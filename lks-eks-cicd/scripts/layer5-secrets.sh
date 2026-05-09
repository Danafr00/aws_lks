#!/bin/bash
# Layer 5 — Secrets Manager + External Secrets Operator
# Prerequisites: Layer 4 done (EFS mounted, PVC Bound)
# Run from: lks-eks-cicd/ directory
set -e

AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-lks-wallet-eks}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
# AWS Academy: iam:CreateRole blocked — LabRole has secretsmanager permissions
LAB_ROLE_ARN="${LAB_ROLE_ARN:-arn:aws:iam::${ACCOUNT_ID}:role/LabRole}"

echo "==> Layer 5: Secrets Manager + External Secrets Operator"
echo "    Account: $ACCOUNT_ID | Region: $AWS_REGION"

# ── 5.1 Verify DB secret exists ─────────────────────────────────────────────
# layer3-rds.sh creates lks/wallet/db in Secrets Manager so ExternalSecret can
# reference it by name. Verify it's there before continuing.
echo ""
echo "==> [5.1] Verifying lks/wallet/db in Secrets Manager"
aws secretsmanager describe-secret \
  --secret-id lks/wallet/db \
  --region "$AWS_REGION" > /dev/null || {
  echo "  ERROR: lks/wallet/db not found."
  echo "  Run scripts/layer3-rds.sh first — it creates this secret."
  exit 1
}
echo "  lks/wallet/db exists"

# ── 5.2 Create JWT secret ────────────────────────────────────────────────────
echo ""
echo "==> [5.2] Creating JWT secret (lks/wallet/app)"
JWT_SECRET=$(openssl rand -hex 32)
aws secretsmanager create-secret \
  --name lks/wallet/app \
  --secret-string "{\"JWT_SECRET\":\"${JWT_SECRET}\"}" \
  --region "$AWS_REGION" \
  --tags Key=Project,Value=nusantara-wallet 2>/dev/null || {
  # Secret already exists — update value
  aws secretsmanager put-secret-value \
    --secret-id lks/wallet/app \
    --secret-string "{\"JWT_SECRET\":\"${JWT_SECRET}\"}" \
    --region "$AWS_REGION"
  echo "  (already existed — value updated)"
}
echo "  lks/wallet/app created"

# ── 5.3 Service account with IRSA annotation ────────────────────────────────
echo ""
echo "==> [5.3] Creating/annotating wallet-api-sa with LabRole"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

kubectl create serviceaccount wallet-api-sa -n wallet 2>/dev/null || true
kubectl annotate serviceaccount wallet-api-sa -n wallet \
  eks.amazonaws.com/role-arn="$LAB_ROLE_ARN" --overwrite
echo "  wallet-api-sa annotated with $LAB_ROLE_ARN"

# ── 5.4 Install External Secrets Operator ───────────────────────────────────
echo ""
echo "==> [5.4] Installing External Secrets Operator (Helm)"
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo update

helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace \
  --wait --timeout 5m0s

kubectl rollout status deployment/external-secrets -n external-secrets --timeout=120s
echo "  ESO running"

# ── 5.5 Delete manual K8s secret from Layer 3 ───────────────────────────────
# ExternalSecret creationPolicy: Owner will not adopt a pre-existing secret
echo ""
echo "==> [5.5] Removing manual wallet-api-secret (ESO will recreate it)"
kubectl delete secret wallet-api-secret -n wallet 2>/dev/null || \
  echo "  (not found — skipping)"

# ── 5.6 ClusterSecretStore ──────────────────────────────────────────────────
echo ""
echo "==> [5.6] Applying ClusterSecretStore"
kubectl apply -f k8s/cluster-secret-store.yaml

# ── 5.7 ExternalSecret ──────────────────────────────────────────────────────
echo ""
echo "==> [5.7] Applying ExternalSecret"
kubectl apply -f k8s/external-secret.yaml

echo "  Waiting for secret sync from Secrets Manager (up to 2 min)..."
sleep 5
kubectl wait externalsecret/wallet-api-external-secret \
  -n wallet --for=condition=Ready --timeout=120s || {
  echo "  Sync not Ready yet — checking status:"
  kubectl describe externalsecret wallet-api-external-secret -n wallet | tail -20
  echo ""
  echo "  If error is about LabRole permissions, ensure LabRole has"
  echo "  secretsmanager:GetSecretValue on lks/wallet/* in AWS Academy."
  exit 1
}
echo "  ExternalSecret synced!"

# ── 5.8 Restart deployment ──────────────────────────────────────────────────
echo ""
echo "==> [5.8] Restarting deployment with wallet-api-sa service account"
kubectl rollout restart deployment/wallet-api -n wallet
kubectl rollout status deployment/wallet-api -n wallet --timeout=300s

# ── 5.9 Verify secrets injected ──────────────────────────────────────────────
echo ""
echo "==> [5.9] Verifying secrets are injected (names only — not values)"
POD=$(kubectl get pod -n wallet -l app=wallet-api -o jsonpath='{.items[0].metadata.name}')
echo "  Pod: $POD"
kubectl exec -n wallet "$POD" -- sh -c \
  "env | grep -E 'DB_PASSWORD|JWT_SECRET' | cut -d= -f1 | sort"

# ── 5.10 Apply HPA and PDB ───────────────────────────────────────────────────
echo ""
echo "==> [5.10] Applying HPA and PodDisruptionBudget"
kubectl apply -f k8s/hpa.yaml
kubectl apply -f k8s/pdb.yaml
kubectl get hpa -n wallet

ELB=$(kubectl get svc wallet-api-svc -n wallet \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

echo ""
echo "==> Layer 5 checkpoint:"
echo "  [ ] kubectl get externalsecret -n wallet  shows READY=True"
echo "  [ ] kubectl get secret wallet-api-secret -n wallet  exists (created by ESO)"
echo "  [ ] DB_PASSWORD and JWT_SECRET printed above"
echo "  [ ] curl http://${ELB:-<elb-hostname>}/health/ready  returns 200"
echo ""
echo "==> Layer 5 complete! Full stack running:"
echo "      ELB    → wallet-api pods"
echo "      pods   → RDS PostgreSQL (credentials from Secrets Manager)"
echo "      pods   ↔ EFS /app/uploads (ReadWriteMany)"
echo "      HPA      min=1 max=3, CPU>60% or Mem>70%"
echo ""
echo "  ELB: ${ELB:-<run: kubectl get svc wallet-api-svc -n wallet>}"
echo ""
echo "==> Optional next: Layer 6 (GitHub Actions CI/CD) — see step-by-step.md"

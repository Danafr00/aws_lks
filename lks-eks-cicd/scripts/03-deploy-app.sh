#!/bin/bash
set -e

# ── Edit these before running ────────────────────────────────────────────────
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
CLUSTER_NAME="lks-wallet-eks"
REGION="ap-southeast-1"
RDS_ENDPOINT="${RDS_ENDPOINT:-}"      # e.g. lks-wallet-db.xxx.rds.amazonaws.com
EFS_ID="${EFS_ID:-}"                  # e.g. fs-0abc1234
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
K8S="$SCRIPT_DIR/k8s"

if [[ -z "$RDS_ENDPOINT" || -z "$EFS_ID" ]]; then
  echo "ERROR: Set RDS_ENDPOINT and EFS_ID before running this script."
  exit 1
fi

echo "==> Updating kubeconfig"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

# Grant LKS-GitHubActionsRole Kubernetes access via EKS Access Entry.
# Without this, every kubectl command in GitHub Actions fails with Unauthorized
# because aws eks update-kubeconfig sets up auth as that IAM role, but EKS
# won't let an unmapped role do anything inside the cluster.
echo ""
echo "==> Granting LKS-GitHubActionsRole access to the EKS cluster"
aws eks create-access-entry \
  --cluster-name "$CLUSTER_NAME" \
  --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/LKS-GitHubActionsRole" \
  --type STANDARD \
  --region "$REGION" 2>/dev/null || echo "  access entry already exists"

# Scoped to the wallet namespace only (least privilege — CI/CD doesn't need cluster-admin)
aws eks associate-access-policy \
  --cluster-name "$CLUSTER_NAME" \
  --principal-arn "arn:aws:iam::${ACCOUNT_ID}:role/LKS-GitHubActionsRole" \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy \
  --access-scope type=namespace,namespaces=wallet \
  --region "$REGION" 2>/dev/null || echo "  access policy already associated"

echo ""
echo "==> Creating wallet namespace and IRSA service account"
kubectl create namespace wallet 2>/dev/null || echo "  namespace already exists"
kubectl label namespace wallet app.kubernetes.io/name=wallet Project=nusantara-wallet --overwrite

eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --namespace wallet \
  --name wallet-api-sa \
  --role-name LKS-WalletAppRole \
  --attach-policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/LKS-WalletAppPolicy" \
  --approve \
  --region "$REGION" 2>/dev/null || echo "  IRSA service account already exists"

echo ""
echo "==> Applying ClusterSecretStore"
kubectl apply -f "$K8S/cluster-secret-store.yaml"

echo ""
echo "==> Applying ConfigMap (patching RDS endpoint)"
sed "s|<RDS_ENDPOINT>|$RDS_ENDPOINT|g" "$K8S/configmap.yaml" | kubectl apply -f -

echo ""
echo "==> Applying ExternalSecret"
kubectl apply -f "$K8S/external-secret.yaml"

echo "  Waiting for secret sync from Secrets Manager..."
kubectl wait externalsecret/wallet-api-external-secret \
  -n wallet --for=condition=Ready --timeout=90s

echo ""
echo "==> Applying StorageClass (patching EFS ID)"
sed "s|<EFS_FILE_SYSTEM_ID>|$EFS_ID|g" "$K8S/storage-class.yaml" | kubectl apply -f -

echo ""
echo "==> Applying PVC (ReadWriteMany via EFS)"
kubectl apply -f "$K8S/pvc.yaml"

echo "  Waiting for PVC to bind..."
kubectl wait pvc/wallet-uploads-pvc -n wallet --for=jsonpath='{.status.phase}'=Bound --timeout=60s
kubectl get pvc -n wallet

echo ""
echo "==> Applying Deployment (patching ECR account)"
sed "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" "$K8S/deployment.yaml" | kubectl apply -f -

echo ""
echo "==> Applying Service, Ingress, HPA, PDB"
kubectl apply -f "$K8S/service.yaml"
kubectl apply -f "$K8S/ingress.yaml"
kubectl apply -f "$K8S/hpa.yaml"
kubectl apply -f "$K8S/pdb.yaml"

echo ""
echo "==> Waiting for deployment rollout..."
kubectl rollout status deployment/wallet-api -n wallet --timeout=300s

echo ""
echo "==> Current state:"
kubectl get pods,svc,ingress,pvc,hpa -n wallet

echo ""
echo "==> Done. Run scripts/04-validate.sh to verify EFS and the endpoint."

#!/bin/bash
# Layer 2 — ECR + Containerized App
# Prerequisites: Layer 1 done (VPC, EKS cluster, hello nginx pod running via Classic ELB)
# Run from: lks-eks-cicd/ directory
set -e

AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-lks-wallet-eks}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REPO="lks-wallet-api"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPO}"

echo "==> Layer 2: ECR + Containerized App"
echo "    Account: $ACCOUNT_ID | Region: $AWS_REGION"

# ── 2.1 ECR repository ───────────────────────────────────────────────────────
echo ""
echo "==> [2.1] Creating ECR repository"
aws ecr create-repository \
  --repository-name "$ECR_REPO" \
  --image-tag-mutability IMMUTABLE \
  --image-scanning-configuration scanOnPush=true \
  --region "$AWS_REGION" \
  --tags Key=Project,Value=nusantara-wallet 2>/dev/null || echo "  (already exists)"

aws ecr put-lifecycle-policy \
  --repository-name "$ECR_REPO" \
  --region "$AWS_REGION" \
  --lifecycle-policy-text '{
    "rules": [
      {"rulePriority":1,"description":"Keep last 5 tagged",
       "selection":{"tagStatus":"tagged","tagPrefixList":["v"],
       "countType":"imageCountMoreThan","countNumber":5},
       "action":{"type":"expire"}},
      {"rulePriority":2,"description":"Expire untagged after 1 day",
       "selection":{"tagStatus":"untagged",
       "countType":"sinceImagePushed","countUnit":"days","countNumber":1},
       "action":{"type":"expire"}}
    ]
  }' 2>/dev/null || true

echo "  ECR: $ECR_URI"

# ── 2.2 Build and push ──────────────────────────────────────────────────────
echo ""
echo "==> [2.2] Building and pushing image (linux/amd64 for EKS nodes)"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin \
    "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker buildx build --platform linux/amd64 \
  -t "${ECR_URI}:v1.0.0" \
  --push \
  app/

echo "  Pushed: ${ECR_URI}:v1.0.0"

# ── 2.3 Swap hello-app with real wallet-api ──────────────────────────────────
echo ""
echo "==> [2.3] Replacing hello-app (nginx) with wallet-api"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

# Create wallet-api-sa early (no IRSA annotation yet — added in Layer 5)
kubectl create serviceaccount wallet-api-sa -n wallet 2>/dev/null || true

# Delete hello-app
kubectl delete deployment wallet-app -n wallet 2>/dev/null || echo "  (hello-app already removed)"

# Apply real deployment (patches ACCOUNT_ID and AWS_REGION placeholders)
sed "s|<ACCOUNT_ID>|$ACCOUNT_ID|g; s|<AWS_REGION>|$AWS_REGION|g" k8s/deployment.yaml | kubectl apply -f -

# Apply service — keeps LoadBalancer type so Classic ELB stays alive
# Also fixes targetPort: nginx listened on 80, Go app listens on 8080
kubectl apply -f k8s/service.yaml

echo ""
echo "  Pods will be in CrashLoopBackOff until Layer 3 provides ConfigMap + Secret."
echo "  This is expected — continue to Layer 3."
echo ""
kubectl get pods -n wallet
echo ""
ELB=$(kubectl get svc wallet-api-svc -n wallet \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
echo "  ELB: ${ELB:-<provisioning — wait 1-2 min>}"

echo ""
echo "==> Layer 2 checkpoint:"
echo "  [ ] aws ecr list-images --repository-name $ECR_REPO --region $AWS_REGION  shows v1.0.0"
echo "  [ ] kubectl get deployment wallet-api -n wallet  exists"
echo ""
echo "==> Layer 2 complete. Next: scripts/layer3-rds.sh"

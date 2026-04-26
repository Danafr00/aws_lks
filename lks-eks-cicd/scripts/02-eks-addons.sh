#!/bin/bash
set -e

# ── Edit these before running ────────────────────────────────────────────────
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
CLUSTER_NAME="lks-wallet-eks"
REGION="ap-southeast-1"
VPC_ID="${VPC_ID:-}"          # paste your VPC ID here, e.g. vpc-0abc1234
EFS_ID="${EFS_ID:-}"          # paste your EFS file system ID here, e.g. fs-0abc1234
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -z "$VPC_ID" ]]; then
  echo "ERROR: Set VPC_ID before running this script."
  exit 1
fi

echo "==> Account: $ACCOUNT_ID | Cluster: $CLUSTER_NAME | VPC: $VPC_ID"

# ── Associate OIDC provider (required for all IRSA) ──────────────────────────
echo ""
echo "==> Associating OIDC provider with cluster"
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --approve

# ── 1. AWS Load Balancer Controller ──────────────────────────────────────────
echo ""
echo "==> [1/5] Installing AWS Load Balancer Controller"

curl -sLo /tmp/alb-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file:///tmp/alb-iam-policy.json 2>/dev/null || echo "  policy already exists"

eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --role-name LKS-AWSLoadBalancerControllerRole \
  --attach-policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy" \
  --approve \
  --region "$REGION"

helm repo add eks https://aws.github.io/eks-charts 2>/dev/null; helm repo update

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region="$REGION" \
  --set vpcId="$VPC_ID"

kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s

# ── 2. EFS CSI Driver ────────────────────────────────────────────────────────
echo ""
echo "==> [2/5] Installing EFS CSI Driver"

eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --namespace kube-system \
  --name efs-csi-controller-sa \
  --role-name LKS-EFSCSIDriverRole \
  --attach-policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/LKS-EFSCSIDriverPolicy" \
  --approve \
  --region "$REGION"

aws eks create-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-efs-csi-driver \
  --service-account-role-arn "arn:aws:iam::${ACCOUNT_ID}:role/LKS-EFSCSIDriverRole" \
  --region "$REGION" 2>/dev/null || echo "  addon already exists"

echo "  Waiting for EFS CSI driver to become ACTIVE..."
aws eks wait addon-active \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-efs-csi-driver \
  --region "$REGION"

# Patch storage-class.yaml with the actual EFS ID, then apply
if [[ -n "$EFS_ID" ]]; then
  sed "s|<EFS_FILE_SYSTEM_ID>|$EFS_ID|g" "$SCRIPT_DIR/k8s/storage-class.yaml" | kubectl apply -f -
  echo "  StorageClass efs-sc applied (EFS: $EFS_ID)"
else
  echo "  WARNING: EFS_ID not set. Edit k8s/storage-class.yaml manually then: kubectl apply -f k8s/storage-class.yaml"
fi

# ── 3. Cluster Autoscaler ────────────────────────────────────────────────────
echo ""
echo "==> [3/5] Installing Cluster Autoscaler"

eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --namespace kube-system \
  --name cluster-autoscaler \
  --role-name LKS-ClusterAutoscalerRole \
  --attach-policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/LKS-ClusterAutoscalerPolicy" \
  --approve \
  --region "$REGION"

helm repo add autoscaler https://kubernetes.github.io/autoscaler 2>/dev/null; helm repo update

helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName="$CLUSTER_NAME" \
  --set awsRegion="$REGION" \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler

# ── 4. External Secrets Operator ─────────────────────────────────────────────
echo ""
echo "==> [4/5] Installing External Secrets Operator"

eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --namespace external-secrets \
  --name external-secrets \
  --role-name LKS-ExternalSecretsRole \
  --attach-policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/LKS-ExternalSecretsPolicy" \
  --approve \
  --region "$REGION"

helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null; helm repo update

helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=arn:aws:iam::${ACCOUNT_ID}:role/LKS-ExternalSecretsRole"

kubectl rollout status deployment/external-secrets -n external-secrets --timeout=120s

# ── 5. Metrics Server ────────────────────────────────────────────────────────
echo ""
echo "==> [5/5] Installing Metrics Server"
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s

echo ""
echo "==> All add-ons installed. Next: scripts/03-deploy-app.sh"

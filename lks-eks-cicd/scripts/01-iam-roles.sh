#!/bin/bash
set -e

# ── Edit these before running ────────────────────────────────────────────────
ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
CLUSTER_NAME="lks-wallet-eks"
REGION="ap-southeast-1"
OIDC_ISSUER="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
  --query "cluster.identity.oidc.issuer" --output text 2>/dev/null | sed 's|https://||')"
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Account: $ACCOUNT_ID | Cluster: $CLUSTER_NAME | Region: $REGION"

# ── 1. EKS Cluster Role ──────────────────────────────────────────────────────
echo ""
echo "==> Creating LKS-EKSClusterRole"
aws iam create-role \
  --role-name LKS-EKSClusterRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "eks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }' \
  --tags Key=Project,Value=nusantara-wallet Key=ManagedBy,Value=LKS-Team 2>/dev/null || echo "  (already exists, skipping)"

aws iam attach-role-policy \
  --role-name LKS-EKSClusterRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

# ── 2. EKS Node Role ─────────────────────────────────────────────────────────
echo ""
echo "==> Creating LKS-EKSNodeRole"
aws iam create-role \
  --role-name LKS-EKSNodeRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }]
  }' \
  --tags Key=Project,Value=nusantara-wallet Key=ManagedBy,Value=LKS-Team 2>/dev/null || echo "  (already exists, skipping)"

for policy in AmazonEKSWorkerNodePolicy AmazonEC2ContainerRegistryReadOnly AmazonEKS_CNI_Policy CloudWatchAgentServerPolicy; do
  aws iam attach-role-policy \
    --role-name LKS-EKSNodeRole \
    --policy-arn "arn:aws:iam::aws:policy/$policy"
done

# ── 3. EFS CSI Driver Policy and Role ────────────────────────────────────────
echo ""
echo "==> Creating LKS-EFSCSIDriverPolicy"
aws iam create-policy \
  --policy-name LKS-EFSCSIDriverPolicy \
  --policy-document file://"$SCRIPT_DIR/iam/efs-csi-policy.json" \
  --tags Key=Project,Value=nusantara-wallet 2>/dev/null || echo "  (already exists, skipping)"

# ── 4. Cluster Autoscaler Policy ─────────────────────────────────────────────
echo ""
echo "==> Creating LKS-ClusterAutoscalerPolicy"
aws iam create-policy \
  --policy-name LKS-ClusterAutoscalerPolicy \
  --policy-document file://"$SCRIPT_DIR/iam/cluster-autoscaler-policy.json" \
  --tags Key=Project,Value=nusantara-wallet 2>/dev/null || echo "  (already exists, skipping)"

# ── 5. External Secrets Policy ───────────────────────────────────────────────
echo ""
echo "==> Creating LKS-ExternalSecretsPolicy"
aws iam create-policy \
  --policy-name LKS-ExternalSecretsPolicy \
  --policy-document file://"$SCRIPT_DIR/iam/external-secrets-policy.json" \
  --tags Key=Project,Value=nusantara-wallet 2>/dev/null || echo "  (already exists, skipping)"

# ── 6. Wallet App Policy ─────────────────────────────────────────────────────
echo ""
echo "==> Creating LKS-WalletAppPolicy"
aws iam create-policy \
  --policy-name LKS-WalletAppPolicy \
  --policy-document file://"$SCRIPT_DIR/iam/wallet-app-policy.json" \
  --tags Key=Project,Value=nusantara-wallet 2>/dev/null || echo "  (already exists, skipping)"

# ── 7. GitHub Actions Policy and Role ────────────────────────────────────────
echo ""
echo "==> Creating LKS-GitHubActionsPolicy"
aws iam create-policy \
  --policy-name LKS-GitHubActionsPolicy \
  --policy-document file://"$SCRIPT_DIR/iam/github-actions-policy.json" \
  --tags Key=Project,Value=nusantara-wallet 2>/dev/null || echo "  (already exists, skipping)"

echo ""
echo "==> Creating GitHub OIDC Identity Provider"
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 2>/dev/null || echo "  (already exists, skipping)"

echo ""
echo "==> Done. Run scripts/02-eks-addons.sh after the EKS cluster is ACTIVE."
echo ""
echo "    NOTE: IRSA roles (ALB controller, EFS CSI, autoscaler, external-secrets,"
echo "    wallet-api-sa) are created in 02-eks-addons.sh via eksctl after the"
echo "    cluster OIDC provider is associated."

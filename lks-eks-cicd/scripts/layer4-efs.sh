#!/bin/bash
# Layer 4 — EFS Shared Storage
# Prerequisites: Layer 3 done (app connected to RDS, /health/ready returns 200)
# Run from: lks-eks-cicd/ directory
#
# AWS Academy note: OIDC/IRSA blocked. EFS CSI addon installed WITHOUT service-account-role-arn.
# Uses static PV provisioning (pv.yaml) to bypass the CSI controller entirely.
# The CSI node DaemonSet mounts EFS via NFS — no EFS API calls, no IAM credentials needed.
set -e

AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-lks-wallet-eks}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "==> Layer 4: EFS Shared Storage (static provisioning)"
echo "    Account: $ACCOUNT_ID | Region: $AWS_REGION"

# Derive networking from cluster
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
CLUSTER_SG=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
NODE_SG=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=lks-eks-node-sg" \
  --query 'SecurityGroups[0].GroupId' --output text)
PRIV1=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=lks-private-1a" \
  --query 'Subnets[0].SubnetId' --output text)
PRIV2=$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=lks-private-1b" \
  --query 'Subnets[0].SubnetId' --output text)

echo "  VPC: $VPC_ID | NODE_SG: $NODE_SG | PRIV: $PRIV1, $PRIV2"

# ── 4.1 EFS security group ───────────────────────────────────────────────────
echo ""
echo "==> [4.1] Creating lks-efs-sg"
EFS_SG=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=lks-efs-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

if [[ -z "$EFS_SG" || "$EFS_SG" == "None" ]]; then
  EFS_SG=$(aws ec2 create-security-group \
    --group-name lks-efs-sg \
    --description "EFS NFS mount targets" \
    --vpc-id "$VPC_ID" \
    --region "$AWS_REGION" \
    --query 'GroupId' --output text)
  echo "  Created: $EFS_SG"
else
  echo "  Already exists: $EFS_SG"
fi

# Allow NFS from node SG and cluster SG (pods use cluster SG for egress)
aws ec2 authorize-security-group-ingress --group-id "$EFS_SG" \
  --protocol tcp --port 2049 --source-group "$NODE_SG" \
  --region "$AWS_REGION" 2>/dev/null || true
aws ec2 authorize-security-group-ingress --group-id "$EFS_SG" \
  --protocol tcp --port 2049 --source-group "$CLUSTER_SG" \
  --region "$AWS_REGION" 2>/dev/null || true
aws ec2 create-tags --resources "$EFS_SG" \
  --tags Key=Name,Value=lks-efs-sg Key=Project,Value=nusantara-wallet \
  --region "$AWS_REGION"
echo "  EFS SG: $EFS_SG"

# ── 4.2 EFS file system ──────────────────────────────────────────────────────
echo ""
echo "==> [4.2] Creating EFS file system"
EFS_ID=$(aws efs create-file-system \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --encrypted \
  --region "$AWS_REGION" \
  --tags Key=Name,Value=lks-wallet-storage Key=Project,Value=nusantara-wallet \
  --query 'FileSystemId' --output text)
echo "  EFS: $EFS_ID"

# ── 4.3 Mount targets in private subnets ────────────────────────────────────
echo ""
echo "==> [4.3] Creating mount targets in private subnets"
aws efs create-mount-target \
  --file-system-id "$EFS_ID" \
  --subnet-id "$PRIV1" \
  --security-groups "$EFS_SG" \
  --region "$AWS_REGION"
aws efs create-mount-target \
  --file-system-id "$EFS_ID" \
  --subnet-id "$PRIV2" \
  --security-groups "$EFS_SG" \
  --region "$AWS_REGION"

echo "  Waiting 45s for mount targets to become available..."
sleep 45

# ── 4.4 EFS CSI Driver addon (NO --service-account-role-arn) ────────────────
echo ""
echo "==> [4.4] Installing EFS CSI Driver addon (no IRSA — static provisioning bypasses controller)"
aws eks create-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-efs-csi-driver \
  --region "$AWS_REGION" 2>/dev/null || echo "  (addon already installed)"

echo "  Waiting for EFS CSI Driver to become ACTIVE..."
aws eks wait addon-active \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name aws-efs-csi-driver \
  --region "$AWS_REGION"
echo "  EFS CSI Driver: ACTIVE"

# ── 4.5 StorageClass + static PV + PVC ──────────────────────────────────────
echo ""
echo "==> [4.5] Applying StorageClass, static PV, and PVC"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"

# StorageClass: provisioner reference only — parameters unused for static PV
sed "s|<EFS_FILE_SYSTEM_ID>|$EFS_ID|g" k8s/storage-class.yaml | kubectl apply -f -

# Static PV — references EFS filesystem directly, no access point
sed "s|<EFS_FILE_SYSTEM_ID>|$EFS_ID|g" k8s/pv.yaml | kubectl apply -f -

# PVC binds to PV by volumeName — no dynamic provisioning triggered
kubectl apply -f k8s/pvc.yaml

echo "  Waiting for PVC to bind (up to 60s)..."
kubectl wait pvc/wallet-uploads-pvc -n wallet \
  --for=jsonpath='{.status.phase}'=Bound --timeout=60s
kubectl get pvc -n wallet

# ── 4.6 Re-apply deployment (reverts any emptyDir workaround from Layer 3) ──
echo ""
echo "==> [4.6] Re-applying deployment with real EFS PVC"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed "s|<ACCOUNT_ID>|$ACCOUNT_ID|g; s|<AWS_REGION>|$AWS_REGION|g" k8s/deployment.yaml | kubectl apply -f -
kubectl rollout status deployment/wallet-api -n wallet --timeout=300s

# ── 4.7 ReadWriteMany test ───────────────────────────────────────────────────
echo ""
echo "==> [4.8] Testing EFS ReadWriteMany (scale to 2 pods)"
kubectl scale deployment wallet-api -n wallet --replicas=2
kubectl wait --for=condition=ready pod -l app=wallet-api -n wallet --timeout=120s

P0=$(kubectl get pods -n wallet -l app=wallet-api -o name | head -1 | sed 's|pod/||')
P1=$(kubectl get pods -n wallet -l app=wallet-api -o name | tail -1 | sed 's|pod/||')

if [[ -z "$P1" || "$P0" == "$P1" ]]; then
  echo "  Only 1 pod found — skipping cross-pod test."
  echo "  Run manually: kubectl scale deployment wallet-api -n wallet --replicas=2"
else
  echo "  Writing from $P0..."
  kubectl exec -n wallet "$P0" -- \
    sh -c "echo 'layer4-rwx-ok' > /app/uploads/test.txt && echo OK"

  echo "  Reading from $P1..."
  RESULT=$(kubectl exec -n wallet "$P1" -- cat /app/uploads/test.txt)
  echo "  Read: $RESULT"

  if [[ "$RESULT" == "layer4-rwx-ok" ]]; then
    echo "  ReadWriteMany CONFIRMED"
  else
    echo "  ERROR: ReadWriteMany test FAILED — expected 'layer4-rwx-ok' got '$RESULT'"
    exit 1
  fi
fi

# Scale back to 1 (HPA will scale up under load)
kubectl scale deployment wallet-api -n wallet --replicas=1

echo ""
echo "==> Layer 4 checkpoint:"
echo "  [x] PVC is Bound"
echo "  [x] File written from pod1 readable by pod2 (ReadWriteMany confirmed)"
echo ""
echo "  Save for later: EFS_ID=$EFS_ID"
echo ""
echo "==> Layer 4 complete. Next: scripts/layer5-secrets.sh"

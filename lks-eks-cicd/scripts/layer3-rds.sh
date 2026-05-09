#!/bin/bash
# Layer 3 — RDS PostgreSQL
# Prerequisites: Layer 2 done (wallet-api deployment exists, ECR image pushed)
# Run from: lks-eks-cicd/ directory
set -e

AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-lks-wallet-eks}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "==> Layer 3: RDS PostgreSQL"
echo "    Account: $ACCOUNT_ID | Region: $AWS_REGION | Cluster: $CLUSTER_NAME"

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

echo "  VPC: $VPC_ID | NODE_SG: $NODE_SG | CLUSTER_SG: $CLUSTER_SG"
echo "  Private subnets: $PRIV1, $PRIV2"

# ── 3.1 RDS security group ───────────────────────────────────────────────────
echo ""
echo "==> [3.1] Creating lks-rds-sg"
RDS_SG=$(aws ec2 describe-security-groups --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=lks-rds-sg" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)

if [[ -z "$RDS_SG" || "$RDS_SG" == "None" ]]; then
  RDS_SG=$(aws ec2 create-security-group \
    --group-name lks-rds-sg \
    --description "RDS PostgreSQL" \
    --vpc-id "$VPC_ID" \
    --region "$AWS_REGION" \
    --query 'GroupId' --output text)
  echo "  Created: $RDS_SG"
else
  echo "  Already exists: $RDS_SG"
fi

# Allow from node SG (for direct EC2 access / bastion)
aws ec2 authorize-security-group-ingress --group-id "$RDS_SG" \
  --protocol tcp --port 5432 --source-group "$NODE_SG" \
  --region "$AWS_REGION" 2>/dev/null || true

# Allow from EKS cluster SG (pods egress through this SG — without it, pods get timeout)
aws ec2 authorize-security-group-ingress --group-id "$RDS_SG" \
  --protocol tcp --port 5432 --source-group "$CLUSTER_SG" \
  --region "$AWS_REGION" 2>/dev/null || true

aws ec2 create-tags --resources "$RDS_SG" \
  --tags Key=Name,Value=lks-rds-sg Key=Project,Value=nusantara-wallet \
  --region "$AWS_REGION"

echo "  RDS SG: $RDS_SG (allows from node SG + cluster SG)"

# ── 3.2 DB subnet group ──────────────────────────────────────────────────────
echo ""
echo "==> [3.2] Creating DB subnet group"
aws rds create-db-subnet-group \
  --db-subnet-group-name lks-wallet-db-subnet \
  --db-subnet-group-description "Wallet DB private subnets" \
  --subnet-ids "$PRIV1" "$PRIV2" \
  --region "$AWS_REGION" 2>/dev/null || echo "  (already exists)"

# ── 3.3 RDS instance ─────────────────────────────────────────────────────────
echo ""
echo "==> [3.3] Creating RDS PostgreSQL 16 instance (takes ~10 min)"
aws rds create-db-instance \
  --db-instance-identifier lks-wallet-db \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version 16.3 \
  --master-username walletadmin \
  --manage-master-user-password \
  --db-name wallet_db \
  --allocated-storage 20 \
  --storage-type gp2 \
  --no-multi-az \
  --no-publicly-accessible \
  --vpc-security-group-ids "$RDS_SG" \
  --db-subnet-group-name lks-wallet-db-subnet \
  --backup-retention-period 0 \
  --region "$AWS_REGION" \
  --tags Key=Project,Value=nusantara-wallet 2>/dev/null || echo "  (already exists)"

echo "  Waiting for RDS (~10 min)..."
aws rds wait db-instance-available \
  --db-instance-identifier lks-wallet-db \
  --region "$AWS_REGION"

DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier lks-wallet-db \
  --region "$AWS_REGION" \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "  DB Endpoint: $DB_ENDPOINT"

# ── 3.4 ConfigMap ────────────────────────────────────────────────────────────
echo ""
echo "==> [3.4] Applying ConfigMap (DB_HOST=$DB_ENDPOINT)"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION"
sed "s|<RDS_ENDPOINT>|$DB_ENDPOINT|g" k8s/configmap.yaml | kubectl apply -f -

# ── 3.5 K8s Secret from Secrets Manager ─────────────────────────────────────
echo ""
echo "==> [3.5] Injecting DB_PASSWORD from Secrets Manager into K8s Secret"
DB_SECRET_ARN=$(aws rds describe-db-instances \
  --db-instance-identifier lks-wallet-db \
  --region "$AWS_REGION" \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)

DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$DB_SECRET_ARN" \
  --region "$AWS_REGION" \
  --query 'SecretString' --output text \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

# RDS auto-creates the secret as rds!db-<id>-<uuid> — create lks/wallet/db so
# ExternalSecret (k8s/external-secret.yaml key: lks/wallet/db) finds it by name.
aws secretsmanager create-secret \
  --name lks/wallet/db \
  --secret-string "{\"password\":\"${DB_PASSWORD}\",\"username\":\"walletadmin\"}" \
  --region "$AWS_REGION" \
  --tags Key=Project,Value=nusantara-wallet 2>/dev/null || \
aws secretsmanager put-secret-value \
  --secret-id lks/wallet/db \
  --secret-string "{\"password\":\"${DB_PASSWORD}\",\"username\":\"walletadmin\"}" \
  --region "$AWS_REGION"
echo "  lks/wallet/db created in Secrets Manager"

# Use dry-run + apply for idempotency
kubectl create secret generic wallet-api-secret \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  -n wallet --dry-run=client -o yaml | kubectl apply -f -

# ── 3.6 Restart and verify ───────────────────────────────────────────────────
echo ""
echo "==> [3.6] Restarting deployment"
kubectl rollout restart deployment/wallet-api -n wallet
kubectl rollout status deployment/wallet-api -n wallet --timeout=300s

echo ""
echo "==> [3.7] Verifying DB connectivity"
POD=$(kubectl get pod -n wallet -l app=wallet-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n wallet "$POD" -- sh -c "nc -zv $DB_ENDPOINT 5432 && echo 'DB reachable!'"
kubectl logs "$POD" -n wallet --tail=5

echo ""
ELB=$(kubectl get svc wallet-api-svc -n wallet \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
echo "==> Layer 3 checkpoint:"
echo "  [ ] nc shows port 5432 open"
echo "  [ ] Pod logs show 'Migration complete' and 'Listening on :8080'"
echo "  [ ] curl http://${ELB:-<elb-hostname>}/health/ready  returns 200"
echo ""
echo "==> Layer 3 complete. Next: scripts/layer4-efs.sh"

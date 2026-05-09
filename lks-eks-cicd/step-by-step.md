# Step-by-Step: EKS CI/CD — Build It Layer by Layer

**Goal**: Deploy a containerized wallet API on EKS, connected to RDS + EFS + Secrets Manager, with a GitHub Actions CI/CD pipeline.  
**Approach**: Build and test each layer independently before adding the next. Never set up everything at once.  
**Region**: us-east-1 | **Cost warning**: EKS $0.10/hr, NAT Gateway $0.045/hr — delete after use.

---

## Layers

| Layer | What You Build | Test | Script |
|---|---|---|---|
| **1** | VPC + IAM + EKS + Nodes + Hello App | Classic ELB serves Hello World | manual (see below) |
| **2** | ECR + Containerized App | Pods pull from ECR | `scripts/layer2-ecr.sh` |
| **3** | RDS PostgreSQL | App connects to DB | `scripts/layer3-rds.sh` |
| **4** | EFS Shared Storage | Pods read/write shared files | `scripts/layer4-efs.sh` |
| **5** | Secrets Manager | App reads secrets from AWS | `scripts/layer5-secrets.sh` |
| **6** | GitHub Actions CI/CD | `git push` → auto deploy | manual (see Layer 6) |

> **Scripts** (layers 2–5) are AWS Academy compatible. They use `LabRole` for all addon service accounts. Set `AWS_REGION` and `CLUSTER_NAME` environment variables before running if your values differ from the defaults (`us-east-1`, `lks-wallet-eks`).

---

## Layer 1 — EKS Cluster + Hello App

### 1.1 Variables

Keep this terminal open — all later layers depend on these variables.

```bash
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=lks-wallet-eks
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID"
```

### 1.2 VPC

```bash
# VPC
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.10.0.0/16 \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
aws ec2 create-tags --resources $VPC_ID \
  --tags Key=Name,Value=lks-wallet-vpc Key=Project,Value=nusantara-wallet
echo "VPC: $VPC_ID"

# Public subnets (ALB lives here)
PUB1=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.10.1.0/24 --availability-zone ${AWS_REGION}a \
  --query 'Subnet.SubnetId' --output text)
PUB2=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.10.2.0/24 --availability-zone ${AWS_REGION}b \
  --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --subnet-id $PUB1 --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $PUB2 --map-public-ip-on-launch
aws ec2 create-tags --resources $PUB1 \
  --tags Key=Name,Value=lks-public-1a \
         Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned \
         Key=kubernetes.io/role/elb,Value=1
aws ec2 create-tags --resources $PUB2 \
  --tags Key=Name,Value=lks-public-1b \
         Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned \
         Key=kubernetes.io/role/elb,Value=1

# Private subnets (nodes, RDS, EFS live here)
PRIV1=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.10.10.0/24 --availability-zone ${AWS_REGION}a \
  --query 'Subnet.SubnetId' --output text)
PRIV2=$(aws ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 10.10.11.0/24 --availability-zone ${AWS_REGION}b \
  --query 'Subnet.SubnetId' --output text)
aws ec2 create-tags --resources $PRIV1 \
  --tags Key=Name,Value=lks-private-1a \
         Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned \
         Key=kubernetes.io/role/internal-elb,Value=1
aws ec2 create-tags --resources $PRIV2 \
  --tags Key=Name,Value=lks-private-1b \
         Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=owned \
         Key=kubernetes.io/role/internal-elb,Value=1

echo "Public: $PUB1 $PUB2 | Private: $PRIV1 $PRIV2"

# Internet Gateway + public route table
IGW=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC_ID
aws ec2 create-tags --resources $IGW --tags Key=Name,Value=lks-wallet-igw

PUB_RTB=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $PUB_RTB \
  --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW
aws ec2 associate-route-table --route-table-id $PUB_RTB --subnet-id $PUB1
aws ec2 associate-route-table --route-table-id $PUB_RTB --subnet-id $PUB2
aws ec2 create-tags --resources $PUB_RTB --tags Key=Name,Value=lks-public-rtb

# NAT Gateway + private route table (nodes in private subnets need internet for ECR pulls)
EIP=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
NAT=$(aws ec2 create-nat-gateway \
  --subnet-id $PUB1 --allocation-id $EIP \
  --query 'NatGateway.NatGatewayId' --output text)
aws ec2 create-tags --resources $NAT --tags Key=Name,Value=lks-wallet-nat
echo "Waiting for NAT Gateway..."
aws ec2 wait nat-gateway-available --nat-gateway-ids $NAT

PRIV_RTB=$(aws ec2 create-route-table --vpc-id $VPC_ID \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id $PRIV_RTB \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id $NAT
aws ec2 associate-route-table --route-table-id $PRIV_RTB --subnet-id $PRIV1
aws ec2 associate-route-table --route-table-id $PRIV_RTB --subnet-id $PRIV2
aws ec2 create-tags --resources $PRIV_RTB --tags Key=Name,Value=lks-private-rtb

echo "--- VPC done ---"
```

### 1.3 Security Groups

```bash
# Node security group
NODE_SG=$(aws ec2 create-security-group \
  --group-name lks-eks-node-sg \
  --description "EKS worker nodes" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)
# Allow SSH from anywhere (restrict to your IP in production)
aws ec2 authorize-security-group-ingress --group-id $NODE_SG \
  --protocol tcp --port 22 --cidr 0.0.0.0/0
# Allow all internal traffic between nodes
aws ec2 authorize-security-group-ingress --group-id $NODE_SG \
  --protocol -1 --port -1 --source-group $NODE_SG
aws ec2 create-tags --resources $NODE_SG --tags Key=Name,Value=lks-eks-node-sg
echo "Node SG: $NODE_SG"
```

### 1.4 Key Pair (for SSH to nodes)

```bash
aws ec2 create-key-pair \
  --key-name lks-eks-key \
  --query 'KeyMaterial' \
  --output text > ~/.ssh/lks-eks-key.pem

chmod 400 ~/.ssh/lks-eks-key.pem
echo "Key saved to ~/.ssh/lks-eks-key.pem"
```

### 1.5 IAM Roles

```bash
# ── Cluster Role ──────────────────────────────────────────────
cat > /tmp/eks-cluster-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow",
    "Principal": {"Service": "eks.amazonaws.com"},
    "Action": "sts:AssumeRole"}]
}
EOF

aws iam create-role --role-name LKS-EKSClusterRole \
  --assume-role-policy-document file:///tmp/eks-cluster-trust.json
aws iam attach-role-policy --role-name LKS-EKSClusterRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

CLUSTER_ROLE_ARN=$(aws iam get-role --role-name LKS-EKSClusterRole \
  --query 'Role.Arn' --output text)
echo "Cluster Role: $CLUSTER_ROLE_ARN"

# ── Node Role ─────────────────────────────────────────────────
cat > /tmp/eks-node-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"}]
}
EOF

aws iam create-role --role-name LKS-EKSNodeRole \
  --assume-role-policy-document file:///tmp/eks-node-trust.json

for POLICY in \
  AmazonEKSWorkerNodePolicy \
  AmazonEKS_CNI_Policy \
  AmazonEC2ContainerRegistryReadOnly \
  AmazonSSMManagedInstanceCore; do
  aws iam attach-role-policy --role-name LKS-EKSNodeRole \
    --policy-arn arn:aws:iam::aws:policy/$POLICY
  echo "Attached $POLICY"
done

NODE_ROLE_ARN=$(aws iam get-role --role-name LKS-EKSNodeRole \
  --query 'Role.Arn' --output text)
echo "Node Role: $NODE_ROLE_ARN"

echo "--- IAM done ---"
```

### 1.6 EKS Cluster

```bash
aws eks create-cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --kubernetes-version 1.31 \
  --role-arn $CLUSTER_ROLE_ARN \
  --resources-vpc-config \
    subnetIds=$PRIV1,$PRIV2,\
endpointPublicAccess=true,endpointPrivateAccess=true \
  --access-config authenticationMode=API

echo "Waiting for cluster (~12 min)..."
aws eks wait cluster-active --name $CLUSTER_NAME --region $AWS_REGION
echo "Cluster ACTIVE!"

aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
kubectl get svc
```

### 1.7 Node Group (AL2023, no launch template, SSH enabled)

```bash
aws eks create-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name lks-wallet-ng \
  --node-role $NODE_ROLE_ARN \
  --subnets $PRIV1 $PRIV2 \
  --instance-types m7i-flex.large \
  --ami-type AL2023_x86_64_STANDARD \
  --disk-size 20 \
  --scaling-config minSize=2,maxSize=4,desiredSize=2 \
  --remote-access ec2SshKey=lks-eks-key,sourceSecurityGroups=$NODE_SG \
  --region $AWS_REGION

echo "Waiting for node group (~7 min)..."
aws eks wait nodegroup-active \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name lks-wallet-ng \
  --region $AWS_REGION

kubectl get nodes
# Expected: 1 node Ready
```

> **To connect to a node:**
>
> Nodes are in private subnets. Use **SSM Session Manager** — no bastion, no open ports needed:
> ```bash
> NODE_ID=$(aws ec2 describe-instances \
>   --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" \
>             "Name=instance-state-name,Values=running" \
>   --query 'Reservations[0].Instances[0].InstanceId' --output text)
>
> aws ssm start-session --target $NODE_ID
> # Opens a shell on the node
> ```
>
> Or traditional SSH from a bastion in the public subnet:
> ```bash
> ssh -i ~/.ssh/lks-eks-key.pem ec2-user@<node-private-ip>
> ```

### 1.8 Deploy Hello App

> **AWS Academy note:** `iam:CreateOpenIDConnectProvider` is blocked. Skip LBC entirely — use `Service type=LoadBalancer`. The EKS in-tree cloud provider creates a Classic ELB using the cluster's IAM role (`AmazonEKSClusterPolicy` includes `elasticloadbalancing:*`). No OIDC, no Helm, no extra IAM needed.
>
> Subnets must be tagged with `kubernetes.io/cluster/<cluster-name>` and `kubernetes.io/role/elb` for the in-tree provider to discover them (already done in step 1.2).

Verify everything works before adding more services.

```bash
kubectl create namespace wallet

kubectl apply -f - << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wallet-app
  namespace: wallet
spec:
  replicas: 1
  selector:
    matchLabels:
      app: wallet-app
  template:
    metadata:
      labels:
        app: wallet-app
    spec:
      containers:
      - name: app
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: wallet-api-svc
  namespace: wallet
spec:
  selector:
    app: wallet-app
  ports:
  - port: 80
  type: LoadBalancer
EOF

kubectl get pods -n wallet --watch
# Wait for Running, then Ctrl+C

kubectl get svc wallet-api-svc -n wallet --watch
# Wait for EXTERNAL-IP column (1-2 min), then:
ELB=$(kubectl get svc wallet-api-svc -n wallet \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$ELB
# Expected: nginx welcome page
```

**Layer 1 checkpoint** — before continuing:
- [ ] `kubectl get nodes` shows Ready
- [ ] `curl http://$ELB` returns a response
- [ ] `aws ssm start-session --target $NODE_ID` opens a shell

---

## Layer 2 — ECR + Containerized App

### 2.1 Create ECR Repository

```bash
aws ecr create-repository \
  --repository-name lks-wallet-api \
  --image-tag-mutability IMMUTABLE \
  --image-scanning-configuration scanOnPush=true \
  --region $AWS_REGION

ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/lks-wallet-api"
echo "ECR: $ECR_URI"

# Keep only last 5 tagged images, expire untagged after 1 day
aws ecr put-lifecycle-policy \
  --repository-name lks-wallet-api \
  --lifecycle-policy-text '{
    "rules": [
      {"rulePriority": 1, "description": "Keep last 5 tagged",
       "selection": {"tagStatus": "tagged", "tagPrefixList": ["v"],
       "countType": "imageCountMoreThan", "countNumber": 5},
       "action": {"type": "expire"}},
      {"rulePriority": 2, "description": "Expire untagged after 1 day",
       "selection": {"tagStatus": "untagged",
       "countType": "sinceImagePushed", "countUnit": "days", "countNumber": 1},
       "action": {"type": "expire"}}
    ]
  }'
```

### 2.2 Build and Push Image

> **Apple Silicon Mac (M1/M2/M3):** EKS nodes are `amd64`. Build with `--platform linux/amd64` or the pod gets `ImagePullBackOff: no match for platform in manifest`.

```bash
# From lks-eks-cicd/app/ directory
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin \
  ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Build for amd64 (required on Apple Silicon)
docker buildx build --platform linux/amd64 \
  -t ${ECR_URI}:v1.0.0 --push .
echo "Image pushed: ${ECR_URI}:v1.0.0"
```

> **ECR immutable tags:** The ECR repo is created with `IMMUTABLE` tags. If you need to fix a bad push (e.g., wrong platform), you cannot overwrite — use a new tag (`v1.0.1`) or disable immutability first:
> ```bash
> aws ecr put-image-tag-mutability --repository-name lks-wallet-api \
>   --image-tag-mutability MUTABLE --region $AWS_REGION
> ```

### 2.3 Replace Hello-App with Real Deployment

Hello-app verified the Classic ELB works. Now delete it and apply the real manifests from `k8s/`.

```bash
# Delete hello-app — it has served its purpose
kubectl delete deployment wallet-app -n wallet
echo "Hello-app removed."

# Apply real deployment + service (service.yaml keeps type: LoadBalancer from Layer 1)
sed "s|<ACCOUNT_ID>|$ACCOUNT_ID|g; s|<AWS_REGION>|$AWS_REGION|g" k8s/deployment.yaml | kubectl apply -f -
kubectl apply -f k8s/service.yaml

# Pods will CrashLoop until Layer 3 provides ConfigMap + Secret — expected
echo "Pods will be unhealthy until Layer 3. Continuing is fine."
kubectl get pods -n wallet
```

**Layer 2 checkpoint:**
- [ ] ECR repo shows image in console
- [ ] `kubectl get deployment wallet-api -n wallet` exists

---

## Layer 3 — RDS PostgreSQL

### 3.1 Security Group for RDS

```bash
RDS_SG=$(aws ec2 create-security-group \
  --group-name lks-rds-sg \
  --description "RDS PostgreSQL" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

# Allow from manually created node SG
aws ec2 authorize-security-group-ingress --group-id $RDS_SG \
  --protocol tcp --port 5432 --source-group $NODE_SG

# EKS also auto-creates a cluster SG (pods use this one) — allow it too
CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $RDS_SG \
  --protocol tcp --port 5432 --source-group $CLUSTER_SG

aws ec2 create-tags --resources $RDS_SG --tags Key=Name,Value=lks-rds-sg
echo "RDS SG: $RDS_SG | Cluster SG allowed: $CLUSTER_SG"
```

> **Why two SGs?** EKS auto-creates a cluster SG and attaches it to every node and pod. The manually created `$NODE_SG` covers SSH/remote access but pods actually egress through the cluster SG. Both must be allowed or pods get connection timeout on port 5432.

> **NODE_SG lookup note:** If `lks-eks-node-sg` was never created manually (e.g. node group created via console with "Allow SSH" which creates an `eks-remoteAccess-*` SG instead), the `$NODE_SG` variable will be empty. Use the cluster SG alone, or look up the remoteAccess SG: `aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=eks-remoteAccess*" --query 'SecurityGroups[0].GroupId' --output text`

### 3.2 Create RDS

```bash
aws rds create-db-subnet-group \
  --db-subnet-group-name lks-wallet-db-subnet \
  --db-subnet-group-description "Wallet DB subnets" \
  --subnet-ids $PRIV1 $PRIV2

aws rds create-db-instance \
  --db-instance-identifier lks-wallet-db \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version 16.6 \
  --master-username walletadmin \
  --manage-master-user-password \
  --db-name wallet_db \
  --allocated-storage 20 \
  --storage-type gp2 \
  --no-multi-az \
  --no-publicly-accessible \
  --vpc-security-group-ids $RDS_SG \
  --db-subnet-group-name lks-wallet-db-subnet \
  --backup-retention-period 0 \
  --tags Key=Project,Value=nusantara-wallet

echo "Waiting for RDS (~10 min)..."
aws rds wait db-instance-available --db-instance-identifier lks-wallet-db

DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier lks-wallet-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "DB Endpoint: $DB_ENDPOINT"
```

### 3.3 Connect App to RDS

```bash
sed "s|<RDS_ENDPOINT>|$DB_ENDPOINT|g" k8s/configmap.yaml | kubectl apply -f -
```

### 3.4 Inject DB Password

RDS auto-creates the password in Secrets Manager as `rds!db-<id>-<uuid>`. Pull it, create a canonical `lks/wallet/db` secret (so ExternalSecret in Layer 5 finds it by name), and create the k8s Secret.

```bash
DB_SECRET_ARN=$(aws rds describe-db-instances \
  --db-instance-identifier lks-wallet-db \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)

DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$DB_SECRET_ARN" \
  --query 'SecretString' --output text \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

# Create canonical secret name that ExternalSecret (k8s/external-secret.yaml) references
aws secretsmanager create-secret \
  --name lks/wallet/db \
  --secret-string "{\"password\":\"${DB_PASSWORD}\",\"username\":\"walletadmin\"}" \
  --tags Key=Project,Value=nusantara-wallet 2>/dev/null || \
aws secretsmanager put-secret-value \
  --secret-id lks/wallet/db \
  --secret-string "{\"password\":\"${DB_PASSWORD}\",\"username\":\"walletadmin\"}"

kubectl create secret generic wallet-api-secret \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  -n wallet

kubectl rollout restart deployment/wallet-api -n wallet
kubectl rollout status deployment/wallet-api -n wallet --timeout=300s
```

### 3.5 Test DB Connectivity

```bash
POD=$(kubectl get pod -n wallet -l app=wallet-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $POD -n wallet -- sh -c "nc -zv $DB_ENDPOINT 5432 && echo 'DB reachable!'"
kubectl logs $POD -n wallet | tail -5
# Expected: "Migration complete" and "Listening on :8080"
curl http://$ELB/health/ready
# Expected: HTTP 200
```

**Layer 3 checkpoint:**
- [ ] `nc` shows DB port is reachable from pod
- [ ] Pod logs show `Migration complete` and `Listening on :8080`
- [ ] `/health/ready` returns 200

> **Note:** If deployment spec includes EFS PVC but Layer 4 hasn't run yet, pod stays `Pending` (`wallet-uploads-pvc not found`). Temporarily patch to `emptyDir` so Layer 3 can be tested independently:
> ```bash
> kubectl patch deployment wallet-api -n wallet \
>   --type=json \
>   -p='[{"op":"replace","path":"/spec/template/spec/volumes/0","value":{"name":"uploads","emptyDir":{}}}]'
> # Revert this patch in Layer 4 after EFS PVC is bound.
> ```

---

## Layer 4 — EFS Shared Storage

Multiple pods write payment proof uploads. EFS supports `ReadWriteMany` — EBS does not.

> **AWS Academy constraints in this layer:**
> - `elasticfilesystem:CreateAccessPoint` is blocked → use **static PV provisioning** (pre-created PV that references the EFS filesystem directly — no access point, no CSI controller API calls)
> - `iam:CreateOpenIDConnectProvider` is blocked → install EFS CSI addon **without** `--service-account-role-arn`. Do not pass LabRole ARN either: even with LabRole, the SDK tries `AssumeRoleWithWebIdentity` (OIDC token is mounted in every pod), fails with `No OpenIDConnect provider found`, and never falls back to instance profile
> - The CSI **node** DaemonSet (which actually mounts EFS via NFS) works fine using the node EC2 instance profile — no IRSA needed

### 4.1 EFS Security Group + File System

```bash
# Cluster SG is always attached to pods — more reliable than lks-eks-node-sg
CLUSTER_SG=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

EFS_SG=$(aws ec2 create-security-group \
  --group-name lks-efs-sg \
  --description "EFS mount targets" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id $EFS_SG \
  --protocol tcp --port 2049 --source-group $CLUSTER_SG
# Also allow from lks-eks-node-sg if it exists
[[ -n "$NODE_SG" ]] && aws ec2 authorize-security-group-ingress --group-id $EFS_SG \
  --protocol tcp --port 2049 --source-group $NODE_SG 2>/dev/null || true
aws ec2 create-tags --resources $EFS_SG --tags Key=Name,Value=lks-efs-sg

EFS_ID=$(aws efs create-file-system \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --tags Key=Name,Value=lks-wallet-storage \
  --query 'FileSystemId' --output text)
echo "EFS: $EFS_ID"

echo "Waiting for EFS to be ready..."
sleep 20

aws efs create-mount-target --file-system-id $EFS_ID \
  --subnet-id $PRIV1 --security-groups $EFS_SG 2>/dev/null || {
  sleep 15
  aws efs create-mount-target --file-system-id $EFS_ID \
    --subnet-id $PRIV1 --security-groups $EFS_SG
}
aws efs create-mount-target --file-system-id $EFS_ID \
  --subnet-id $PRIV2 --security-groups $EFS_SG

echo "Waiting for mount targets to be available..."
sleep 45
```

### 4.2 Install EFS CSI Driver

> **No `--service-account-role-arn`** — installing without it causes the addon to use the node EC2 instance profile for any API calls. Static provisioning avoids API calls from the controller entirely, so this is sufficient.

```bash
aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name aws-efs-csi-driver \
  --region $AWS_REGION

aws eks wait addon-active \
  --cluster-name $CLUSTER_NAME --addon-name aws-efs-csi-driver --region $AWS_REGION
echo "EFS CSI Driver active!"

kubectl get pods -n kube-system | grep efs
# Expected: efs-csi-controller (2 pods) and efs-csi-node (1 per node) Running
```

### 4.3 Static PV + PVC

Dynamic provisioning calls `efs:CreateAccessPoint` from the CSI controller — blocked in Academy and the controller can't reach IMDS. Static provisioning pre-creates the PV. The CSI node DaemonSet mounts it via NFS — no EFS API calls at all.

```bash
# Apply StorageClass (needed as provisioner reference in PV/PVC — parameters ignored for static PVs)
sed "s|<EFS_FILE_SYSTEM_ID>|$EFS_ID|g" k8s/storage-class.yaml | kubectl apply -f -

# Create static PV pointing directly to the EFS filesystem
sed "s|<EFS_FILE_SYSTEM_ID>|$EFS_ID|g" k8s/pv.yaml | kubectl apply -f -

# Apply PVC — binds to wallet-uploads-pv by name (no dynamic provisioning triggered)
kubectl apply -f k8s/pvc.yaml

echo "Waiting for PVC to bind..."
kubectl wait pvc/wallet-uploads-pvc -n wallet --for=jsonpath='{.status.phase}'=Bound --timeout=60s
kubectl get pvc -n wallet
# Expected: STATUS=Bound  VOLUME=wallet-uploads-pv
```

### 4.4 Restore Deployment + Test

Re-applying the deployment reverts any `emptyDir` patch that was applied in Layer 3.

```bash
sed "s|<ACCOUNT_ID>|$ACCOUNT_ID|g; s|<AWS_REGION>|$AWS_REGION|g" k8s/deployment.yaml | kubectl apply -f -
kubectl rollout status deployment/wallet-api -n wallet --timeout=300s

# Verify EFS is mounted
POD=$(kubectl get pod -n wallet -l app=wallet-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n wallet $POD -- df -h /app/uploads
# Expected: 127.0.0.1:/ 8.0E 0 8.0E 0% /app/uploads

# Test ReadWriteMany — scale to 2 pods
kubectl scale deployment wallet-api -n wallet --replicas=2
kubectl wait --for=condition=ready pod -l app=wallet-api -n wallet --timeout=60s

PODS=$(kubectl get pods -n wallet -l app=wallet-api -o name | sed 's|pod/||')
P0=$(echo "$PODS" | head -1)
P1=$(echo "$PODS" | tail -1)
kubectl exec -n wallet $P0 -- sh -c "echo 'hello from pod1' > /app/uploads/test.txt"
kubectl exec -n wallet $P1 -- cat /app/uploads/test.txt
# Expected: hello from pod1

kubectl scale deployment wallet-api -n wallet --replicas=1
```

**Layer 4 checkpoint:**
- [ ] `kubectl get pvc -n wallet` shows `STATUS=Bound`
- [ ] `kubectl exec ... df -h /app/uploads` shows `127.0.0.1:/ 8.0E`
- [ ] File written from pod 1 is readable from pod 2

---

## Layer 5 — Secrets Manager

Replace plain ConfigMap credentials with secrets pulled from AWS Secrets Manager.

### 5.1 Create Secrets

```bash
# RDS auto-created the DB password secret — verify:
aws secretsmanager describe-secret --secret-id lks/wallet/db

# Create JWT secret
JWT_SECRET=$(openssl rand -hex 32)
aws secretsmanager create-secret \
  --name lks/wallet/app \
  --secret-string "{\"JWT_SECRET\":\"${JWT_SECRET}\"}" \
  --tags Key=Project,Value=nusantara-wallet
```

### 5.2 App IRSA Role

```bash
cat > /tmp/wallet-app-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "secretsmanager:GetSecretValue",
     "Resource": "arn:aws:secretsmanager:${AWS_REGION}:${ACCOUNT_ID}:secret:lks/wallet/*"},
    {"Effect": "Allow",
     "Action": ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
     "Resource": "*"}
  ]
}
EOF

aws iam create-policy --policy-name LKS-WalletAppPolicy \
  --policy-document file:///tmp/wallet-app-policy.json
WALLET_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/LKS-WalletAppPolicy"

# AWS Academy: iam:CreateRole blocked — use LabRole ARN directly
WALLET_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/LabRole"

kubectl create serviceaccount wallet-api-sa -n wallet
kubectl annotate serviceaccount wallet-api-sa -n wallet \
  eks.amazonaws.com/role-arn=$WALLET_ROLE_ARN
```

### 5.3 Install External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

kubectl rollout status deployment external-secrets -n external-secrets
```

### 5.4 ClusterSecretStore + ExternalSecret

> **Delete the manual secret from Layer 3 first.** ExternalSecret uses `creationPolicy: Owner` — it won't adopt a secret it didn't create.
> ```bash
> kubectl delete secret wallet-api-secret -n wallet
> ```

```bash
kubectl apply -f - << EOF
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-store
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${AWS_REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: wallet-api-sa
            namespace: wallet
EOF

kubectl apply -f - << 'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: wallet-secrets
  namespace: wallet
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-store
    kind: ClusterSecretStore
  target:
    name: wallet-secrets
    creationPolicy: Owner
  data:
  - secretKey: DB_PASSWORD
    remoteRef:
      key: lks/wallet/db
      property: password
  - secretKey: JWT_SECRET
    remoteRef:
      key: lks/wallet/app
      property: JWT_SECRET
EOF

kubectl get externalsecret wallet-secrets -n wallet
# Expected: SecretSynced
```

### 5.5 Inject Secrets into Deployment

```bash
kubectl rollout restart deployment/wallet-api -n wallet
kubectl rollout status deployment/wallet-api -n wallet

# Verify secrets are injected (names only, not values)
POD=$(kubectl get pod -n wallet -l app=wallet-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n wallet $POD -- sh -c "env | grep -E 'DB_PASSWORD|JWT_SECRET' | cut -d= -f1"
# Expected: DB_PASSWORD  JWT_SECRET
```

**Layer 5 checkpoint:**
- [ ] `kubectl get secret wallet-secrets -n wallet` exists and is synced
- [ ] Pods have DB_PASSWORD and JWT_SECRET env vars

---

## Layer 6 — GitHub Actions CI/CD

Everything works manually. Now automate it: `git push` → build → push ECR → deploy to EKS.

### 6.1 GitHub OIDC Provider

> **AWS Academy:** `iam:CreateOpenIDConnectProvider` is blocked. Skip sections 6.1 and 6.2 — use static credentials stored as GitHub secrets instead (see section 6.3).

```bash
# Non-Academy only: skip this block in AWS Academy
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

### 6.2 IAM Role for GitHub Actions

Replace `YOUR_GITHUB_ORG/YOUR_REPO` with your actual repo.

```bash
GITHUB_REPO="YOUR_GITHUB_ORG/YOUR_REPO"

cat > /tmp/github-trust.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:${GITHUB_REPO}:ref:refs/heads/main"
      }
    }
  }]
}
EOF

cat > /tmp/github-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage"
    ], "Resource": "*"},
    {"Effect": "Allow", "Action": "eks:DescribeCluster",
     "Resource": "arn:aws:eks:${AWS_REGION}:${ACCOUNT_ID}:cluster/${CLUSTER_NAME}"}
  ]
}
EOF

aws iam create-role --role-name LKS-GitHubActionsRole \
  --assume-role-policy-document file:///tmp/github-trust.json
aws iam put-role-policy --role-name LKS-GitHubActionsRole \
  --policy-name GitHubActionsPolicy \
  --policy-document file:///tmp/github-policy.json

GITHUB_ROLE_ARN=$(aws iam get-role --role-name LKS-GitHubActionsRole \
  --query 'Role.Arn' --output text)
echo "GitHub Actions Role: $GITHUB_ROLE_ARN"
```

### 6.3 Grant GitHub Actions Access to EKS

```bash
aws eks create-access-entry \
  --cluster-name $CLUSTER_NAME \
  --principal-arn $GITHUB_ROLE_ARN \
  --region $AWS_REGION

aws eks associate-access-policy \
  --cluster-name $CLUSTER_NAME \
  --principal-arn $GITHUB_ROLE_ARN \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy \
  --access-scope type=namespace,namespaces=wallet \
  --region $AWS_REGION
```

### 6.4 Set GitHub Repository Secrets

In GitHub → **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `AWS_ACCOUNT_ID` | Your 12-digit account ID |
| `AWS_REGION` | `ap-southeast-1` |
| `EKS_CLUSTER_NAME` | `lks-wallet-eks` |
| `AWS_ROLE_ARN` | Value of `$GITHUB_ROLE_ARN` |

### 6.5 Test the Pipeline

```bash
# Make a small change and push
echo "# deploy $(date)" >> app/main.go
git add app/main.go
git commit -m "test: trigger CI/CD pipeline"
git push origin main

# Watch in GitHub Actions UI
echo "Watch: https://github.com/${GITHUB_REPO}/actions"
```

The workflow (`.github/workflows/deploy.yml`) runs:
1. **test** — `go test ./...` + `go vet ./...`
2. **build-and-push** — build image, tag with git SHA, push to ECR
3. **deploy** — run DB migration Job → `kubectl set image` → `kubectl rollout status` → auto-rollback on failure

### 6.6 Verify

```bash
# Confirm new image (git SHA) is running
kubectl get pods -n wallet -o wide
kubectl describe pods -n wallet | grep "Image:"
# Should show ECR URI with new SHA tag

kubectl rollout history deployment/wallet-api -n wallet
```

**Layer 6 checkpoint:**
- [ ] All 3 GitHub Actions jobs passed
- [ ] Pod image tag matches the git commit SHA
- [ ] `curl http://$ELB/health/live` returns 200

---

## Cleanup

```bash
# 1. Delete k8s resources
kubectl delete namespace wallet
helm uninstall external-secrets -n external-secrets

# 2. Delete node group
aws eks delete-nodegroup \
  --cluster-name $CLUSTER_NAME --nodegroup-name lks-wallet-ng --region $AWS_REGION
aws eks wait nodegroup-deleted \
  --cluster-name $CLUSTER_NAME --nodegroup-name lks-wallet-ng --region $AWS_REGION

# 3. Delete EKS cluster
aws eks delete-cluster --name $CLUSTER_NAME --region $AWS_REGION
aws eks wait cluster-deleted --name $CLUSTER_NAME --region $AWS_REGION

# 4. Delete RDS
aws rds delete-db-instance \
  --db-instance-identifier lks-wallet-db --skip-final-snapshot
aws rds wait db-instance-deleted --db-instance-identifier lks-wallet-db

# 5. Delete EFS mount targets then file system
for MT in $(aws efs describe-mount-targets --file-system-id $EFS_ID \
  --query 'MountTargets[*].MountTargetId' --output text); do
  aws efs delete-mount-target --mount-target-id $MT
done
sleep 30
aws efs delete-file-system --file-system-id $EFS_ID

# 6. Delete ECR
aws ecr delete-repository --repository-name lks-wallet-api --force

# 7. Delete NAT Gateway + EIP
aws ec2 delete-nat-gateway --nat-gateway-id $NAT
sleep 60
aws ec2 release-address --allocation-id $EIP

# 8. Delete Secrets Manager secrets
aws secretsmanager delete-secret --secret-id lks/wallet/app --force-delete-without-recovery
aws secretsmanager delete-secret --secret-id lks/wallet/db --force-delete-without-recovery

# 9. Delete IAM roles and policies
for ROLE in LKS-GitHubActionsRole LKS-ExternalSecretsRole LKS-WalletAppRole \
            LKS-EFSCSIDriverRole LKS-LBCRole LKS-EKSNodeRole LKS-EKSClusterRole; do
  for P in $(aws iam list-attached-role-policies --role-name $ROLE \
    --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name $ROLE --policy-arn $P
  done
  aws iam delete-role-policy --role-name $ROLE --policy-name GitHubActionsPolicy 2>/dev/null
  aws iam delete-role --role-name $ROLE 2>/dev/null && echo "Deleted $ROLE"
done
for P in $LBC_POLICY_ARN $EFS_POLICY_ARN $WALLET_POLICY_ARN; do
  aws iam delete-policy --policy-arn $P 2>/dev/null
done

# 10. Delete VPC
aws ec2 delete-security-group --group-id $RDS_SG
aws ec2 delete-security-group --group-id $EFS_SG
aws ec2 delete-security-group --group-id $NODE_SG
aws ec2 delete-subnet --subnet-id $PUB1
aws ec2 delete-subnet --subnet-id $PUB2
aws ec2 delete-subnet --subnet-id $PRIV1
aws ec2 delete-subnet --subnet-id $PRIV2
aws ec2 delete-route-table --route-table-id $PUB_RTB
aws ec2 delete-route-table --route-table-id $PRIV_RTB
aws ec2 detach-internet-gateway --internet-gateway-id $IGW --vpc-id $VPC_ID
aws ec2 delete-internet-gateway --internet-gateway-id $IGW
aws ec2 delete-vpc --vpc-id $VPC_ID
aws ec2 delete-key-pair --key-name lks-eks-key

echo "All resources deleted"
```

---

## Final Architecture

```
Internet
    │ HTTP :80
    ▼
Classic ELB  (internet-facing, public subnets)
    │
    ▼
wallet-api pods  (private subnets, m7i-flex.large)
    ├── ConfigMap        → non-sensitive env vars (DB_HOST, PORT, etc.)
    ├── ExternalSecret   → DB_PASSWORD + JWT_SECRET from Secrets Manager
    ├── EFS PVC          → /app/uploads  (ReadWriteMany across pods)
    └── ECR image        → tagged with git commit SHA
    │
    ├── RDS PostgreSQL   (private subnet, port 5432)
    └── EFS              (private subnet, NFS port 2049)

GitHub Actions  (on push to main):
  test  →  build+push to ECR  →  kubectl set image  →  rollout
```

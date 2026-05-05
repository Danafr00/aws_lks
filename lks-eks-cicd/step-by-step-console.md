# Step-by-Step: EKS CI/CD — AWS Console Guide

**Goal**: Deploy a containerized wallet API on EKS, connected to RDS + EFS + Secrets Manager, with a GitHub Actions CI/CD pipeline.  
**Approach**: Build one layer at a time — verify it works before moving to the next.  
**Region**: ap-southeast-1 | **Cost warning**: EKS $0.10/hr, NAT Gateway $0.045/hr — delete after use.

> **Note**: kubectl, helm, and docker commands have no console equivalent. Each layer ends with a short terminal block for those. Everything else can be done in the AWS Console.

---

## Layers

| Layer | Console | Terminal |
|---|---|---|
| **1** | VPC + SGs + Key Pair + IAM + EKS + Node Group + OIDC | Install LBC, deploy Hello App |
| **2** | Create ECR repository | Build + push image, update deployment |
| **3** | RDS subnet group + instance | Connect app to DB |
| **4** | EFS + mount targets + CSI IAM | Install EFS CSI addon, mount into pods |
| **5** | Secrets Manager + App IAM role | Install ESO, create ExternalSecret |
| **6** | GitHub OIDC + IAM role | Push code, watch pipeline |

---

## Layer 1 — EKS Cluster + Hello App

### 1.1 VPC

1. Open [VPC Console](https://console.aws.amazon.com/vpc) → region: **ap-southeast-1**
2. Left sidebar → **Your VPCs** → **Create VPC**
   - Resources to create: **VPC only**
   - Name tag: `lks-wallet-vpc`
   - IPv4 CIDR: `10.10.0.0/16`
   - IPv6: No
3. **Create VPC**
4. Select `lks-wallet-vpc` → **Actions** → **Edit VPC settings**
   - ✅ Enable DNS hostnames
   - ✅ Enable DNS resolution
   - **Save**

---

### 1.2 Subnets

Create 4 subnets total: 2 public (for ALB), 2 private (for nodes, RDS, EFS).

**Public Subnet 1 (AZ a)**
1. **Subnets** → **Create subnet** → VPC: `lks-wallet-vpc`
   - Name: `lks-public-1a`
   - AZ: `ap-southeast-1a`
   - CIDR: `10.10.1.0/24`
2. **Create subnet**
3. Select it → **Actions** → **Edit subnet settings** → ✅ Enable auto-assign public IPv4 → **Save**

**Public Subnet 2 (AZ b)**
1. Same steps:
   - Name: `lks-public-1b` | AZ: `ap-southeast-1b` | CIDR: `10.10.2.0/24`
2. Enable auto-assign public IPv4.

**Private Subnet 1 (AZ a)**
1. Create subnet:
   - Name: `lks-private-1a` | AZ: `ap-southeast-1a` | CIDR: `10.10.10.0/24`
2. Do NOT enable auto-assign public IP.

**Private Subnet 2 (AZ b)**
1. Create subnet:
   - Name: `lks-private-1b` | AZ: `ap-southeast-1b` | CIDR: `10.10.11.0/24`
2. Do NOT enable auto-assign public IP.

---

### 1.3 Subnet Tags

Tags are **required** — LBC uses them to discover where to put the ALB.

**On both public subnets** (`lks-public-1a` and `lks-public-1b`):
1. Select subnet → **Tags** tab → **Manage tags** → **Add tag**

   | Key | Value |
   |---|---|
   | `kubernetes.io/cluster/lks-wallet-eks` | `owned` |
   | `kubernetes.io/role/elb` | `1` |

2. **Save**

**On both private subnets** (`lks-private-1a` and `lks-private-1b`):
1. Select subnet → **Tags** tab → **Manage tags** → **Add tag**

   | Key | Value |
   |---|---|
   | `kubernetes.io/cluster/lks-wallet-eks` | `owned` |
   | `kubernetes.io/role/internal-elb` | `1` |

2. **Save**

---

### 1.4 Internet Gateway

1. **Internet gateways** → **Create internet gateway**
   - Name: `lks-wallet-igw`
2. **Create internet gateway**
3. **Actions** → **Attach to VPC** → `lks-wallet-vpc` → **Attach**

---

### 1.5 Public Route Table

1. **Route tables** → **Create route table**
   - Name: `lks-public-rtb` | VPC: `lks-wallet-vpc`
2. **Create route table**
3. Select it → **Routes** tab → **Edit routes** → **Add route**
   - Destination: `0.0.0.0/0` | Target: **Internet Gateway** → `lks-wallet-igw`
   - **Save changes**
4. **Subnet associations** → **Edit subnet associations**
   - ✅ `lks-public-1a` ✅ `lks-public-1b`
   - **Save associations**

---

### 1.6 NAT Gateway + Private Route Table

Nodes in private subnets need internet access to pull container images from ECR.

**Create Elastic IP:**
1. Left sidebar → **Elastic IPs** → **Allocate Elastic IP address**
   - Network border group: `ap-southeast-1`
   - **Allocate**

**Create NAT Gateway:**
1. Left sidebar → **NAT gateways** → **Create NAT gateway**
   - Name: `lks-wallet-nat`
   - Subnet: `lks-public-1a`
   - Connectivity type: **Public**
   - Elastic IP: select the one you just allocated
2. **Create NAT gateway**
3. ⏳ Wait ~2 minutes for state to become **Available**

**Create Private Route Table:**
1. **Route tables** → **Create route table**
   - Name: `lks-private-rtb` | VPC: `lks-wallet-vpc`
2. Select it → **Routes** tab → **Edit routes** → **Add route**
   - Destination: `0.0.0.0/0` | Target: **NAT Gateway** → `lks-wallet-nat`
   - **Save changes**
3. **Subnet associations** → **Edit subnet associations**
   - ✅ `lks-private-1a` ✅ `lks-private-1b`
   - **Save associations**

---

### 1.7 Security Groups

**Node Security Group:**
1. Left sidebar → **Security groups** → **Create security group**
   - Name: `lks-eks-node-sg`
   - Description: `EKS worker nodes`
   - VPC: `lks-wallet-vpc`
2. **Inbound rules** → **Add rule**:
   - Type: **SSH** | Protocol: TCP | Port: 22 | Source: `0.0.0.0/0`
3. Add another rule:
   - Type: **All traffic** | Source: **Custom** → type `lks-eks-node-sg` (self-referencing — allows node-to-node traffic)
4. **Create security group**

Note the Security Group ID — you will need it when creating the node group.

---

### 1.8 EC2 Key Pair (for SSH to nodes)

1. Open [EC2 Console](https://console.aws.amazon.com/ec2) → left sidebar → **Key Pairs** → **Create key pair**
   - Name: `lks-eks-key`
   - Key pair type: **RSA**
   - Private key file format: **.pem** (Mac/Linux) or **.ppk** (Windows/PuTTY)
2. **Create key pair** — the `.pem` file downloads automatically
3. Move it and set permissions (terminal):
   ```bash
   mv ~/Downloads/lks-eks-key.pem ~/.ssh/
   chmod 400 ~/.ssh/lks-eks-key.pem
   ```

---

### 1.9 IAM Roles

**EKS Cluster Role:**
1. [IAM Console](https://console.aws.amazon.com/iam) → **Roles** → **Create role**
   - Trusted entity type: **AWS service**
   - Use case: scroll to **EKS** → select **EKS – Cluster**
2. **Next** (policy `AmazonEKSClusterPolicy` is pre-selected) → **Next**
3. Role name: `LKS-EKSClusterRole` → **Create role**

**EKS Node Role:**
1. **Create role** → Trusted entity: **AWS service** → Use case: **EC2** (not EKS)
2. **Next** → search and check each:
   - ✅ `AmazonEKSWorkerNodePolicy`
   - ✅ `AmazonEKS_CNI_Policy`
   - ✅ `AmazonEC2ContainerRegistryReadOnly`
   - ✅ `AmazonSSMManagedInstanceCore`
3. **Next** → Role name: `LKS-EKSNodeRole` → **Create role**

**LBC IAM Policy:**

First download the policy JSON (terminal):
```bash
curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json
```

Then in console:
1. IAM Console → **Policies** → **Create policy** → **JSON** tab
2. Paste the full contents of `iam_policy.json`
3. **Next** → Policy name: `AWSLoadBalancerControllerIAMPolicy` → **Create policy**

---

### 1.10 EKS Cluster

1. Open [EKS Console](https://console.aws.amazon.com/eks) → **Clusters** → **Create cluster**

**Step 1 — Configure cluster:**
- Name: `lks-wallet-eks`
- Kubernetes version: `1.31`
- Cluster IAM role: `LKS-EKSClusterRole`
- **Next**

**Step 2 — Specify networking:**
- VPC: `lks-wallet-vpc`
- Subnets: select both **private** subnets (`lks-private-1a`, `lks-private-1b`)
- Security groups: leave blank
- Cluster endpoint access: **Public and private**
- **Next**

**Step 3 — Configure observability:** defaults → **Next**

**Step 4 — Select add-ons:** keep defaults (kube-proxy, CoreDNS, VPC CNI) → **Next**

**Step 5 — Configure add-on settings:** defaults → **Next**

**Step 6 — Review** → **Create**

> ⏳ Wait ~12 minutes for Status: **Active**

Grant your CLI identity cluster-admin access (terminal):
```bash
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=lks-wallet-eks
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CLI_ARN=$(aws sts get-caller-identity --query Arn --output text)

aws eks create-access-entry \
  --cluster-name $CLUSTER_NAME \
  --principal-arn $CLI_ARN \
  --region $AWS_REGION

aws eks associate-access-policy \
  --cluster-name $CLUSTER_NAME \
  --principal-arn $CLI_ARN \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster \
  --region $AWS_REGION
```

Connect kubectl (terminal):
```bash
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
kubectl get svc
```

---

### 1.11 Node Group

> Do NOT use a Launch Template. Select AL2023 from the AMI type dropdown — EKS handles bootstrap automatically.

1. EKS Console → `lks-wallet-eks` → **Compute** tab → **Add node group**

**Step 1 — Configure node group:**
- Name: `lks-wallet-ng`
- Node IAM role: `LKS-EKSNodeRole`
- Leave Launch template toggle **off**
- **Next**

**Step 2 — Compute and scaling:**
- AMI type: **Amazon Linux 2023 (AL2023_x86_64_STANDARD)**
- Capacity type: **On-Demand**
- Instance types: `m7i-flex.large`
- Disk size: 20 GiB
- Scaling: Minimum `2` | Maximum `4` | Desired `2`
- **Next**

**Step 3 — Networking:**
- Subnets: `lks-private-1a` and `lks-private-1b`
- **Allow SSH remote access**: ✅ Enable
  - EC2 Key Pair: `lks-eks-key`
  - Security groups: select `lks-eks-node-sg`
- **Next**

**Step 4 — Review** → **Create**

> ⏳ Wait ~7 minutes for Status: **Active**

Verify nodes (terminal):
```bash
kubectl get nodes
# Expected: 1 node, Status: Ready
```

---

### 1.12 OIDC Provider

1. EKS Console → `lks-wallet-eks` → **Overview** tab → copy **OpenID Connect provider URL**
   - Example: `https://oidc.eks.ap-southeast-1.amazonaws.com/id/ABC123XYZ`
   - Note the **ID** at the end (after `/id/`)

2. IAM Console → **Identity providers** → **Add provider**
   - Provider type: **OpenID Connect**
   - Provider URL: paste the full URL
   - **Get thumbprint** (auto-fills)
   - Audience: `sts.amazonaws.com`
3. **Add provider**

---

### 1.13 LBC IAM Role (IRSA)

1. IAM Console → **Roles** → **Create role**
   - Trusted entity: **Web identity**
   - Identity provider: select the OIDC provider you just added
   - Audience: `sts.amazonaws.com`
2. **Next** → search `AWSLoadBalancerControllerIAMPolicy` → ✅ check it → **Next**
3. Role name: `LKS-LBCRole` → **Create role**

**Restrict the trust policy to the LBC service account:**
1. IAM → **Roles** → `LKS-LBCRole` → **Trust relationships** → **Edit trust policy**
2. Replace the entire `"Condition"` block with (substitute your real OIDC_ID):

```json
"Condition": {
  "StringEquals": {
    "oidc.eks.ap-southeast-1.amazonaws.com/id/OIDC_ID:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
    "oidc.eks.ap-southeast-1.amazonaws.com/id/OIDC_ID:aud": "sts.amazonaws.com"
  }
}
```

3. **Update policy**

---

### 1.14 Install LBC + Deploy Hello App (Terminal)

```bash
# Set variables (run these if you opened a new terminal)
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=lks-wallet-eks
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export VPC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)
export OIDC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION \
  --query "cluster.identity.oidc.issuer" --output text | awk -F'/' '{print $NF}')
export LBC_ROLE_ARN=$(aws iam get-role --role-name LKS-LBCRole --query 'Role.Arn' --output text)

# Install LBC
kubectl create serviceaccount aws-load-balancer-controller -n kube-system
kubectl annotate serviceaccount aws-load-balancer-controller -n kube-system \
  eks.amazonaws.com/role-arn=$LBC_ROLE_ARN

helm repo add eks https://aws.github.io/eks-charts && helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$AWS_REGION \
  --set vpcId=$VPC_ID

kubectl rollout status deployment aws-load-balancer-controller -n kube-system
# Expected: READY 2/2

# Deploy Hello App
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
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wallet-ingress
  namespace: wallet
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}]'
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: wallet-api-svc
            port:
              number: 80
EOF

kubectl get pods -n wallet --watch
# Wait for Running, then Ctrl+C

kubectl get ingress wallet-ingress -n wallet --watch
# Wait for ADDRESS column, then:
ALB=$(kubectl get ingress wallet-ingress -n wallet \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$ALB
# Expected: nginx welcome page
```

**Layer 1 checkpoint:**
- [ ] `kubectl get nodes` shows Ready
- [ ] `curl http://$ALB` returns a response

---

## Layer 2 — ECR + Containerized App

### 2.1 Create ECR Repository (Console)

1. Open [ECR Console](https://console.aws.amazon.com/ecr) → **Repositories** → **Create repository**
   - Visibility: **Private**
   - Repository name: `lks-wallet-api`
   - Tag immutability: **Enabled**
   - Scan on push: **Enabled**
2. **Create repository**

**Add lifecycle policy (keep last 5 tagged images):**
1. Click `lks-wallet-api` → **Lifecycle policy** → **Create rule**
   - Priority: `1`
   - Rule description: `Keep last 5 tagged`
   - Image status: **Tagged**
   - Tag prefixes: `v`
   - Action: **Expire** | Count type: **Image count more than** | Count: `5`
2. **Save**
3. Add second rule:
   - Priority: `2` | Description: `Expire untagged after 1 day`
   - Image status: **Untagged** | Action: **Expire** | Count type: **Since image pushed** | 1 day
4. **Save**

### 2.2 Build + Push + Update Deployment (Terminal)

> **Apple Silicon Mac (M1/M2/M3):** EKS nodes are `amd64`. Build with `--platform linux/amd64` or the pod gets `ImagePullBackOff: no match for platform in manifest`.

```bash
export ECR_URI="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/lks-wallet-api"

# Login to ECR
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin \
  ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

# Build for amd64 and push (from lks-eks-cicd/app/ directory)
cd app/
docker buildx build --platform linux/amd64 \
  -t ${ECR_URI}:v1.0.0 --push .

# Delete hello-app — it has served its purpose
kubectl delete deployment wallet-app -n wallet
echo "Hello-app removed."

# Apply real deployment + service (service.yaml updates selector to app: wallet-api)
# Keep the Layer 1 wallet-ingress for HTTP testing
# k8s/ingress.yaml is production HTTPS — apply in Layer 6 after ACM cert setup
sed "s|<ACCOUNT_ID>|$ACCOUNT_ID|g" k8s/deployment.yaml | kubectl apply -f -
kubectl apply -f k8s/service.yaml

# Pods will CrashLoop until Layer 3 provides ConfigMap + Secret — expected
echo "Pods pending config — continue to Layer 3."
kubectl get pods -n wallet
```

> **ECR immutable tags:** If you need to re-push the same tag (e.g., after fixing platform), disable immutability first in the ECR console: `lks-wallet-api` → **Edit** → Tag immutability: **Disabled**. Or use a new tag (`v1.0.1`).

**Layer 2 checkpoint:**
- [ ] ECR repo shows image in console
- [ ] `kubectl get deployment wallet-api -n wallet` exists

---

## Layer 3 — RDS PostgreSQL

### 3.1 RDS Security Group (Console)

1. VPC Console → **Security groups** → **Create security group**
   - Name: `lks-rds-sg`
   - Description: `RDS PostgreSQL`
   - VPC: `lks-wallet-vpc`
2. **Inbound rules** → **Add rule** (add **two** rules):
   - Rule 1: Type: **PostgreSQL** | Port: 5432 | Source: **Custom** → `lks-eks-node-sg`
   - Rule 2: Type: **PostgreSQL** | Port: 5432 | Source: **Custom** → `eks-cluster-sg-lks-wallet-eks-*` (the auto-created cluster SG — find it by searching `lks-wallet-eks` in the SG search box)
3. **Create security group**

> **Why two rules?** EKS auto-creates a cluster SG and attaches it to every pod. The `lks-eks-node-sg` covers SSH but pods egress through the cluster SG. Without it, pods get connection timeout even though the node SG is allowed.

---

### 3.2 RDS DB Subnet Group (Console)

1. Open [RDS Console](https://console.aws.amazon.com/rds) → left sidebar → **Subnet groups** → **Create DB subnet group**
   - Name: `lks-wallet-db-subnet`
   - Description: `Wallet DB subnets`
   - VPC: `lks-wallet-vpc`
   - AZs: `ap-southeast-1a`, `ap-southeast-1b`
   - Subnets: select `lks-private-1a` and `lks-private-1b`
2. **Create**

---

### 3.3 Create RDS Instance (Console)

1. RDS Console → **Databases** → **Create database**

**Method:** Standard create

**Engine options:**
- Engine: **PostgreSQL**
- Engine version: **PostgreSQL 16.3**

**Templates:** Free tier (or Dev/Test if free tier is not available)

**Settings:**
- DB instance identifier: `lks-wallet-db`
- Master username: `walletadmin`
- Credentials management: **Managed in AWS Secrets Manager** (auto-creates the password secret)

**Instance configuration:**
- DB instance class: `db.t3.micro`

**Storage:**
- Storage type: `gp2` | Allocated: 20 GiB
- ❌ Disable storage autoscaling (not needed for exam)

**Connectivity:**
- VPC: `lks-wallet-vpc`
- DB subnet group: `lks-wallet-db-subnet`
- Public access: **No**
- VPC security group: **Choose existing** → remove default → add `lks-rds-sg`
- AZ: `ap-southeast-1a`

**Additional configuration:**
- Initial database name: `wallet_db`
- Backup retention: `0 days` (disables backups — saves time)

**Create database**

> ⏳ Wait ~10 minutes for Status: **Available**

Note the endpoint:
1. Click `lks-wallet-db` → **Connectivity & security** → copy the **Endpoint**

---

### 3.4 Connect App to RDS (Terminal)

```bash
DB_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier lks-wallet-db \
  --query 'DBInstances[0].Endpoint.Address' --output text)
echo "DB: $DB_ENDPOINT"

sed "s|<RDS_ENDPOINT>|$DB_ENDPOINT|g" k8s/configmap.yaml | kubectl apply -f -
```

### 3.5 Inject DB Password (Terminal)

RDS stored the password in Secrets Manager. Pull it and inject into the deployment. (Layer 5 replaces this with ExternalSecrets.)

```bash
DB_SECRET_ARN=$(aws rds describe-db-instances \
  --db-instance-identifier lks-wallet-db \
  --query 'DBInstances[0].MasterUserSecret.SecretArn' --output text)

DB_PASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "$DB_SECRET_ARN" \
  --query 'SecretString' --output text \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

kubectl create secret generic wallet-api-secret \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  -n wallet

kubectl rollout restart deployment/wallet-api -n wallet
kubectl rollout status deployment/wallet-api -n wallet --timeout=300s

# Test
POD=$(kubectl get pod -n wallet -l app=wallet-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $POD -n wallet -- sh -c "nc -zv $DB_ENDPOINT 5432 && echo 'DB reachable!'"
kubectl logs $POD -n wallet | tail -5
# Expected: "Migration complete" and "Listening on :8080"
```

**Layer 3 checkpoint:**
- [ ] `nc` shows DB port is reachable
- [ ] Pod logs show `Migration complete` and `Listening on :8080`
- [ ] `/health/ready` returns 200

---

## Layer 4 — EFS Shared Storage

Multiple pods need to share uploaded files. EFS supports `ReadWriteMany` — EBS does not.

### 4.1 EFS Security Group (Console)

1. VPC Console → **Security groups** → **Create security group**
   - Name: `lks-efs-sg`
   - Description: `EFS mount targets`
   - VPC: `lks-wallet-vpc`
2. **Inbound rules** → **Add rule**:
   - Type: **NFS** | Port: 2049 | Source: **Custom** → `lks-eks-node-sg`
3. **Create security group**

---

### 4.2 Create EFS File System (Console)

1. Open [EFS Console](https://console.aws.amazon.com/efs) → **Create file system**
   - Name: `lks-wallet-storage`
   - VPC: `lks-wallet-vpc`
2. **Customize** (don't use Quick Create — you need to set mount targets)

**Step 1 — File system settings:**
- Performance mode: **General Purpose**
- Throughput mode: **Bursting**
- **Next**

**Step 2 — Network access:**
- For each AZ (`ap-southeast-1a`, `ap-southeast-1b`):
  - Subnet: select the private subnet (`lks-private-1a` / `lks-private-1b`)
  - Security group: remove the default → add `lks-efs-sg`
- **Next**

**Step 3 — File system policy:** skip → **Next**

**Step 4 — Review** → **Create**

Note the **File system ID** (e.g., `fs-0abc123def`)

> ⏳ Wait ~1 minute for mount targets state: **Available**

---

### 4.3 EFS CSI Driver IAM (Console)

**Create EFS CSI Policy:**
1. IAM Console → **Policies** → **Create policy** → **JSON** tab → paste:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": [
      "elasticfilesystem:DescribeAccessPoints",
      "elasticfilesystem:DescribeFileSystems",
      "elasticfilesystem:DescribeMountTargets",
      "ec2:DescribeAvailabilityZones"
    ], "Resource": "*"},
    {"Effect": "Allow", "Action": ["elasticfilesystem:CreateAccessPoint"],
     "Resource": "*",
     "Condition": {"StringLike": {"aws:RequestTag/efs.csi.aws.com/cluster": "true"}}},
    {"Effect": "Allow", "Action": ["elasticfilesystem:TagResource"],
     "Resource": "*",
     "Condition": {"StringLike": {"aws:ResourceTag/efs.csi.aws.com/cluster": "true"}}},
    {"Effect": "Allow", "Action": "elasticfilesystem:DeleteAccessPoint",
     "Resource": "*",
     "Condition": {"StringEquals": {"aws:ResourceTag/efs.csi.aws.com/cluster": "true"}}}
  ]
}
```

2. **Next** → Policy name: `LKS-EFSCSIPolicy` → **Create policy**

**Create EFS CSI Role:**
1. IAM → **Roles** → **Create role**
   - Trusted entity: **Web identity**
   - Identity provider: your OIDC provider
   - Audience: `sts.amazonaws.com`
2. **Next** → search and select `LKS-EFSCSIPolicy` → **Next**
3. Role name: `LKS-EFSCSIDriverRole` → **Create role**

**Restrict trust policy to EFS CSI service account:**
1. IAM → **Roles** → `LKS-EFSCSIDriverRole` → **Trust relationships** → **Edit trust policy**
2. Replace the `"Condition"` block (substitute your real OIDC_ID):

```json
"Condition": {
  "StringEquals": {
    "oidc.eks.ap-southeast-1.amazonaws.com/id/OIDC_ID:sub": "system:serviceaccount:kube-system:efs-csi-controller-sa",
    "oidc.eks.ap-southeast-1.amazonaws.com/id/OIDC_ID:aud": "sts.amazonaws.com"
  }
}
```

3. **Update policy**

---

### 4.4 Install EFS CSI Driver (Console)

1. EKS Console → `lks-wallet-eks` → **Add-ons** tab → **Get more add-ons**
2. Search for `Amazon EFS CSI Driver` → select it → **Next**
3. Version: keep default (latest)
4. IAM role for service account: select `LKS-EFSCSIDriverRole`
5. **Next** → **Create**

> ⏳ Wait ~1 minute for Status: **Active**

---

### 4.5 Mount EFS into Pods (Terminal)

`deployment.yaml` already has the EFS volume mount defined — no patch needed.

```bash
EFS_ID=$(aws efs describe-file-systems \
  --query 'FileSystems[?Name==`lks-wallet-storage`].FileSystemId' \
  --output text)
echo "EFS: $EFS_ID"

sed "s|<EFS_FILE_SYSTEM_ID>|$EFS_ID|g" k8s/storage-class.yaml | kubectl apply -f -
kubectl apply -f k8s/pvc.yaml

echo "Waiting for PVC to bind..."
kubectl wait pvc/wallet-uploads-pvc -n wallet --for=jsonpath='{.status.phase}'=Bound --timeout=60s
kubectl get pvc -n wallet

kubectl rollout restart deployment/wallet-api -n wallet

kubectl apply -f k8s/storage-class.yaml
kubectl rollout status deployment/wallet-api -n wallet

# Test ReadWriteMany — scale to 2 pods
kubectl scale deployment wallet-api -n wallet --replicas=2
kubectl wait --for=condition=ready pod -l app=wallet-api -n wallet --timeout=60s

PODS=($(kubectl get pods -n wallet -l app=wallet-api -o name))
kubectl exec -n wallet ${PODS[0]} -- sh -c "echo 'hello from pod1' > /app/uploads/test.txt"
kubectl exec -n wallet ${PODS[1]} -- cat /app/uploads/test.txt
# Expected: hello from pod1
```

**Layer 4 checkpoint:**
- [ ] `kubectl get pvc -n wallet` shows `Bound`
- [ ] File written by pod 1 is readable by pod 2

---

## Layer 5 — Secrets Manager

Replace plain ConfigMap credentials with secrets pulled from AWS Secrets Manager.

### 5.1 Create JWT Secret (Console)

1. Open [Secrets Manager Console](https://console.aws.amazon.com/secretsmanager) → **Store a new secret**
2. Secret type: **Other type of secret**
3. Key/value pairs → **Add row**:
   - Key: `JWT_SECRET` | Value: any long random string (e.g., paste output of `openssl rand -hex 32`)
4. **Next**
5. Secret name: `lks/wallet/app`
6. Add tag: Key=`Project` Value=`nusantara-wallet`
7. **Next** → **Next** → **Store**

> The DB password secret (`lks/wallet/db`) was auto-created by RDS when you chose "Managed in AWS Secrets Manager". Verify it exists in the console.

---

### 5.2 App IAM Policy + Role (Console)

**Create App Policy:**
1. IAM → **Policies** → **Create policy** → **JSON** tab → paste (replace `ACCOUNT_ID` and `AWS_REGION`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "secretsmanager:GetSecretValue",
     "Resource": "arn:aws:secretsmanager:ap-southeast-1:ACCOUNT_ID:secret:lks/wallet/*"},
    {"Effect": "Allow",
     "Action": ["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
     "Resource": "*"}
  ]
}
```

2. Policy name: `LKS-WalletAppPolicy` → **Create policy**

**Create App Role:**
1. IAM → **Roles** → **Create role**
   - Trusted entity: **Web identity**
   - Identity provider: your OIDC provider
   - Audience: `sts.amazonaws.com`
2. **Next** → select `LKS-WalletAppPolicy` → **Next**
3. Role name: `LKS-WalletAppRole` → **Create role**

**Restrict trust policy to wallet service account:**
1. IAM → **Roles** → `LKS-WalletAppRole` → **Trust relationships** → **Edit trust policy**
2. Replace the `"Condition"` block (substitute your real OIDC_ID):

```json
"Condition": {
  "StringEquals": {
    "oidc.eks.ap-southeast-1.amazonaws.com/id/OIDC_ID:sub": "system:serviceaccount:wallet:wallet-api-sa",
    "oidc.eks.ap-southeast-1.amazonaws.com/id/OIDC_ID:aud": "sts.amazonaws.com"
  }
}
```

3. **Update policy**

---

### 5.3 Install ESO + Pull Secrets (Terminal)

> **Delete the manual secret from Layer 3 first.** ExternalSecret uses `creationPolicy: Owner` — it won't adopt a secret it didn't create.
> ```bash
> kubectl delete secret wallet-api-secret -n wallet
> ```

```bash
export WALLET_ROLE_ARN=$(aws iam get-role --role-name LKS-WalletAppRole \
  --query 'Role.Arn' --output text)

# Create and annotate service account
kubectl create serviceaccount wallet-api-sa -n wallet
kubectl annotate serviceaccount wallet-api-sa -n wallet \
  eks.amazonaws.com/role-arn=$WALLET_ROLE_ARN

# Install External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io && helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

kubectl rollout status deployment external-secrets -n external-secrets

# ClusterSecretStore
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

# ExternalSecret — pulls both secrets into one K8s Secret
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

kubectl rollout restart deployment/wallet-api -n wallet
kubectl rollout status deployment/wallet-api -n wallet

# Verify secrets are injected (names only, not values)
POD=$(kubectl get pod -n wallet -l app=wallet-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n wallet $POD -- sh -c "env | grep -E 'DB_PASSWORD|JWT_SECRET' | cut -d= -f1"
# Expected: DB_PASSWORD  JWT_SECRET
```

**Layer 5 checkpoint:**
- [ ] `kubectl get secret wallet-secrets -n wallet` exists
- [ ] Pods have `DB_PASSWORD` and `JWT_SECRET` env vars

---

## Layer 6 — GitHub Actions CI/CD

### 6.1 Register GitHub OIDC Provider (Console)

1. IAM Console → **Identity providers** → **Add provider**
   - Provider type: **OpenID Connect**
   - Provider URL: `https://token.actions.githubusercontent.com`
   - **Get thumbprint** (auto-fills)
   - Audience: `sts.amazonaws.com`
2. **Add provider**

---

### 6.2 IAM Role for GitHub Actions (Console)

**Create Role:**
1. IAM → **Roles** → **Create role**
   - Trusted entity: **Web identity**
   - Identity provider: `token.actions.githubusercontent.com`
   - Audience: `sts.amazonaws.com`
2. **Next** → skip policies for now (you'll add them inline) → **Next**
3. Role name: `LKS-GitHubActionsRole` → **Create role**

**Add inline policy:**
1. Click `LKS-GitHubActionsRole` → **Add permissions** → **Create inline policy** → **JSON** tab:

```json
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
     "Resource": "arn:aws:eks:ap-southeast-1:ACCOUNT_ID:cluster/lks-wallet-eks"}
  ]
}
```

   Replace `ACCOUNT_ID` with your actual account ID.
2. Policy name: `GitHubActionsPolicy` → **Create policy**

**Restrict trust policy to your repository:**
1. `LKS-GitHubActionsRole` → **Trust relationships** → **Edit trust policy**
2. Replace the `"Condition"` block (replace `YOUR_ORG/YOUR_REPO`):

```json
"Condition": {
  "StringEquals": {
    "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
  },
  "StringLike": {
    "token.actions.githubusercontent.com:sub": "repo:YOUR_ORG/YOUR_REPO:ref:refs/heads/main"
  }
}
```

3. **Update policy**

---

### 6.3 Grant GitHub Actions Access to EKS (Terminal)

```bash
GITHUB_ROLE_ARN=$(aws iam get-role --role-name LKS-GitHubActionsRole \
  --query 'Role.Arn' --output text)

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

---

### 6.4 GitHub Repository Secrets (GitHub UI)

In your repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**:

| Secret name | Value |
|---|---|
| `AWS_ACCOUNT_ID` | Your 12-digit account ID |
| `AWS_REGION` | `ap-southeast-1` |
| `EKS_CLUSTER_NAME` | `lks-wallet-eks` |
| `AWS_ROLE_ARN` | ARN of `LKS-GitHubActionsRole` (copy from IAM console) |

---

### 6.5 Trigger and Verify (Terminal)

```bash
# Make a small change and push
echo "# deploy $(date)" >> app/main.go
git add app/main.go
git commit -m "test: trigger CI/CD pipeline"
git push origin main
```

Watch the GitHub Actions tab in your repo. The workflow runs:
1. **test** — unit tests
2. **build-and-push** — build image, tag with git SHA, push to ECR
3. **deploy** — `kubectl set image` → `kubectl rollout status`

Verify after pipeline completes:
```bash
kubectl describe pods -n wallet | grep "Image:"
# Should show ECR URI with the new git SHA tag
```

**Layer 6 checkpoint:**
- [ ] All 3 GitHub Actions jobs passed (green)
- [ ] Pod image tag in kubectl matches the git commit SHA
- [ ] `curl http://$ALB/health/live` returns 200

---

## Cleanup

**Do this in order — Kubernetes resources first to remove the ALB.**

### Console: EKS → delete node group then cluster

1. EKS Console → `lks-wallet-eks` → **Compute** tab
2. Select `lks-wallet-ng` → **Delete** → confirm
3. ⏳ Wait ~5 minutes
4. **Overview** → **Delete cluster** → type `lks-wallet-eks` → **Delete**
5. ⏳ Wait ~5 minutes

### Console: RDS → delete instance

1. RDS Console → **Databases** → `lks-wallet-db` → **Actions** → **Delete**
   - ❌ Uncheck "Create final snapshot"
   - ✅ Check "I acknowledge..."
   - Type `delete me` → **Delete**

### Console: EFS → delete file system

1. EFS Console → select `lks-wallet-storage` → **Delete**
   - Type the file system ID to confirm

### Console: ECR → delete repository

1. ECR Console → select `lks-wallet-api` → **Delete** → type `delete` → **Delete**

### Console: Secrets Manager → delete secrets

1. Secrets Manager → `lks/wallet/app` → **Actions** → **Delete secret**
   - Waiting period: 0 days → **Schedule deletion**
2. Repeat for `lks/wallet/db`

### Console: IAM → delete roles and policies

Delete roles in this order (detach policies first if needed):
1. `LKS-GitHubActionsRole`
2. `LKS-WalletAppRole`
3. `LKS-EFSCSIDriverRole`
4. `LKS-LBCRole`
5. `LKS-EKSNodeRole`
6. `LKS-EKSClusterRole`

Delete custom policies:
- `LKS-WalletAppPolicy`
- `LKS-EFSCSIPolicy`
- `AWSLoadBalancerControllerIAMPolicy`

Delete identity providers:
- `oidc.eks.ap-southeast-1.amazonaws.com/id/...` (EKS OIDC)
- `token.actions.githubusercontent.com` (GitHub OIDC)

### Console: NAT Gateway + Elastic IP

1. VPC Console → **NAT gateways** → `lks-wallet-nat` → **Actions** → **Delete NAT gateway**
2. ⏳ Wait for deletion (~1 min)
3. **Elastic IPs** → select the unassociated IP → **Actions** → **Release Elastic IP address**

### Console: VPC → delete networking (order matters)

1. **Internet gateways** → detach `lks-wallet-igw` from VPC → then delete it
2. **Subnets** → delete all 4 subnets
3. **Route tables** → delete `lks-public-rtb` and `lks-private-rtb`
4. **Security groups** → delete `lks-eks-node-sg`, `lks-rds-sg`, `lks-efs-sg`
5. **Your VPCs** → `lks-wallet-vpc` → **Actions** → **Delete VPC** → confirm

### Console: EC2 Key Pair

1. EC2 Console → **Key Pairs** → `lks-eks-key` → **Actions** → **Delete** → confirm

---

## Final Architecture

```
Internet
    │ HTTP :80
    ▼
ALB  (internet-facing, public subnets)
    │
    ▼
wallet-api pods  (private subnets, m7i-flex.large, AL2023)
    ├── ConfigMap        → DB_HOST, PORT, etc.
    ├── ExternalSecret   → DB_PASSWORD + JWT_SECRET from Secrets Manager
    ├── EFS PVC          → /app/uploads  (ReadWriteMany)
    └── ECR image        → tagged with git SHA
    │
    ├── RDS PostgreSQL   (private subnet, port 5432)
    └── EFS              (private subnet, NFS port 2049)

GitHub Actions (on push to main):
  test → build+push to ECR → kubectl set image → rollout
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Node group stuck `CREATING` | Launch template or wrong AMI | Delete, re-create with AL2023 and no launch template |
| LBC pods not ready after 5 min | IAM trust policy wrong OIDC ID or SA name | Re-check trust policy condition in IAM |
| Ingress has no ADDRESS | Subnet tags missing or wrong cluster name | Verify all 4 subnets have `kubernetes.io/cluster/lks-wallet-eks` tag |
| `ExternalSecret` not syncing | App role can't read Secrets Manager | Check role policy has the correct secret ARN pattern |
| EFS PVC stuck `Pending` | EFS CSI driver not running | Check `kubectl get pods -n kube-system \| grep efs` |
| GitHub Actions `Unauthorized` to EKS | Access entry missing | Run `aws eks create-access-entry` + `associate-access-policy` |
| `ImagePullBackOff: no match for platform` | Image built on Apple Silicon (arm64) but nodes are amd64 | Rebuild with `docker buildx build --platform linux/amd64` |
| ALB returns 502 after switching to Go app | Service `targetPort` still set to 80 (nginx default) but Go app listens on 8080 | `kubectl patch svc wallet-api-svc -n wallet --type=json -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'` |
| Pod connection timeout to RDS despite SG rule | Rule allows `lks-eks-node-sg` but pods use the auto-created EKS cluster SG | Add inbound rule for `eks-cluster-sg-lks-wallet-eks-*` SG on port 5432 |
| App restarts with `DB not ready` even after RDS fix | `DB_PASSWORD` env var missing — app can't auth | Create `wallet-api-secret` from Secrets Manager and patch deployment (see step 3.5) |
| ECR push fails `tag already exists and cannot be overwritten` | ECR immutable tags enabled | Disable immutability in ECR console or use a new tag version |

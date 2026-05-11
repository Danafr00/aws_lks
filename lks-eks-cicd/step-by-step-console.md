# Step-by-Step: EKS CI/CD — AWS Console Guide

**Goal**: Deploy a containerized wallet API on EKS, connected to RDS + EFS + Secrets Manager, with a GitHub Actions CI/CD pipeline.  
**Approach**: Build one layer at a time — verify it works before moving to the next.  
**Region**: us-east-1 | **Cost warning**: EKS $0.10/hr, NAT Gateway $0.045/hr — delete after use.

> **AWS Academy constraints (live-confirmed):**
> - `iam:CreateRole` and `iam:CreateOpenIDConnectProvider` both blocked
> - Use `LabRole` for all roles: EKS cluster, node group, EFS CSI, app workloads
> - OIDC/IRSA blocked → ESO uses node instance profile via IMDS (no auth needed)
> - Use `Service type=LoadBalancer` (Classic ELB via in-tree cloud provider) — no AWS Load Balancer Controller
> - GitHub Actions OIDC not available → use manual build+push+deploy (Layer 6)
> - Region: **us-east-1** | ap-southeast-1 blocked for all services

> **Note**: kubectl, helm, and docker commands have no console equivalent. Each layer ends with a short terminal block for those. Everything else can be done in the AWS Console.

---

## Layers

| Layer | Console | Terminal |
|---|---|---|
| **1** | VPC + SGs + Key Pair + EKS + Node Group | Deploy Hello App with Classic ELB |
| **2** | Create ECR repository | Build + push image, update deployment |
| **3** | RDS subnet group + instance | Connect app to DB |
| **4** | EFS + mount targets + CSI add-on | Install EFS CSI addon, mount into pods |
| **5** | Secrets Manager + service account | Install ESO, create ExternalSecret |
| **6** | — | Build + push to ECR, kubectl set image |

---

## Layer 1 — EKS Cluster + Hello App

### 1.1 VPC

1. Open [VPC Console](https://console.aws.amazon.com/vpc) → region: **us-east-1**
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

Create 4 subnets total: 2 public (for Classic ELB), 2 private (for nodes, RDS, EFS).

**Public Subnet 1 (AZ a)**
1. **Subnets** → **Create subnet** → VPC: `lks-wallet-vpc`
   - Name: `lks-public-1a`
   - AZ: `us-east-1a`
   - CIDR: `10.10.1.0/24`
2. **Create subnet**
3. Select it → **Actions** → **Edit subnet settings** → ✅ Enable auto-assign public IPv4 → **Save**

**Public Subnet 2 (AZ b)**
1. Same steps:
   - Name: `lks-public-1b` | AZ: `us-east-1b` | CIDR: `10.10.2.0/24`
2. Enable auto-assign public IPv4.

**Private Subnet 1 (AZ a)**
1. Create subnet:
   - Name: `lks-private-1a` | AZ: `us-east-1a` | CIDR: `10.10.10.0/24`
2. Do NOT enable auto-assign public IP.

**Private Subnet 2 (AZ b)**
1. Create subnet:
   - Name: `lks-private-1b` | AZ: `us-east-1b` | CIDR: `10.10.11.0/24`
2. Do NOT enable auto-assign public IP.

---

### 1.3 Subnet Tags

Tags are **required** — the EKS in-tree cloud provider uses them to discover which subnets to place the Classic ELB in.

> **Important:** Use your actual cluster name in the tag key (e.g. `lks-wallet-eks-dana` not just `lks-wallet-eks`).

**On both public subnets** (`lks-public-1a` and `lks-public-1b`):
1. Select subnet → **Tags** tab → **Manage tags** → **Add tag**

   | Key | Value |
   |---|---|
   | `kubernetes.io/cluster/<your-cluster-name>` | `owned` |
   | `kubernetes.io/role/elb` | `1` |

2. **Save**

**On both private subnets** (`lks-private-1a` and `lks-private-1b`):
1. Select subnet → **Tags** tab → **Manage tags** → **Add tag**

   | Key | Value |
   |---|---|
   | `kubernetes.io/cluster/<your-cluster-name>` | `owned` |
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
   - Network border group: `us-east-1`
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

> **AWS Academy:** `iam:CreateRole` is blocked. Use `LabRole` for both the EKS cluster role and node role. LabRole trust policy already includes `eks.amazonaws.com` and `ec2.amazonaws.com`.

| Role purpose | Role name to use |
|---|---|
| EKS Cluster Role | `LabRole` |
| EKS Node Role | `LabRole` |

---

### 1.10 EKS Cluster

1. Open [EKS Console](https://console.aws.amazon.com/eks) → **Clusters** → **Create cluster**

**Step 1 — Configure cluster:**
- Name: `lks-wallet-eks`
- Kubernetes version: `1.31`
- Cluster IAM role: `LabRole`
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

Grant your identity cluster-admin access (Console):

1. EKS Console → `lks-wallet-eks` → **Access** tab → **Create access entry**
2. **IAM principal ARN**: paste your voclabs ARN from `AWS Details` → `AWS CLI` → `aws_sts_credentials_command` → copy the `--role-arn` value (looks like `arn:aws:sts::ACCOUNT_ID:assumed-role/voclabs/...`)
   - Alternatively run in terminal: `aws sts get-caller-identity --query Arn --output text`
3. **Type**: **Standard**
4. **Next** → **Add access policy**:
   - Policy name: `AmazonEKSClusterAdminPolicy`
   - Access scope: **Cluster**
5. **Add policy** → **Next** → **Create**

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
- Node IAM role: `LabRole`
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
# Expected: 2 nodes, Status: Ready
```

---

### 1.12 Deploy Hello App (Terminal)

> **AWS Academy:** OIDC provider creation is blocked. Skip LBC entirely — use `Service type=LoadBalancer`. The EKS in-tree cloud provider creates a Classic ELB using the cluster's IAM role (which already has `elasticloadbalancing:*` via `AmazonEKSClusterPolicy`). No OIDC, no Helm, no extra IAM needed.

```bash
# Set variables (run these if you opened a new terminal)
export AWS_REGION=us-east-1
export CLUSTER_NAME=lks-wallet-eks   # use your actual cluster name
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

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
  type: LoadBalancer
EOF

kubectl get pods -n wallet --watch
# Wait for Running, then Ctrl+C

kubectl get svc wallet-api-svc -n wallet --watch
# Wait for EXTERNAL-IP column (takes 1-2 min), then:
ELB=$(kubectl get svc wallet-api-svc -n wallet \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$ELB
# Expected: nginx welcome page
```

**Layer 1 checkpoint:**
- [ ] `kubectl get nodes` shows Ready
- [ ] `curl http://$ELB` returns a response

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

# Apply real deployment + service (service.yaml keeps type: LoadBalancer from Layer 1)
sed "s|<ACCOUNT_ID>|$ACCOUNT_ID|g; s|<AWS_REGION>|$AWS_REGION|g" k8s/deployment.yaml | kubectl apply -f -
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
   - AZs: `us-east-1a`, `us-east-1b`
   - Subnets: select `lks-private-1a` and `lks-private-1b`
2. **Create**

---

### 3.3 Create RDS Instance (Console)

1. RDS Console → **Databases** → **Create database**

**Method:** Standard create

**Engine options:**
- Engine: **PostgreSQL**
- Engine version: **PostgreSQL 16.6**

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
- AZ: `us-east-1a`

**Additional configuration:**
- Initial database name: `wallet_db`
- Backup retention: `0 days` (disables backups — saves time)

**Create database**

> ⏳ Wait ~10 minutes for Status: **Available**

Note the endpoint:
1. Click `lks-wallet-db` → **Connectivity & security** → copy the **Endpoint**

---

### 3.4 Connect App to RDS (Terminal)

Get the endpoint from Console first:
1. **RDS Console** → **Databases** → `lks-wallet-db` → **Connectivity & security** → copy the **Endpoint** value

```bash
# Paste the endpoint you copied from Console
DB_ENDPOINT="paste-rds-endpoint-here.rds.amazonaws.com"

sed "s|<RDS_ENDPOINT>|$DB_ENDPOINT|g" k8s/configmap.yaml | kubectl apply -f -
```

### 3.5 Inject DB Password (Terminal)

RDS stored the password in Secrets Manager. Pull it from Console:
1. **RDS Console** → `lks-wallet-db` → **Configuration** tab → copy the **Master credentials ARN** (or find in **Secrets Manager Console** under `rds!db-...`)
2. **Secrets Manager Console** → click the secret → **Retrieve secret value** → copy the `password` value

```bash
# Paste the password you retrieved from Secrets Manager Console
DB_PASSWORD="paste-password-here"

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
2. **Inbound rules** → **Add rule** (add **two** rules):
   - Rule 1: Type: **NFS** | Port: 2049 | Source: **Custom** → search for `eks-cluster-sg-lks-wallet` and select the auto-created cluster SG
   - Rule 2: Type: **NFS** | Port: 2049 | Source: **Custom** → `lks-eks-node-sg` (if it exists — skip if not found)
3. **Create security group**

> **Why cluster SG?** EKS attaches the cluster SG to every pod. The CSI node DaemonSet (which does the actual EFS NFS mount) runs with the node's SGs. Using the cluster SG ensures both pods and node agents can reach the EFS mount targets.

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
- For each AZ (`us-east-1a`, `us-east-1b`):
  - Subnet: select the private subnet (`lks-private-1a` / `lks-private-1b`)
  - Security group: remove the default → add `lks-efs-sg`
- **Next**

**Step 3 — File system policy:** skip → **Next**

**Step 4 — Review** → **Create**

Note the **File system ID** (e.g., `fs-0abc123def`)

> ⏳ Wait ~1 minute for mount targets state: **Available**

---

### 4.3 EFS CSI Driver IAM

> **AWS Academy:** No IAM setup needed for this layer. We use **static PV provisioning** — the CSI node DaemonSet mounts EFS via NFS directly. The CSI controller (which would need EFS API credentials) is bypassed entirely.
>
> Do **not** attach a service account role ARN in the next step. Even attaching `LabRole` causes the SDK to try `AssumeRoleWithWebIdentity` (fails: no OIDC provider in Academy) and never falls back to the instance profile.

---

### 4.4 Install EFS CSI Driver (Console)

1. EKS Console → `lks-wallet-eks` → **Add-ons** tab → **Get more add-ons**
2. Search for `Amazon EFS CSI Driver` → select it → **Next**
3. Version: keep default (latest)
4. **IAM role for service account: leave blank** (do not enter any role ARN)
5. **Next** → **Create**

> ⏳ Wait ~1 minute for Status: **Active**

Verify addon pods are running (terminal):
```bash
kubectl get pods -n kube-system | grep efs
# Expected: efs-csi-controller (2 pods) and efs-csi-node (1 per node) Running
```

---

### 4.5 Mount EFS into Pods (Terminal)

Uses **static PV provisioning** — pre-creates the PersistentVolume pointing to the EFS filesystem directly. The PVC binds to it by name. No dynamic access point creation needed.

Get the EFS File System ID from Console first:
1. **EFS Console** → click `lks-wallet-storage` → copy the **File system ID** (format: `fs-xxxxxxxxx`)

```bash
# Paste the File System ID you copied from EFS Console
EFS_ID="fs-xxxxxxxxx"

# Apply StorageClass (needed as provisioner reference — parameters ignored for static PVs)
sed "s|<EFS_FILE_SYSTEM_ID>|$EFS_ID|g" k8s/storage-class.yaml | kubectl apply -f -

# Create static PV pointing directly to the EFS filesystem (no access point)
sed "s|<EFS_FILE_SYSTEM_ID>|$EFS_ID|g" k8s/pv.yaml | kubectl apply -f -

# Apply PVC — binds to wallet-uploads-pv by name
kubectl apply -f k8s/pvc.yaml

echo "Waiting for PVC to bind..."
kubectl wait pvc/wallet-uploads-pvc -n wallet --for=jsonpath='{.status.phase}'=Bound --timeout=60s
kubectl get pvc -n wallet
# Expected: STATUS=Bound  VOLUME=wallet-uploads-pv

# Re-apply deployment (reverts any emptyDir workaround from Layer 3)
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

### 5.2 App Service Account (Terminal)

> **AWS Academy:** `iam:CreateOpenIDConnectProvider` is blocked — IRSA is unavailable. Pods use the node EC2 instance profile (LabRole) via IMDS automatically. No role annotation needed on the service account.

```bash
# Service account created so ESO can reference it; no role annotation needed
kubectl create serviceaccount wallet-api-sa -n wallet
```

---

### 5.3 Install ESO + Pull Secrets (Terminal)

> **Delete the manual secret from Layer 3 first.** ExternalSecret uses `creationPolicy: Owner` — it won't adopt a secret it didn't create.
> ```bash
> kubectl delete secret wallet-api-secret -n wallet
> ```

```bash
# Install External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io && helm repo update
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

kubectl rollout status deployment external-secrets -n external-secrets

# ClusterSecretStore — no auth block; ESO uses node instance profile via IMDS
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
      # No auth block — ESO uses node instance profile (LabRole) via IMDS.
      # IRSA requires iam:CreateOpenIDConnectProvider which is blocked in this lab.
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

## Layer 6 — CI/CD (Manual Push Workflow)

> **AWS Academy:** GitHub Actions CI/CD via OIDC is **not available** — `iam:CreateOpenIDConnectProvider` and `iam:CreateRole` both blocked (live-confirmed). The manual workflow below replicates the CI/CD steps locally.

### 6.1 Build + Tag + Push to ECR (Terminal)

```bash
# Tag with git SHA (same as GitHub Actions would do)
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "v$(date +%Y%m%d%H%M%S)")
IMAGE_TAG="${ECR_URI}:${GIT_SHA}"

aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker buildx build --platform linux/amd64 \
  -t "$IMAGE_TAG" --push app/
echo "Image pushed: $IMAGE_TAG"
```

### 6.2 Deploy New Image to EKS (Terminal)

```bash
kubectl set image deployment/wallet-api \
  app="$IMAGE_TAG" -n wallet

kubectl rollout status deployment/wallet-api -n wallet --timeout=300s
```

### 6.3 Verify (Terminal)

```bash
kubectl describe pods -n wallet | grep "Image:"
# Should show ECR URI with the new SHA tag

curl http://$ELB/health/live
# Expected: HTTP 200
```

**Layer 6 checkpoint:**
- [ ] Image in ECR tagged with git SHA (visible in ECR Console)
- [ ] Pod image tag matches the SHA
- [ ] `curl http://$ELB/health/live` returns 200

---

## Cleanup

**Do this in order — Kubernetes resources first to remove the Classic ELB.**

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

### IAM — nothing to delete

> **AWS Academy:** No custom roles or policies were created (used LabRole throughout). Nothing to clean up here.

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
Classic ELB  (internet-facing, public subnets)
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

CI/CD (manual — GitHub Actions OIDC blocked in lab):
  build locally → push to ECR → kubectl set image → rollout
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `AccessDenied: iam:CreateRole` | voclabs policy blocks role creation | Use `LabRole` — see section 1.9 |
| `AccessDenied: iam:CreateOpenIDConnectProvider` | voclabs policy blocks OIDC creation | Expected — ESO uses node instance profile via IMDS, no auth block in ClusterSecretStore |
| Node group stuck `CREATING` | Launch template or wrong AMI | Delete, re-create with AL2023 and no launch template |
| Classic ELB not provisioned | Subnet tags missing or wrong cluster name | Verify public subnets have `kubernetes.io/cluster/<cluster-name>` and `kubernetes.io/role/elb=1` tags |
| `ExternalSecret` not syncing | LabRole can't read Secrets Manager | Check LabRole has `secretsmanager:GetSecretValue` permission |
| EFS PVC stuck `Pending` (old error: `ProvisioningFailed`) | Dynamic provisioning requires EFS API calls — `CreateAccessPoint` blocked in Academy or CSI controller can't reach IMDS | Use static PV provisioning: apply `k8s/pv.yaml` with `<EFS_FILE_SYSTEM_ID>` patched, and `k8s/pvc.yaml` with `volumeName: wallet-uploads-pv` |
| EFS CSI `No OpenIDConnect provider found` | Addon installed with `--service-account-role-arn` (even LabRole) triggers WebIdentity auth which requires OIDC | Delete addon and reinstall without `--service-account-role-arn` |
| `ExternalSecret` stays `SecretSyncError` | ESO ClusterSecretStore has auth block → triggers WebIdentity (OIDC blocked) | Remove `auth:` block from ClusterSecretStore so ESO uses IMDS |
| `ImagePullBackOff: no match for platform` | Image built on Apple Silicon (arm64) but nodes are amd64 | Rebuild with `docker buildx build --platform linux/amd64` |
| Classic ELB returns 502 after switching to Go app | Service `targetPort` still set to 80 (nginx default) but Go app listens on 8080 | `kubectl patch svc wallet-api-svc -n wallet --type=json -p='[{"op":"replace","path":"/spec/ports/0/targetPort","value":8080}]'` |
| Pod connection timeout to RDS despite SG rule | Rule allows `lks-eks-node-sg` but pods use the auto-created EKS cluster SG | Add inbound rule for `eks-cluster-sg-lks-wallet-eks-*` SG on port 5432 |
| App restarts with `DB not ready` even after RDS fix | `DB_PASSWORD` env var missing — app can't auth | Create `wallet-api-secret` from Secrets Manager and patch deployment (see step 3.5) |
| ECR push fails `tag already exists and cannot be overwritten` | ECR immutable tags enabled | Disable immutability in ECR console or use a new tag version |

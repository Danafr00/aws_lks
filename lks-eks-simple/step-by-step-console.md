# Step-by-Step: EKS + ALB — AWS Console Guide

**Goal**: Deploy a simple nginx app on EKS, accessible via ALB, using the AWS Console for all infrastructure.  
**Note**: Phases 5d, 6, and 7 require a terminal for kubectl/helm — there is no console alternative for Kubernetes resources.  
**Region**: ap-southeast-1

---

## Timeline

| Phase | Task | Where | Est. Time |
|---|---|---|---|
| 1 | VPC + Networking | Console | 5 min |
| 2 | IAM Roles | Console | 3 min |
| 3 | EKS Cluster | Console | 12 min wait |
| 4 | Node Group | Console | 5 min wait |
| 5a–c | OIDC + LBC IAM | Console | 5 min |
| 5d | Install LBC | Terminal | 2 min |
| 6 | Deploy App | Terminal | 2 min |
| 7 | Test ALB | Terminal + Console | 5 min |
| 8 | Cleanup | Console + Terminal | 5 min |

---

## Phase 1 — VPC + Networking

### 1.1 Create VPC

1. Open [VPC Console](https://console.aws.amazon.com/vpc) → region: **ap-southeast-1**
2. Left sidebar → **Your VPCs** → **Create VPC**
3. Fill in:
   - Resources to create: **VPC only**
   - Name tag: `lks-simple-vpc`
   - IPv4 CIDR block: `10.0.0.0/16`
   - IPv6 CIDR block: No IPv6
   - Tenancy: Default
4. **Create VPC**
5. Select `lks-simple-vpc` → **Actions** → **Edit VPC settings**
   - ✅ Enable DNS hostnames
   - ✅ Enable DNS resolution
   - **Save**

---

### 1.2 Create Subnet 1 (AZ a)

1. Left sidebar → **Subnets** → **Create subnet**
2. VPC: `lks-simple-vpc`
3. Subnet settings:
   - Subnet name: `lks-public-1a`
   - Availability Zone: `ap-southeast-1a`
   - IPv4 subnet CIDR block: `10.0.1.0/24`
4. **Create subnet**
5. Select `lks-public-1a` → **Actions** → **Edit subnet settings**
   - ✅ Enable auto-assign public IPv4 address
   - **Save**

---

### 1.3 Create Subnet 2 (AZ b)

1. **Create subnet** again (same VPC)
2. Subnet settings:
   - Subnet name: `lks-public-1b`
   - Availability Zone: `ap-southeast-1b`
   - IPv4 subnet CIDR block: `10.0.2.0/24`
3. **Create subnet**
4. Select `lks-public-1b` → **Actions** → **Edit subnet settings**
   - ✅ Enable auto-assign public IPv4 address
   - **Save**

---

### 1.4 Tag Both Subnets for EKS + ALB

These tags are **required** — the AWS Load Balancer Controller uses them to discover which subnets to put the ALB in.

**For `lks-public-1a`:**
1. Select the subnet → **Tags** tab → **Manage tags** → **Add tag**

   | Key | Value |
   |---|---|
   | `kubernetes.io/cluster/lks-simple-eks` | `shared` |
   | `kubernetes.io/role/elb` | `1` |

2. **Save**

**Repeat the same two tags for `lks-public-1b`.**

---

### 1.5 Create Internet Gateway

1. Left sidebar → **Internet gateways** → **Create internet gateway**
   - Name tag: `lks-simple-igw`
2. **Create internet gateway**
3. After creation → **Actions** → **Attach to VPC**
   - Select `lks-simple-vpc`
   - **Attach internet gateway**

---

### 1.6 Create Route Table

1. Left sidebar → **Route tables** → **Create route table**
   - Name: `lks-simple-rtb`
   - VPC: `lks-simple-vpc`
2. **Create route table**
3. Select `lks-simple-rtb` → **Routes** tab → **Edit routes**
   - **Add route**:
     - Destination: `0.0.0.0/0`
     - Target: **Internet Gateway** → `lks-simple-igw`
   - **Save changes**
4. **Subnet associations** tab → **Edit subnet associations**
   - ✅ `lks-public-1a`
   - ✅ `lks-public-1b`
   - **Save associations**

---

## Phase 2 — IAM Roles

### 2.1 EKS Cluster Role

1. Open [IAM Console](https://console.aws.amazon.com/iam) → **Roles** → **Create role**
2. Trusted entity type: **AWS service**
3. Use case: scroll to **EKS** section → select **EKS – Cluster**
4. **Next**
5. Permissions: `AmazonEKSClusterPolicy` is pre-selected → **Next**
6. Role name: `LKS-EKSClusterRole`
7. **Create role**

---

### 2.2 EKS Node Role

1. **Create role** again
2. Trusted entity type: **AWS service**
3. Use case: **EC2** (not EKS — nodes are EC2 instances)
4. **Next**
5. Add permissions — search and check each:
   - ✅ `AmazonEKSWorkerNodePolicy`
   - ✅ `AmazonEC2ContainerRegistryReadOnly`
   - ✅ `AmazonEKS_CNI_Policy`
6. **Next** → Role name: `LKS-EKSNodeRole`
7. **Create role**

---

## Phase 3 — EKS Cluster

1. Open [EKS Console](https://console.aws.amazon.com/eks) → **Clusters** → **Create cluster**

**Step 1 — Configure cluster:**
- Name: `lks-simple-eks`
- Kubernetes version: `1.29`
- Cluster IAM role: `LKS-EKSClusterRole`
- Leave everything else default
- **Next**

**Step 2 — Specify networking:**
- VPC: `lks-simple-vpc`
- Subnets: select `lks-public-1a` **and** `lks-public-1b`
- Security groups: leave blank (EKS creates one automatically)
- Cluster endpoint access: **Public**
- **Next**

**Step 3 — Configure observability:** leave defaults → **Next**

**Step 4 — Select add-ons:** leave the 3 defaults (kube-proxy, CoreDNS, Amazon VPC CNI) → **Next**

**Step 5 — Configure add-on settings:** leave defaults → **Next**

**Step 6 — Review:** → **Create**

> ⏳ Wait ~12 minutes for Status to show **Active**

Once Active, connect kubectl to the cluster (terminal):
```bash
aws eks update-kubeconfig --name lks-simple-eks --region ap-southeast-1
kubectl get svc
# Expected: kubernetes   ClusterIP   10.100.0.1   ...
```

---

## Phase 4 — Node Group

1. EKS Console → click cluster `lks-simple-eks` → **Compute** tab → **Add node group**

**Step 1 — Configure node group:**
- Name: `lks-nodes`
- Node IAM role: `LKS-EKSNodeRole`
- Leave launch template and other defaults
- **Next**

**Step 2 — Set compute and scaling configuration:**
- AMI type: `Amazon Linux 2 (AL2_x86_64)`
- Capacity type: On-Demand
- Instance types: `t3.small`
- Disk size: 20 GiB
- Scaling configuration:
  - Minimum: `1`
  - Maximum: `3`
  - Desired: `2`
- **Next**

**Step 3 — Specify networking:**
- Subnets: select `lks-public-1a` **and** `lks-public-1b`
- Leave SSH access disabled (not needed for this lab)
- **Next**

**Step 4 — Review** → **Create**

> ⏳ Wait ~5 minutes for Status to show **Active**

Verify nodes in terminal:
```bash
kubectl get nodes
# Expected: 2 nodes in Ready state
```

---

## Phase 5 — OIDC + AWS Load Balancer Controller

### 5a. Get OIDC Issuer URL from EKS Console

1. EKS Console → `lks-simple-eks` → **Overview** tab
2. Scroll to **Details** section
3. Copy the **OpenID Connect provider URL**
   - Example: `https://oidc.eks.ap-southeast-1.amazonaws.com/id/ABC123XYZ`
   - Note down the **ID** at the end (the part after `/id/`) — you'll need it in 5c

---

### 5b. Register OIDC Identity Provider in IAM

1. IAM Console → left sidebar → **Identity providers** → **Add provider**
2. Provider type: **OpenID Connect**
3. Provider URL: paste the full URL from 5a
4. Click **Get thumbprint** (auto-fills)
5. Audience: `sts.amazonaws.com`
6. **Add provider**

---

### 5c. Create IAM Policy for LBC

First, get the policy JSON (run in terminal):
```bash
curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json
```

Then in console:
1. IAM Console → **Policies** → **Create policy**
2. Click **JSON** tab
3. Replace all content with the contents of `iam_policy.json` (open the file and copy-paste)
4. **Next**
5. Policy name: `AWSLoadBalancerControllerIAMPolicy`
6. **Create policy**

---

### 5c. Create IAM Role for LBC

1. IAM Console → **Roles** → **Create role**
2. Trusted entity type: **Web identity**
3. Identity provider: select the OIDC provider you just added
   - Audience: `sts.amazonaws.com`
4. **Next**
5. Search and select: `AWSLoadBalancerControllerIAMPolicy`
6. **Next** → Role name: `LKS-LBCRole` → **Create role**

**Now restrict the trust policy to the specific service account:**

1. IAM Console → **Roles** → click `LKS-LBCRole`
2. **Trust relationships** tab → **Edit trust policy**
3. Find the `"Condition"` block — it currently has only `"StringEquals"` with the audience.  
   Replace it entirely with this (swap `OIDC_ID` with your actual ID from Step 5a):

```json
"Condition": {
  "StringEquals": {
    "oidc.eks.ap-southeast-1.amazonaws.com/id/OIDC_ID:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
    "oidc.eks.ap-southeast-1.amazonaws.com/id/OIDC_ID:aud": "sts.amazonaws.com"
  }
}
```

4. **Update policy**

---

### 5d. Install LBC — Terminal Required

There is no console for this step. Run in terminal:

```bash
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=lks-simple-eks
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Grab VPC ID and LBC Role ARN dynamically
export VPC_ID=$(aws eks describe-cluster \
  --name $CLUSTER_NAME --region $AWS_REGION \
  --query "cluster.resourcesVpcConfig.vpcId" --output text)
export LBC_ROLE_ARN=$(aws iam get-role \
  --role-name LKS-LBCRole \
  --query 'Role.Arn' --output text)

# Create and annotate the K8s service account
kubectl create serviceaccount aws-load-balancer-controller -n kube-system
kubectl annotate serviceaccount aws-load-balancer-controller \
  -n kube-system \
  eks.amazonaws.com/role-arn=$LBC_ROLE_ARN

# Install via Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$AWS_REGION \
  --set vpcId=$VPC_ID

# Verify — should show READY 2/2
kubectl rollout status deployment aws-load-balancer-controller -n kube-system
kubectl get deployment -n kube-system aws-load-balancer-controller
```

---

## Phase 6 — Deploy Application (Terminal)

```bash
# From the lks-eks-simple/ directory
kubectl apply -f k8s/

# Watch pods come up
kubectl get pods --watch
# Wait until both pods show Running 2/2, then Ctrl+C
```

---

## Phase 7 — Test ALB

### Terminal: get the URL

```bash
# Watch until ADDRESS column is populated (2–4 min)
kubectl get ingress hello-app-ingress --watch

ALB_URL=$(kubectl get ingress hello-app-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "http://$ALB_URL"

curl -s http://$ALB_URL | grep title
# Expected: <title>Hello EKS</title>
```

Open `http://$ALB_URL` in your browser — you should see the **Hello from EKS!** card.

### Console: verify ALB and targets

1. [EC2 Console](https://console.aws.amazon.com/ec2) → left sidebar → **Load balancers**
   - You should see an ALB named `k8s-default-helloapp-...`
   - State: **Active**

2. Left sidebar → **Target groups**
   - Find the target group for the ALB
   - **Targets** tab → 2 targets registered, health check: **healthy**

---

## Phase 8 — Cleanup

**Do this in order — deleting K8s resources first removes the ALB from AWS.**

### 8.1 Terminal — delete K8s resources + Helm

```bash
kubectl delete -f k8s/
# Wait 60s for ALB to be removed from AWS
sleep 60
helm uninstall aws-load-balancer-controller -n kube-system
```

### 8.2 EKS Console — delete node group then cluster

1. EKS Console → `lks-simple-eks` → **Compute** tab
2. Select `lks-nodes` → **Delete** → type `lks-nodes` to confirm
3. ⏳ Wait for deletion (~5 min)
4. **Overview** tab → **Delete cluster** → type `lks-simple-eks` to confirm
5. ⏳ Wait for deletion (~5 min)

### 8.3 IAM Console — delete roles and policy

1. **Roles** → delete `LKS-LBCRole`
2. **Roles** → delete `LKS-EKSNodeRole`
3. **Roles** → delete `LKS-EKSClusterRole`
4. **Policies** → search `AWSLoadBalancerControllerIAMPolicy` → **Delete**
5. **Identity providers** → select the OIDC provider → **Delete**

### 8.4 VPC Console — delete networking (in this order)

1. **Internet gateways** → select `lks-simple-igw` → **Actions** → **Detach from VPC** → then **Delete**
2. **Subnets** → delete `lks-public-1a` → delete `lks-public-1b`
3. **Route tables** → delete `lks-simple-rtb`
4. **Your VPCs** → select `lks-simple-vpc` → **Actions** → **Delete VPC** → confirm

---

## Architecture Built

```
Internet
    │  HTTP :80
    ▼
Application Load Balancer   ← EC2 Console → Load Balancers
  (internet-facing)
    │  target-type: ip
    ▼
Service: hello-app-svc (ClusterIP :80)
    │
    ├── Pod 1: nginx + hello-html
    └── Pod 2: nginx + hello-html

        EKS Cluster (1.29)         ← EKS Console → Clusters
        └── Node Group: 2x t3.small
            └── VPC 10.0.0.0/16    ← VPC Console → Your VPCs
                ├── 10.0.1.0/24  ap-southeast-1a
                └── 10.0.2.0/24  ap-southeast-1b
```

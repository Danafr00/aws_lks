# Kunci Jawaban – CI/CD and Container Orchestration

---

## Task 1 – VPC and Network Infrastructure

### Step 1: Create VPC

1. Go to **AWS Console → VPC → Your VPCs → Create VPC**
2. Select **VPC and more**
3. Fill in:
   - Name tag auto-generation: `lks-wallet`
   - IPv4 CIDR: `10.10.0.0/16`
   - Number of Availability Zones: **2**
   - Number of public subnets: **2**
   - Number of private subnets: **2**
   - Public subnet CIDRs: `10.10.1.0/24` (1a), `10.10.2.0/24` (1b)
   - Private subnet CIDRs: `10.10.10.0/24` (1a), `10.10.11.0/24` (1b)
   - NAT gateways: **1** (change from default "1 per AZ")
   - VPC endpoints: None for now
4. Click **Create VPC**

### Step 2: Rename resources

After creation, rename:
- VPC → `lks-wallet-vpc`
- Public subnets → `lks-public-1a`, `lks-public-1b`
- Private subnets → `lks-private-1a`, `lks-private-1b`
- Internet Gateway → `lks-wallet-igw`
- NAT Gateway → `lks-wallet-nat`
- Public Route Table → `lks-public-rt`
- Private Route Table → `lks-private-rt`

### Step 3: Enable DNS settings

1. Select `lks-wallet-vpc` → **Actions → Edit VPC settings**
2. Enable: **DNS hostnames** ✓ and **DNS resolution** ✓

### Step 4: Tag subnets for EKS

For each **public subnet**:
```
kubernetes.io/role/elb = 1
kubernetes.io/cluster/lks-wallet-eks = owned
Project = nusantara-wallet
Environment = production
ManagedBy = LKS-Team
```

For each **private subnet**:
```
kubernetes.io/role/internal-elb = 1
kubernetes.io/cluster/lks-wallet-eks = owned
Project = nusantara-wallet
Environment = production
ManagedBy = LKS-Team
```

---

## Task 2 – Security Groups

### Create lks-eks-cluster-sg

1. **EC2 → Security Groups → Create security group**
2. Name: `lks-eks-cluster-sg`, VPC: `lks-wallet-vpc`
3. Inbound: HTTPS (443), Source: `10.10.0.0/16`
4. Outbound: All traffic, Destination: `10.10.0.0/16`
5. Add tags

### Create lks-eks-node-sg

1. Name: `lks-eks-node-sg`, VPC: `lks-wallet-vpc`
2. Inbound:
   - All traffic, Source: `lks-eks-node-sg` (self-referencing)
   - Custom TCP, Port `1025-65535`, Source: `lks-eks-cluster-sg`
3. Outbound: All traffic

### Create lks-rds-sg

1. Name: `lks-rds-sg`, VPC: `lks-wallet-vpc`
2. Inbound: PostgreSQL (5432), Source: `lks-eks-node-sg`
3. Outbound: Delete the default rule (none)

### Create lks-efs-sg

1. Name: `lks-efs-sg`, VPC: `lks-wallet-vpc`
2. Inbound: Custom TCP, Port `2049` (NFS), Source: `lks-eks-node-sg`
3. Outbound: Delete the default rule (none)

> The NFS protocol uses port 2049. EKS nodes must be allowed to reach this port to mount the EFS file system.

---

## Task 3 – RDS PostgreSQL

### Step 1: Create DB Subnet Group

1. **RDS → Subnet groups → Create DB subnet group**
2. Name: `lks-wallet-db-subnet-group`
3. VPC: `lks-wallet-vpc`
4. Add subnets: `lks-private-1a`, `lks-private-1b`

### Step 2: Create RDS Instance

1. **RDS → Create database**
2. Engine: **PostgreSQL**, version: **16.x**
3. Templates: **Free tier**
4. DB identifier: `lks-wallet-db`
5. Master username: `walletadmin`
6. Credentials: **Manage master credentials in AWS Secrets Manager**
   - Secret name: `lks/wallet/db`
7. Instance class: `db.t3.micro` (free tier)
8. Storage: `20 GiB gp2` — **disable** storage autoscaling
9. Multi-AZ: **No** (leave unchecked — free tier does not include Multi-AZ)
10. VPC: `lks-wallet-vpc`
11. Subnet group: `lks-wallet-db-subnet-group`
12. Public access: **No**
13. Security group: `lks-rds-sg`
14. Initial database name: `wallet_db`
15. Add tags

> Note the RDS endpoint after creation — you will need it for the ConfigMap.

---

## Task 4 – AWS Secrets Manager

### Create JWT secret

1. **Secrets Manager → Store a new secret**
2. Type: **Other type of secret**
3. Key: `JWT_SECRET`, Value: run `openssl rand -hex 32` locally and paste the result
4. Secret name: `lks/wallet/app`
5. Add tags

> The DB password secret `lks/wallet/db` was already created automatically by RDS in Step 3.2.

---

## Task 5 – ECR Repository

1. **ECR → Private registry → Create repository**
2. Repository name: `lks-wallet-api`
3. Tag immutability: **Enabled**
4. Scan on push: **Enabled**
5. Add tags

### Add Lifecycle Policy

1. Select the repository → **Lifecycle Policy → Create rule**
2. Rule 1 – Keep last 5 tagged images:
   - Priority: `1`, Image status: Tagged, Action: Keep last `5`
3. Rule 2 – Expire untagged images:
   - Priority: `2`, Image status: Untagged, Since image pushed: `1` day

---

## Task 6 – Amazon EFS

### Step 1: Create the EFS File System

1. **EFS → File systems → Create file system**
2. Click **Customize** (not Quick Create)
3. Name: `lks-wallet-storage`
4. Storage class: **Standard**
5. Automatic backups: **Disabled**
6. Lifecycle management: Transition to IA after **30 days**
7. Performance mode: **General Purpose**
8. Throughput mode: **Bursting**
9. Encryption: **Enabled** (default KMS key)
10. Add tags: Project, Environment, ManagedBy

### Step 2: Configure Network (Mount Targets)

On the next page (Network):
1. VPC: `lks-wallet-vpc`
2. Add mount targets for **both private subnets**:
   - `lks-private-1a` → Security group: `lks-efs-sg`
   - `lks-private-1b` → Security group: `lks-efs-sg`
3. Click **Next** and **Create**

### Step 3: Note the File System ID

After creation, go to the EFS console and note the **File system ID** (format: `fs-xxxxxxxxx`). You will need it in the StorageClass manifest.

---

## Task 7 – EKS Cluster

### Step 1: Create IAM Roles

**LKS-EKSClusterRole** (trust: `eks.amazonaws.com`):
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "eks.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```
Attach: `AmazonEKSClusterPolicy`

**LKS-EKSNodeRole** (trust: `ec2.amazonaws.com`):
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```
Attach:
- `AmazonEKSWorkerNodePolicy`
- `AmazonEC2ContainerRegistryReadOnly`
- `AmazonEKS_CNI_Policy`
- `CloudWatchAgentServerPolicy`

### Step 2: Create EKS Cluster

1. **EKS → Create cluster**
2. Name: `lks-wallet-eks`, version: `1.31`
3. Cluster service role: `LKS-EKSClusterRole`
4. VPC: `lks-wallet-vpc`
5. Subnets: **Private subnets only**
6. Security group: `lks-eks-cluster-sg`
7. Cluster endpoint access: **Public and private**
8. Add tags → **Create** (wait ~10–15 min)

### Step 3: Create Node Group

1. Go to cluster → **Compute → Add node group**
2. Name: `lks-wallet-ng`
3. Node IAM role: `LKS-EKSNodeRole`
4. AMI type: `Amazon Linux 2 (AL2_x86_64)`
5. Instance type: `t3.micro` (free tier)
6. Disk size: `20 GiB`
7. Scaling: Desired `1`, Min `1`, Max `2`
8. Subnets: private subnets → **Create**

### Step 4: Update kubeconfig

```bash
aws eks update-kubeconfig \
  --region ap-southeast-1 \
  --name lks-wallet-eks

kubectl get nodes
```

---

## Task 8 – EKS Add-ons

### 8.1 – AWS Load Balancer Controller

**Step 1: Associate OIDC provider**
```bash
eksctl utils associate-iam-oidc-provider \
  --cluster lks-wallet-eks \
  --region ap-southeast-1 \
  --approve
```

**Step 2: Download and create IAM policy**
```bash
curl -o alb-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://alb-iam-policy.json
```

**Step 3: Create IRSA role**
```bash
eksctl create iamserviceaccount \
  --cluster lks-wallet-eks \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --role-name LKS-AWSLoadBalancerControllerRole \
  --attach-policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve \
  --region ap-southeast-1
```

**Step 4: Install via Helm**
```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=lks-wallet-eks \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=ap-southeast-1 \
  --set vpcId=<VPC_ID>
```

Verify:
```bash
kubectl get deployment -n kube-system aws-load-balancer-controller
```

---

### 8.2 – EFS CSI Driver

The EFS CSI Driver allows Kubernetes to dynamically provision EFS-backed PersistentVolumes using EFS Access Points.

**Step 1: Create IAM policy for EFS CSI**
```bash
cat > efs-csi-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:DescribeAccessPoints",
        "elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeMountTargets",
        "ec2:DescribeAvailabilityZones"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:CreateAccessPoint",
        "elasticfilesystem:TagResource"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:RequestTag/efs.csi.aws.com/cluster": "true"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": "elasticfilesystem:DeleteAccessPoint",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/efs.csi.aws.com/cluster": "true"
        }
      }
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name LKS-EFSCSIDriverPolicy \
  --policy-document file://efs-csi-policy.json
```

**Step 2: Create IRSA role**
```bash
eksctl create iamserviceaccount \
  --cluster lks-wallet-eks \
  --namespace kube-system \
  --name efs-csi-controller-sa \
  --role-name LKS-EFSCSIDriverRole \
  --attach-policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/LKS-EFSCSIDriverPolicy \
  --approve \
  --region ap-southeast-1
```

**Step 3: Install the EFS CSI Driver as an EKS managed add-on**

1. Go to EKS cluster → **Add-ons → Add new add-on**
2. Select: **Amazon EFS CSI Driver**
3. IAM role for service account: `LKS-EFSCSIDriverRole`
4. Click **Create** and wait for status: Active

Verify:
```bash
kubectl get pods -n kube-system -l app=efs-csi-controller
```

**Step 4: Create EFS StorageClass**

Create `k8s/storage-class.yaml`:
```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: <EFS_FILE_SYSTEM_ID>   # e.g. fs-0abc1234def56789
  directoryPerms: "755"
  gidRangeStart: "1000"
  gidRangeEnd: "2000"
  basePath: "/uploads"
reclaimPolicy: Retain
volumeBindingMode: Immediate
```

Apply:
```bash
kubectl apply -f k8s/storage-class.yaml
```

> `provisioningMode: efs-ap` means the CSI driver will automatically create a separate EFS Access Point for each PVC. This isolates data per PVC while sharing the same file system.

---

### 8.3 – Cluster Autoscaler

**Step 1: Create IAM policy**
```bash
cat > cluster-autoscaler-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup"
    ],
    "Resource": ["*"]
  }]
}
EOF

aws iam create-policy \
  --policy-name LKS-ClusterAutoscalerPolicy \
  --policy-document file://cluster-autoscaler-policy.json
```

**Step 2: Create IRSA role**
```bash
eksctl create iamserviceaccount \
  --cluster lks-wallet-eks \
  --namespace kube-system \
  --name cluster-autoscaler \
  --role-name LKS-ClusterAutoscalerRole \
  --attach-policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/LKS-ClusterAutoscalerPolicy \
  --approve \
  --region ap-southeast-1
```

**Step 3: Install via Helm**
```bash
helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm repo update

helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  -n kube-system \
  --set autoDiscovery.clusterName=lks-wallet-eks \
  --set awsRegion=ap-southeast-1 \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler
```

---

### 8.4 – External Secrets Operator

**Step 1: Create IAM policy**
```bash
cat > external-secrets-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret"
    ],
    "Resource": "arn:aws:secretsmanager:ap-southeast-1:<ACCOUNT_ID>:secret:lks/wallet/*"
  }]
}
EOF

aws iam create-policy \
  --policy-name LKS-ExternalSecretsPolicy \
  --policy-document file://external-secrets-policy.json
```

**Step 2: Create IRSA role**
```bash
eksctl create iamserviceaccount \
  --cluster lks-wallet-eks \
  --namespace external-secrets \
  --name external-secrets \
  --role-name LKS-ExternalSecretsRole \
  --attach-policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/LKS-ExternalSecretsPolicy \
  --approve \
  --region ap-southeast-1
```

**Step 3: Install via Helm**
```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=arn:aws:iam::<ACCOUNT_ID>:role/LKS-ExternalSecretsRole
```

**Step 4: Create ClusterSecretStore** – `k8s/cluster-secret-store.yaml`
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ap-southeast-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
```

```bash
kubectl apply -f k8s/cluster-secret-store.yaml
```

---

### 8.5 – Metrics Server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Verify
kubectl get deployment metrics-server -n kube-system
kubectl top nodes
```

---

## Task 9 – Namespace, ServiceAccount, and IRSA

### Create namespace

```bash
kubectl create namespace wallet
kubectl label namespace wallet \
  app.kubernetes.io/name=wallet \
  Project=nusantara-wallet
```

### Create IAM policy and IRSA role for application pods

```bash
cat > wallet-app-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "arn:aws:secretsmanager:ap-southeast-1:<ACCOUNT_ID>:secret:lks/wallet/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name LKS-WalletAppPolicy \
  --policy-document file://wallet-app-policy.json

eksctl create iamserviceaccount \
  --cluster lks-wallet-eks \
  --namespace wallet \
  --name wallet-api-sa \
  --role-name LKS-WalletAppRole \
  --attach-policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/LKS-WalletAppPolicy \
  --approve \
  --region ap-southeast-1
```

Verify:
```bash
kubectl describe serviceaccount wallet-api-sa -n wallet
# Should show: eks.amazonaws.com/role-arn annotation
```

---

## Task 10 – GitHub Actions CI/CD Pipeline

### Step 10.1: Create GitHub OIDC Provider in AWS

1. **IAM → Identity providers → Add provider**
2. Type: **OpenID Connect**
3. URL: `https://token.actions.githubusercontent.com` → click **Get thumbprint**
4. Audience: `sts.amazonaws.com`
5. **Add provider**

### Step 10.2: Create LKS-GitHubActionsRole

1. **IAM → Roles → Create role → Web identity**
2. Provider: `token.actions.githubusercontent.com`
3. Audience: `sts.amazonaws.com`

Trust policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:<YOUR_GITHUB_USERNAME>/nusantara-wallet-api:ref:refs/heads/main"
      }
    }
  }]
}
```

Inline permission policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "ecr:GetAuthorizationToken",
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "arn:aws:ecr:ap-southeast-1:<ACCOUNT_ID>:repository/lks-wallet-api"
    },
    {
      "Effect": "Allow",
      "Action": "eks:DescribeCluster",
      "Resource": "arn:aws:eks:ap-southeast-1:<ACCOUNT_ID>:cluster/lks-wallet-eks"
    }
  ]
}
```

Role name: `LKS-GitHubActionsRole`

### Step 10.3: Add GitHub Secrets

Repository → Settings → Secrets and variables → Actions:

| Name | Value |
|---|---|
| `AWS_ACCOUNT_ID` | Your 12-digit account ID |
| `AWS_REGION` | `ap-southeast-1` |
| `EKS_CLUSTER_NAME` | `lks-wallet-eks` |

### Step 10.4: Configure GitHub Environment

1. Repository → **Settings → Environments → New environment**
2. Name: `production`
3. Required reviewers: Add yourself

### Step 10.5: Create `.github/workflows/deploy.yml`

```yaml
name: CI/CD Pipeline

on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]

permissions:
  id-token: write
  contents: read

env:
  AWS_REGION: ${{ secrets.AWS_REGION }}
  ECR_REPOSITORY: lks-wallet-api
  EKS_CLUSTER_NAME: ${{ secrets.EKS_CLUSTER_NAME }}

jobs:
  test:
    name: Test
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set up Go
        uses: actions/setup-go@v5
        with:
          go-version-file: 'go.mod'
          cache: true

      - name: Run tests
        run: go test -race -v ./...

      - name: Run vet
        run: go vet ./...

  build-and-push:
    name: Build and Push to ECR
    runs-on: ubuntu-latest
    needs: test
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    outputs:
      image-tag: ${{ steps.vars.outputs.sha_short }}
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Set image tag
        id: vars
        run: echo "sha_short=$(echo ${{ github.sha }} | cut -c1-7)" >> $GITHUB_OUTPUT

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/LKS-GitHubActionsRole
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build, tag, and push image
        env:
          ECR_REGISTRY: ${{ steps.login-ecr.outputs.registry }}
          IMAGE_TAG: ${{ steps.vars.outputs.sha_short }}
        run: |
          docker build -t $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG .
          docker tag $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG $ECR_REGISTRY/$ECR_REPOSITORY:latest
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG
          docker push $ECR_REGISTRY/$ECR_REPOSITORY:latest

  deploy:
    name: Deploy to EKS
    runs-on: ubuntu-latest
    needs: build-and-push
    environment: production
    steps:
      - name: Checkout code
        uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/LKS-GitHubActionsRole
          aws-region: ${{ env.AWS_REGION }}

      - name: Update kubeconfig
        run: |
          aws eks update-kubeconfig \
            --region ${{ env.AWS_REGION }} \
            --name ${{ env.EKS_CLUSTER_NAME }}

      - name: Run database migration
        env:
          IMAGE_TAG: ${{ needs.build-and-push.outputs.image-tag }}
          ECR_REGISTRY: ${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.${{ env.AWS_REGION }}.amazonaws.com
        run: |
          sed "s|IMAGE_TAG|$IMAGE_TAG|g" k8s/migrate-job.yaml | \
          sed "s|ECR_REGISTRY|$ECR_REGISTRY|g" | \
          kubectl apply -f -

          kubectl wait --for=condition=complete job/wallet-migrate \
            -n wallet --timeout=120s

          kubectl delete job wallet-migrate -n wallet

      - name: Update deployment image
        env:
          IMAGE_TAG: ${{ needs.build-and-push.outputs.image-tag }}
          ECR_REGISTRY: ${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.${{ env.AWS_REGION }}.amazonaws.com
        run: |
          kubectl set image deployment/wallet-api \
            wallet-api=$ECR_REGISTRY/$ECR_REPOSITORY:$IMAGE_TAG \
            -n wallet

      - name: Wait for rollout
        run: |
          kubectl rollout status deployment/wallet-api \
            -n wallet --timeout=300s

      - name: Rollback on failure
        if: failure()
        run: |
          kubectl rollout undo deployment/wallet-api -n wallet
          kubectl rollout status deployment/wallet-api -n wallet --timeout=120s
```

---

## Task 11 – Kubernetes Manifests

### 11.1 – ConfigMap (`k8s/configmap.yaml`)

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: wallet-api-config
  namespace: wallet
  labels:
    app: wallet-api
data:
  APP_ENV: "production"
  APP_PORT: "8080"
  DB_HOST: "<RDS_ENDPOINT>"
  DB_PORT: "5432"
  DB_NAME: "wallet_db"
  DB_USER: "walletadmin"
  UPLOAD_PATH: "/app/uploads"
  UPLOAD_MAX_SIZE: "10485760"
```

### 11.2 – ExternalSecret (`k8s/external-secret.yaml`)

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: wallet-api-external-secret
  namespace: wallet
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: wallet-api-secret
    creationPolicy: Owner
  data:
    - secretKey: DB_PASSWORD
      remoteRef:
        key: lks/wallet/db
        property: DB_PASSWORD
    - secretKey: JWT_SECRET
      remoteRef:
        key: lks/wallet/app
        property: JWT_SECRET
```

### 11.3 – StorageClass (`k8s/storage-class.yaml`)

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: <EFS_FILE_SYSTEM_ID>
  directoryPerms: "755"
  gidRangeStart: "1000"
  gidRangeEnd: "2000"
  basePath: "/uploads"
reclaimPolicy: Retain
volumeBindingMode: Immediate
```

> Replace `<EFS_FILE_SYSTEM_ID>` with the actual ID (e.g., `fs-0abc1234`). The `efs-ap` mode creates one EFS Access Point per PVC, isolating the directory while sharing the underlying file system.

### 11.4 – PersistentVolumeClaim (`k8s/pvc.yaml`)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wallet-uploads-pvc
  namespace: wallet
  labels:
    app: wallet-api
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 1Gi
```

> `ReadWriteMany` is the key difference from EBS. EBS only supports `ReadWriteOnce` (one node at a time). EFS supports `ReadWriteMany`, meaning **all pods across all nodes** can read and write concurrently — essential for a multi-pod deployment serving file uploads.

### 11.5 – Deployment (`k8s/deployment.yaml`)

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wallet-api
  namespace: wallet
  labels:
    app: wallet-api
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: wallet-api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  template:
    metadata:
      labels:
        app: wallet-api
        version: v1
    spec:
      serviceAccountName: wallet-api-sa
      containers:
        - name: wallet-api
          image: <ACCOUNT_ID>.dkr.ecr.ap-southeast-1.amazonaws.com/lks-wallet-api:latest
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: "50m"
              memory: "64Mi"
            limits:
              cpu: "200m"
              memory: "256Mi"
          envFrom:
            - configMapRef:
                name: wallet-api-config
            - secretRef:
                name: wallet-api-secret
          volumeMounts:
            - name: uploads
              mountPath: /app/uploads
          livenessProbe:
            httpGet:
              path: /health/live
              port: 8080
            initialDelaySeconds: 15
            periodSeconds: 20
            failureThreshold: 3
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3
      volumes:
        - name: uploads
          persistentVolumeClaim:
            claimName: wallet-uploads-pvc
      terminationGracePeriodSeconds: 30
```

> The `volumes` block at pod level declares the PVC as a volume source named `uploads`. The `volumeMounts` block inside the container maps it to `/app/uploads`. When the EFS CSI driver sees this PVC bind, it creates an EFS Access Point and mounts the NFS share into each pod automatically.

### 11.6 – Migration Job (`k8s/migrate-job.yaml`)

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: wallet-migrate
  namespace: wallet
spec:
  ttlSecondsAfterFinished: 60
  template:
    spec:
      serviceAccountName: wallet-api-sa
      restartPolicy: Never
      containers:
        - name: migrate
          image: ECR_REGISTRY/lks-wallet-api:IMAGE_TAG
          command: ["./migrate", "up"]
          envFrom:
            - configMapRef:
                name: wallet-api-config
            - secretRef:
                name: wallet-api-secret
```

### 11.7 – Service (`k8s/service.yaml`)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: wallet-api-svc
  namespace: wallet
  labels:
    app: wallet-api
spec:
  type: ClusterIP
  selector:
    app: wallet-api
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 8080
```

### 11.8 – Ingress (`k8s/ingress.yaml`)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wallet-api-ingress
  namespace: wallet
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/subnets: <PUBLIC_SUBNET_1A_ID>,<PUBLIC_SUBNET_1B_ID>
    alb.ingress.kubernetes.io/certificate-arn: <ACM_CERTIFICATE_ARN>
    alb.ingress.kubernetes.io/ssl-policy: ELBSecurityPolicy-TLS13-1-2-2021-06
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    alb.ingress.kubernetes.io/actions.ssl-redirect: |
      {"type":"redirect","redirectConfig":{"protocol":"HTTPS","port":"443","statusCode":"HTTP_301"}}
spec:
  ingressClassName: alb
  rules:
    - host: api.nusantarawallet.id
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: wallet-api-svc
                port:
                  number: 80
```

**Get ACM Certificate:**
1. **ACM → Request certificate → Public certificate**
2. Domain: `api.nusantarawallet.id`, validation: DNS
3. Add the CNAME record to your DNS, wait for Issued status
4. Copy the ARN into the annotation above

### Apply all manifests in order

```bash
# 1. StorageClass (cluster-scoped, applied before namespace resources)
kubectl apply -f k8s/storage-class.yaml

# 2. ClusterSecretStore
kubectl apply -f k8s/cluster-secret-store.yaml

# 3. ConfigMap and ExternalSecret
kubectl apply -f k8s/configmap.yaml
kubectl apply -f k8s/external-secret.yaml

# 4. Wait for secret sync from Secrets Manager
kubectl wait externalsecret/wallet-api-external-secret \
  -n wallet --for=condition=Ready --timeout=60s

# 5. PVC — the EFS CSI driver will bind this immediately
kubectl apply -f k8s/pvc.yaml

# 6. Verify the PVC is Bound before deploying
kubectl get pvc -n wallet
# Expected: wallet-uploads-pvc  Bound  ...  efs-sc

# 7. Deploy the application
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
kubectl apply -f k8s/hpa.yaml
kubectl apply -f k8s/pdb.yaml
```

---

## Task 12 – Autoscaling

### 12.1 – HPA (`k8s/hpa.yaml`)

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: wallet-api-hpa
  namespace: wallet
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: wallet-api
  minReplicas: 1
  maxReplicas: 3
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 60
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 70
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300
      policies:
        - type: Pods
          value: 1
          periodSeconds: 60
    scaleUp:
      policies:
        - type: Pods
          value: 1
          periodSeconds: 30
```

### 12.2 – PDB (`k8s/pdb.yaml`)

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: wallet-api-pdb
  namespace: wallet
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: wallet-api
```

---

## Task 13 – CloudWatch Container Insights

### Enable Container Insights

```bash
aws eks create-addon \
  --cluster-name lks-wallet-eks \
  --addon-name amazon-cloudwatch-observability \
  --region ap-southeast-1

# Wait for ACTIVE status
aws eks describe-addon \
  --cluster-name lks-wallet-eks \
  --addon-name amazon-cloudwatch-observability \
  --region ap-southeast-1 \
  --query "addon.status"
```

### Create SNS Topic and subscribe email

```bash
aws sns create-topic \
  --name lks-wallet-alerts \
  --region ap-southeast-1

aws sns subscribe \
  --topic-arn arn:aws:sns:ap-southeast-1:<ACCOUNT_ID>:lks-wallet-alerts \
  --protocol email \
  --notification-endpoint your-email@domain.com \
  --region ap-southeast-1
```

Confirm the subscription from the email you receive.

### Create CloudWatch Alarm

1. **CloudWatch → Alarms → Create alarm**
2. Metric: `ContainerInsights` → `pod_cpu_utilization`
3. Filter: `ClusterName = lks-wallet-eks`, `Namespace = wallet`
4. Statistic: Average, Period: 1 minute
5. Threshold: Greater than `80`
6. Datapoints to alarm: `3 out of 3`
7. Action: `lks-wallet-alerts` SNS topic
8. Alarm name: `lks-wallet-high-cpu`

---

## Task 14 – End-to-End Validation

### Step 1: Push a code change

```bash
git add handler/health.go
git commit -m "chore: bump health endpoint version"
git push origin main
```

### Step 2: Observe GitHub Actions

1. `test` → passes
2. `build-and-push` → new image pushed to ECR with SHA tag
3. `deploy` → approve the production environment gate
4. Migration job runs → deployment image updates → rollout completes

### Step 3: Verify deployment

```bash
kubectl get pods -n wallet
kubectl describe deployment wallet-api -n wallet | grep Image

curl https://api.nusantarawallet.id/health/live
```

### Step 4: Verify EFS mount

```bash
POD=$(kubectl get pod -n wallet -l app=wallet-api -o jsonpath='{.items[0].metadata.name}')

# Write a file from the pod
kubectl exec -n wallet $POD -- sh -c "echo 'efs-test' > /app/uploads/test.txt"

# Read it back — proves the mount is working
kubectl exec -n wallet $POD -- cat /app/uploads/test.txt
```

If you scale to 2 pods, you can write from one and read from the other — that demonstrates the `ReadWriteMany` capability:

```bash
# Scale to 2 temporarily
kubectl scale deployment wallet-api -n wallet --replicas=2
kubectl get pods -n wallet

POD1=$(kubectl get pod -n wallet -l app=wallet-api -o jsonpath='{.items[0].metadata.name}')
POD2=$(kubectl get pod -n wallet -l app=wallet-api -o jsonpath='{.items[1].metadata.name}')

kubectl exec -n wallet $POD1 -- sh -c "echo 'written-by-pod1' > /app/uploads/shared.txt"
kubectl exec -n wallet $POD2 -- cat /app/uploads/shared.txt
# Expected output: written-by-pod1
```

### Step 5: Verify HPA

```bash
# Generate load
kubectl run load-gen \
  --image=busybox --restart=Never -n wallet \
  -- sh -c "while true; do wget -q -O- http://wallet-api-svc/health/live; done"

# Watch HPA respond
kubectl get hpa wallet-api-hpa -n wallet -w

# Clean up
kubectl delete pod load-gen -n wallet
```

### Step 6: Verify CloudWatch Container Insights

1. **CloudWatch → Container Insights → Performance monitoring**
2. Select `EKS Clusters` → `lks-wallet-eks`
3. Drill into the `wallet` namespace to view CPU/memory graphs

---

## Summary Checklist

| Task | Resource | Free Tier |
|---|---|---|
| VPC | `lks-wallet-vpc` (10.10.0.0/16) | ✓ |
| Subnets | 2 public + 2 private, 2 AZs | ✓ |
| NAT Gateway | 1 in public subnet | ⚠️ ~$1/day |
| Security Groups | cluster, node, rds, **efs** | ✓ |
| RDS | `lks-wallet-db` PostgreSQL 16, db.t3.micro, single-AZ | ✓ Free Tier |
| Secrets Manager | db, app secrets | ⚠️ $0.40/secret/mo after trial |
| ECR | `lks-wallet-api` with lifecycle policy | ✓ 500MB free |
| **EFS** | **`lks-wallet-storage` Regional, bursting, lifecycle to IA** | **✓ 5GB free** |
| **EFS Mount Targets** | **Private subnets, lks-efs-sg** | **✓** |
| EKS Cluster | `lks-wallet-eks` v1.31 | ⚠️ $0.10/hr |
| Node Group | `lks-wallet-ng` t3.micro, desired 1, max 2 | ✓ Free Tier |
| AWS LB Controller | IRSA + Helm | ⚠️ ALB ~$16/mo min |
| **EFS CSI Driver** | **EKS managed add-on + IRSA + StorageClass** | **✓** |
| Cluster Autoscaler | IRSA + Helm | ✓ |
| External Secrets Operator | IRSA + Helm + ClusterSecretStore | ✓ |
| Metrics Server | Installed | ✓ |
| GitHub OIDC | `LKS-GitHubActionsRole` (no stored keys) | ✓ |
| GitHub Actions | `deploy.yml` test/build/deploy + auto-rollback | ✓ |
| ConfigMap | `wallet-api-config` (with UPLOAD_PATH) | ✓ |
| ExternalSecret | DB_PASSWORD + JWT_SECRET from Secrets Manager | ✓ |
| **StorageClass** | **`efs-sc` dynamic provisioning via EFS Access Point** | **✓** |
| **PVC** | **`wallet-uploads-pvc` ReadWriteMany, 1Gi** | **✓** |
| Deployment | `wallet-api` 1 replica, EFS volume mounted at `/app/uploads` | ✓ |
| Service | `wallet-api-svc` ClusterIP | ✓ |
| Ingress | ALB internet-facing HTTPS | ⚠️ |
| HPA | CPU 60% / Memory 70%, max 3 replicas | ✓ |
| PDB | Min 1 available | ✓ |
| Container Insights | CloudWatch add-on enabled | ✓ Basic free |
| CloudWatch Alarm | CPU > 80% → SNS `lks-wallet-alerts` | ✓ |
| E2E Validation | Push → build → deploy → EFS read/write across pods | ✓ |

# Step-by-Step: EKS CI/CD — Build It Layer by Layer

**Goal**: Deploy a containerized wallet API on EKS, connected to RDS + EFS + Secrets Manager, with a GitHub Actions CI/CD pipeline.  
**Approach**: Build and test each layer independently before adding the next. Never set up everything at once.  
**Region**: ap-southeast-1 | **Cost warning**: EKS $0.10/hr, NAT Gateway $0.045/hr — delete after use.

---

## Layers

| Layer | What You Build | Test |
|---|---|---|
| **1** | VPC + IAM + EKS + Nodes (with SSH) + Hello App | ALB serves Hello World |
| **2** | ECR + Containerized App | Pods pull from ECR |
| **3** | RDS PostgreSQL | App connects to DB |
| **4** | EFS Shared Storage | Pods read/write shared files |
| **5** | Secrets Manager | App reads secrets from AWS |
| **6** | GitHub Actions CI/CD | `git push` → auto deploy |

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

# ── Download LBC IAM policy ───────────────────────────────────
curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.11.0/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
LBC_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"

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

### 1.8 OIDC + Load Balancer Controller

```bash
# Enable OIDC
OIDC_URL=$(aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION \
  --query "cluster.identity.oidc.issuer" --output text)
OIDC_ID=$(echo $OIDC_URL | awk -F'/' '{print $NF}')

THUMBPRINT=$(echo | openssl s_client \
  -connect oidc.eks.${AWS_REGION}.amazonaws.com:443 2>/dev/null \
  | openssl x509 -fingerprint -sha1 -noout \
  | sed 's/.*=//;s/://g' | tr '[:upper:]' '[:lower:]')

aws iam create-open-id-connect-provider \
  --url $OIDC_URL \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list $THUMBPRINT

# LBC IRSA role
cat > /tmp/lbc-trust.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {
      "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
      "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
    }}
  }]
}
EOF

aws iam create-role --role-name LKS-LBCRole \
  --assume-role-policy-document file:///tmp/lbc-trust.json
aws iam attach-role-policy --role-name LKS-LBCRole --policy-arn $LBC_POLICY_ARN

LBC_ROLE_ARN=$(aws iam get-role --role-name LKS-LBCRole \
  --query 'Role.Arn' --output text)

# Install LBC via Helm
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
```

### 1.9 Deploy Hello App

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
# Wait for ADDRESS, then:
ALB=$(kubectl get ingress wallet-ingress -n wallet \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl http://$ALB
# Expected: nginx welcome page
```

**Layer 1 checkpoint** — before continuing:
- [ ] `kubectl get nodes` shows Ready
- [ ] `curl http://$ALB` returns a response
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

```bash
# From lks-eks-cicd/app/ directory
aws ecr get-login-password --region $AWS_REGION \
  | docker login --username AWS --password-stdin \
  ${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

docker build -t lks-wallet-api:v1.0.0 .
docker tag lks-wallet-api:v1.0.0 ${ECR_URI}:v1.0.0
docker push ${ECR_URI}:v1.0.0
echo "Image pushed: ${ECR_URI}:v1.0.0"
```

### 2.3 Update Deployment to Use ECR Image

```bash
kubectl set image deployment/wallet-app app=${ECR_URI}:v1.0.0 -n wallet
kubectl rollout status deployment/wallet-app -n wallet

# Verify ECR image is running
kubectl get pods -n wallet -o jsonpath='{.items[*].spec.containers[*].image}'
curl http://$ALB/health/live
# Expected: HTTP 200
```

**Layer 2 checkpoint:**
- [ ] Pod describes show ECR image URI
- [ ] App responds on `/health/live`

---

## Layer 3 — RDS PostgreSQL

### 3.1 Security Group for RDS

```bash
RDS_SG=$(aws ec2 create-security-group \
  --group-name lks-rds-sg \
  --description "RDS PostgreSQL" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $RDS_SG \
  --protocol tcp --port 5432 --source-group $NODE_SG
aws ec2 create-tags --resources $RDS_SG --tags Key=Name,Value=lks-rds-sg
echo "RDS SG: $RDS_SG"
```

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
  --engine-version 16.3 \
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
kubectl apply -f - << EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: wallet-config
  namespace: wallet
data:
  APP_ENV: production
  APP_PORT: "8080"
  DB_HOST: "${DB_ENDPOINT}"
  DB_PORT: "5432"
  DB_NAME: wallet_db
  DB_USER: walletadmin
  UPLOAD_PATH: /app/uploads
EOF

kubectl set env deployment/wallet-app --from=configmap/wallet-config -n wallet
kubectl rollout status deployment/wallet-app -n wallet
```

### 3.4 Test DB Connectivity

```bash
POD=$(kubectl get pod -n wallet -l app=wallet-app -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $POD -n wallet -- sh -c "nc -zv $DB_ENDPOINT 5432 && echo 'DB reachable!'"
curl http://$ALB/health/ready
# Expected: HTTP 200 (app connects to DB)
```

**Layer 3 checkpoint:**
- [ ] `nc` shows DB port is reachable from pod
- [ ] `/health/ready` returns 200 (DB connection successful)

---

## Layer 4 — EFS Shared Storage

Multiple pods write payment proof uploads. EFS supports `ReadWriteMany` — EBS does not.

### 4.1 Security Group + EFS

```bash
EFS_SG=$(aws ec2 create-security-group \
  --group-name lks-efs-sg \
  --description "EFS mount targets" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id $EFS_SG \
  --protocol tcp --port 2049 --source-group $NODE_SG
aws ec2 create-tags --resources $EFS_SG --tags Key=Name,Value=lks-efs-sg

EFS_ID=$(aws efs create-file-system \
  --performance-mode generalPurpose \
  --throughput-mode bursting \
  --tags Key=Name,Value=lks-wallet-storage \
  --query 'FileSystemId' --output text)
echo "EFS: $EFS_ID"

aws efs create-mount-target --file-system-id $EFS_ID \
  --subnet-id $PRIV1 --security-groups $EFS_SG
aws efs create-mount-target --file-system-id $EFS_ID \
  --subnet-id $PRIV2 --security-groups $EFS_SG

echo "Waiting for mount targets..."
sleep 30
```

### 4.2 Install EFS CSI Driver

```bash
cat > /tmp/efs-csi-policy.json << 'EOF'
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
EOF

aws iam create-policy --policy-name LKS-EFSCSIPolicy \
  --policy-document file:///tmp/efs-csi-policy.json
EFS_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/LKS-EFSCSIPolicy"

cat > /tmp/efs-csi-trust.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {
      "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:kube-system:efs-csi-controller-sa",
      "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
    }}
  }]
}
EOF

aws iam create-role --role-name LKS-EFSCSIDriverRole \
  --assume-role-policy-document file:///tmp/efs-csi-trust.json
aws iam attach-role-policy --role-name LKS-EFSCSIDriverRole \
  --policy-arn $EFS_POLICY_ARN
EFS_CSI_ROLE_ARN=$(aws iam get-role --role-name LKS-EFSCSIDriverRole \
  --query 'Role.Arn' --output text)

aws eks create-addon \
  --cluster-name $CLUSTER_NAME \
  --addon-name aws-efs-csi-driver \
  --service-account-role-arn $EFS_CSI_ROLE_ARN \
  --region $AWS_REGION

aws eks wait addon-active \
  --cluster-name $CLUSTER_NAME --addon-name aws-efs-csi-driver --region $AWS_REGION
echo "EFS CSI Driver active!"
```

### 4.3 StorageClass + PVC + Mount

```bash
kubectl apply -f - << EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap
  fileSystemId: ${EFS_ID}
  directoryPerms: "700"
EOF

kubectl apply -f - << 'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: wallet-uploads-pvc
  namespace: wallet
spec:
  accessModes:
  - ReadWriteMany
  storageClassName: efs-sc
  resources:
    requests:
      storage: 5Gi
EOF

# Patch deployment to mount EFS
kubectl patch deployment wallet-app -n wallet --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/volumes", "value": [
    {"name": "uploads", "persistentVolumeClaim": {"claimName": "wallet-uploads-pvc"}}
  ]},
  {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts", "value": [
    {"name": "uploads", "mountPath": "/app/uploads"}
  ]}
]'

kubectl rollout status deployment/wallet-app -n wallet
```

### 4.4 Test Shared Storage

```bash
# Scale to 2 pods to test ReadWriteMany
kubectl scale deployment wallet-app -n wallet --replicas=2
kubectl wait --for=condition=ready pod -l app=wallet-app -n wallet --timeout=60s

PODS=($(kubectl get pods -n wallet -l app=wallet-app -o name))
kubectl exec -n wallet ${PODS[0]} -- sh -c "echo 'hello from pod1' > /app/uploads/test.txt"
kubectl exec -n wallet ${PODS[1]} -- cat /app/uploads/test.txt
# Expected: hello from pod1
```

**Layer 4 checkpoint:**
- [ ] PVC is `Bound`
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

cat > /tmp/wallet-app-trust.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {"StringEquals": {
      "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:wallet:wallet-api-sa",
      "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
    }}
  }]
}
EOF

aws iam create-role --role-name LKS-WalletAppRole \
  --assume-role-policy-document file:///tmp/wallet-app-trust.json
aws iam attach-role-policy --role-name LKS-WalletAppRole \
  --policy-arn $WALLET_POLICY_ARN
WALLET_ROLE_ARN=$(aws iam get-role --role-name LKS-WalletAppRole \
  --query 'Role.Arn' --output text)

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
kubectl patch deployment wallet-app -n wallet --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/serviceAccountName", "value": "wallet-api-sa"},
  {"op": "add", "path": "/spec/template/spec/containers/0/envFrom", "value": [
    {"configMapRef": {"name": "wallet-config"}},
    {"secretRef": {"name": "wallet-secrets"}}
  ]}
]'

kubectl rollout status deployment/wallet-app -n wallet

# Verify secrets are injected (names only, not values)
POD=$(kubectl get pod -n wallet -l app=wallet-app -o jsonpath='{.items[0].metadata.name}')
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

```bash
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

kubectl rollout history deployment/wallet-app -n wallet
```

**Layer 6 checkpoint:**
- [ ] All 3 GitHub Actions jobs passed
- [ ] Pod image tag matches the git commit SHA
- [ ] `curl http://$ALB/health/live` returns 200

---

## Cleanup

```bash
# 1. Delete k8s resources
kubectl delete namespace wallet
helm uninstall aws-load-balancer-controller -n kube-system
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
ALB  (internet-facing, public subnets)
    │
    ▼
wallet-app pods  (private subnets, m7i-flex.large)
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

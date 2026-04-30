# Step-by-Step: EKS + ALB — Full Manual Setup from VPC

**Goal**: Deploy a simple nginx app on EKS, accessible via ALB.
**All commands are copy-pasteable AWS CLI / kubectl / helm.**
**Region**: ap-southeast-1 | **Cost warning**: EKS = $0.10/hr — delete after use.

---

## Timeline

| Phase | Task | Est. Time |
|---|---|---|
| 1 | Variables + VPC + Networking | 5 min |
| 2 | IAM Roles | 3 min |
| 3 | EKS Cluster (wait) | 12 min |
| 4 | Node Group (wait) | 5 min |
| 5 | OIDC + Load Balancer Controller | 5 min |
| 6 | Deploy App | 2 min |
| 7 | Test ALB (wait) | 5 min |
| 8 | Cleanup | 5 min |
| **Total** | | **~42 min** |

---

## Phase 1 — Variables + VPC + Networking

Run this block first. All later phases depend on these variables, so **keep the terminal session open**.

```bash
# ── Variables ────────────────────────────────────────────────
export AWS_REGION=ap-southeast-1
export CLUSTER_NAME=lks-simple-eks
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account: $ACCOUNT_ID"

# ── VPC ──────────────────────────────────────────────────────
VPC_ID=$(aws ec2 create-vpc \
  --cidr-block 10.0.0.0/16 \
  --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-hostnames
aws ec2 modify-vpc-attribute --vpc-id $VPC_ID --enable-dns-support
aws ec2 create-tags --resources $VPC_ID \
  --tags Key=Name,Value=lks-simple-vpc

echo "VPC: $VPC_ID"

# ── Public Subnets (2 AZs — required by ALB) ─────────────────
SUBNET1_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.1.0/24 \
  --availability-zone ${AWS_REGION}a \
  --query 'Subnet.SubnetId' --output text)

SUBNET2_ID=$(aws ec2 create-subnet \
  --vpc-id $VPC_ID \
  --cidr-block 10.0.2.0/24 \
  --availability-zone ${AWS_REGION}b \
  --query 'Subnet.SubnetId' --output text)

# Auto-assign public IPs so nodes can reach internet (no NAT Gateway needed)
aws ec2 modify-subnet-attribute --subnet-id $SUBNET1_ID --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --subnet-id $SUBNET2_ID --map-public-ip-on-launch

# Tags required by AWS Load Balancer Controller to discover subnets
aws ec2 create-tags --resources $SUBNET1_ID $SUBNET2_ID \
  --tags \
  Key=kubernetes.io/cluster/${CLUSTER_NAME},Value=shared \
  Key=kubernetes.io/role/elb,Value=1

aws ec2 create-tags --resources $SUBNET1_ID \
  --tags Key=Name,Value=lks-public-1a
aws ec2 create-tags --resources $SUBNET2_ID \
  --tags Key=Name,Value=lks-public-1b

echo "Subnet1: $SUBNET1_ID | Subnet2: $SUBNET2_ID"

# ── Internet Gateway ──────────────────────────────────────────
IGW_ID=$(aws ec2 create-internet-gateway \
  --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 create-tags --resources $IGW_ID --tags Key=Name,Value=lks-simple-igw
aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

echo "IGW: $IGW_ID"

# ── Route Table ───────────────────────────────────────────────
RTB_ID=$(aws ec2 create-route-table \
  --vpc-id $VPC_ID \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-tags --resources $RTB_ID --tags Key=Name,Value=lks-simple-rtb

aws ec2 create-route \
  --route-table-id $RTB_ID \
  --destination-cidr-block 0.0.0.0/0 \
  --gateway-id $IGW_ID

aws ec2 associate-route-table --route-table-id $RTB_ID --subnet-id $SUBNET1_ID
aws ec2 associate-route-table --route-table-id $RTB_ID --subnet-id $SUBNET2_ID

echo "RouteTable: $RTB_ID"
echo "--- Phase 1 done ---"
```

---

## Phase 2 — IAM Roles

### EKS Cluster Role

```bash
cat > /tmp/eks-cluster-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "eks.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name LKS-EKSClusterRole \
  --assume-role-policy-document file:///tmp/eks-cluster-trust.json

aws iam attach-role-policy \
  --role-name LKS-EKSClusterRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy

CLUSTER_ROLE_ARN=$(aws iam get-role \
  --role-name LKS-EKSClusterRole \
  --query 'Role.Arn' --output text)
echo "Cluster Role: $CLUSTER_ROLE_ARN"
```

### EKS Node Role

```bash
cat > /tmp/eks-node-trust.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

aws iam create-role \
  --role-name LKS-EKSNodeRole \
  --assume-role-policy-document file:///tmp/eks-node-trust.json

for POLICY in AmazonEKSWorkerNodePolicy AmazonEC2ContainerRegistryReadOnly AmazonEKS_CNI_Policy; do
  aws iam attach-role-policy \
    --role-name LKS-EKSNodeRole \
    --policy-arn arn:aws:iam::aws:policy/$POLICY
  echo "Attached $POLICY"
done

NODE_ROLE_ARN=$(aws iam get-role \
  --role-name LKS-EKSNodeRole \
  --query 'Role.Arn' --output text)
echo "Node Role: $NODE_ROLE_ARN"
echo "--- Phase 2 done ---"
```

---

## Phase 3 — EKS Cluster

```bash
aws eks create-cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --kubernetes-version 1.29 \
  --role-arn $CLUSTER_ROLE_ARN \
  --resources-vpc-config \
    subnetIds=$SUBNET1_ID,$SUBNET2_ID,\
endpointPublicAccess=true,endpointPrivateAccess=false

echo "Waiting for cluster to be ACTIVE (~12 minutes)..."
aws eks wait cluster-active --name $CLUSTER_NAME --region $AWS_REGION
echo "Cluster ACTIVE!"

# Point kubectl at the new cluster
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
kubectl get svc
# Expected: kubernetes   ClusterIP   10.100.0.1   ...
```

---

## Phase 4 — Node Group (Ubuntu 22.04)

EKS managed node groups don't have a built-in Ubuntu option — you need to supply a custom AMI via a launch template.

### 4a. Get Ubuntu EKS-Optimized AMI

Canonical publishes Ubuntu EKS AMIs to SSM. Fetch the latest for Ubuntu 22.04 + Kubernetes 1.29:

```bash
UBUNTU_AMI=$(aws ssm get-parameter \
  --name /aws/service/canonical/ubuntu/eks/22.04/1.29/stable/current/amd64/hvm/ebs-gp2/ami-id \
  --region $AWS_REGION \
  --query 'Parameter.Value' --output text)
echo "Ubuntu AMI: $UBUNTU_AMI"
```

### 4b. Create EC2 Launch Template

The launch template carries only two things: the AMI and the bootstrap userdata. Everything else (instance type, security groups, IAM) is handled by the nodegroup itself.

```bash
# Bootstrap script — tells the Ubuntu node which cluster to join
cat > /tmp/userdata.sh << EOF
#!/bin/bash
/etc/eks/bootstrap.sh $CLUSTER_NAME
EOF

USERDATA_B64=$(base64 < /tmp/userdata.sh)

LT_ID=$(aws ec2 create-launch-template \
  --launch-template-name lks-ubuntu-lt \
  --launch-template-data "{
    \"imageId\": \"$UBUNTU_AMI\",
    \"userData\": \"$USERDATA_B64\"
  }" \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)

echo "Launch Template: $LT_ID"
```

### 4c. Create Node Group

```bash
aws eks create-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name lks-nodes \
  --node-role $NODE_ROLE_ARN \
  --subnets $SUBNET1_ID $SUBNET2_ID \
  --instance-types t3.small \
  --ami-type CUSTOM \
  --launch-template id=$LT_ID,version=1 \
  --scaling-config minSize=1,maxSize=3,desiredSize=2 \
  --region $AWS_REGION

echo "Waiting for node group to be ACTIVE (~5 minutes)..."
aws eks wait nodegroup-active \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name lks-nodes \
  --region $AWS_REGION
echo "Node group ACTIVE!"

kubectl get nodes
# Expected: 2 nodes — OS shown as ubuntu in node labels
echo "--- Phase 4 done ---"
```

---

## Phase 5 — OIDC + AWS Load Balancer Controller

### 5a. Enable OIDC Provider

```bash
# Get OIDC issuer URL and extract the ID
OIDC_URL=$(aws eks describe-cluster \
  --name $CLUSTER_NAME --region $AWS_REGION \
  --query "cluster.identity.oidc.issuer" --output text)
OIDC_ID=$(echo $OIDC_URL | awk -F'/' '{print $NF}')
echo "OIDC ID: $OIDC_ID"

# Get TLS thumbprint of the OIDC endpoint
THUMBPRINT=$(echo | openssl s_client \
  -connect oidc.eks.${AWS_REGION}.amazonaws.com:443 2>/dev/null \
  | openssl x509 -fingerprint -sha1 -noout \
  | sed 's/.*=//;s/://g' \
  | tr '[:upper:]' '[:lower:]')
echo "Thumbprint: $THUMBPRINT"

# Register the OIDC provider
aws iam create-open-id-connect-provider \
  --url $OIDC_URL \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list $THUMBPRINT

echo "OIDC provider created"
```

### 5b. IAM Policy + Role for LBC (IRSA)

```bash
# Download LBC IAM policy
curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

LBC_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"

# Create trust policy — allows only the LBC service account to assume this role
cat > /tmp/lbc-trust.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:sub": "system:serviceaccount:kube-system:aws-load-balancer-controller",
        "oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}:aud": "sts.amazonaws.com"
      }
    }
  }]
}
EOF

aws iam create-role \
  --role-name LKS-LBCRole \
  --assume-role-policy-document file:///tmp/lbc-trust.json

aws iam attach-role-policy \
  --role-name LKS-LBCRole \
  --policy-arn $LBC_POLICY_ARN

LBC_ROLE_ARN=$(aws iam get-role \
  --role-name LKS-LBCRole \
  --query 'Role.Arn' --output text)
echo "LBC Role: $LBC_ROLE_ARN"
```

### 5c. Create K8s Service Account + Install LBC

```bash
# Create service account annotated with the IAM role ARN
kubectl create serviceaccount aws-load-balancer-controller -n kube-system

kubectl annotate serviceaccount aws-load-balancer-controller \
  -n kube-system \
  eks.amazonaws.com/role-arn=$LBC_ROLE_ARN

# Install LBC via Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$AWS_REGION \
  --set vpcId=$VPC_ID

# Verify controller is running
kubectl rollout status deployment aws-load-balancer-controller -n kube-system
kubectl get deployment -n kube-system aws-load-balancer-controller
# Expected: READY 2/2

echo "--- Phase 5 done ---"
```

---

## Phase 6 — Deploy Application

```bash
# From the lks-eks-simple/ directory
kubectl apply -f k8s/

# Expected output:
# configmap/hello-html created
# deployment.apps/hello-app created
# service/hello-app-svc created
# ingress.networking.k8s.io/hello-app-ingress created

# Watch pods start
kubectl get pods --watch
# Wait for 2/2 Running, then Ctrl+C
```

---

## Phase 7 — Test ALB

The ALB takes 2–4 minutes to be provisioned after the Ingress is applied.

```bash
# Watch until ADDRESS column is populated
kubectl get ingress hello-app-ingress --watch
# Ctrl+C once ADDRESS shows a DNS name

# Grab the URL
ALB_URL=$(kubectl get ingress hello-app-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "App: http://$ALB_URL"

# Test
curl -s http://$ALB_URL | grep -o "<title>.*</title>"
# Expected: <title>Hello EKS</title>

# Open in browser (macOS)
open http://$ALB_URL
```

---

## Phase 8 — Cleanup (Do this to stop costs)

```bash
# 1. Delete K8s resources — this triggers ALB deletion
kubectl delete -f k8s/
echo "Waiting 60s for ALB to be removed..."
sleep 60

# 2. Uninstall Helm chart
helm uninstall aws-load-balancer-controller -n kube-system

# 3. Delete launch template
aws ec2 delete-launch-template --launch-template-id $LT_ID

# 4. Delete node group (wait ~5 min)
aws eks delete-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name lks-nodes \
  --region $AWS_REGION
aws eks wait nodegroup-deleted \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name lks-nodes \
  --region $AWS_REGION
echo "Node group deleted"

# 5. Delete EKS cluster (wait ~5 min)
aws eks delete-cluster --name $CLUSTER_NAME --region $AWS_REGION
aws eks wait cluster-deleted --name $CLUSTER_NAME --region $AWS_REGION
echo "Cluster deleted"

# 6. Delete IAM roles and policies
aws iam detach-role-policy --role-name LKS-LBCRole --policy-arn $LBC_POLICY_ARN
aws iam delete-role --role-name LKS-LBCRole
aws iam delete-policy --policy-arn $LBC_POLICY_ARN

for POLICY in AmazonEKSWorkerNodePolicy AmazonEC2ContainerRegistryReadOnly AmazonEKS_CNI_Policy; do
  aws iam detach-role-policy --role-name LKS-EKSNodeRole \
    --policy-arn arn:aws:iam::aws:policy/$POLICY
done
aws iam delete-role --role-name LKS-EKSNodeRole

aws iam detach-role-policy --role-name LKS-EKSClusterRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
aws iam delete-role --role-name LKS-EKSClusterRole

aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn \
  arn:aws:iam::${ACCOUNT_ID}:oidc-provider/oidc.eks.${AWS_REGION}.amazonaws.com/id/${OIDC_ID}

echo "IAM resources deleted"

# 6. Delete VPC resources (must be in this order)
aws ec2 detach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID
aws ec2 delete-internet-gateway --internet-gateway-id $IGW_ID
aws ec2 delete-subnet --subnet-id $SUBNET1_ID
aws ec2 delete-subnet --subnet-id $SUBNET2_ID
aws ec2 delete-route-table --route-table-id $RTB_ID
aws ec2 delete-vpc --vpc-id $VPC_ID

echo "VPC deleted — all resources cleaned up"
```

---

## Architecture Built

```
Internet
    │  HTTP :80
    ▼
Application Load Balancer
  (internet-facing, provisioned by AWS LBC on Ingress create)
    │  target-type: ip — routes directly to pod IPs
    ▼
Service: hello-app-svc (ClusterIP :80)
    │
    ├── Pod 1: nginx + hello-html ConfigMap
    └── Pod 2: nginx + hello-html ConfigMap

        EKS Cluster (1.29)
        └── Managed Node Group: 2x t3.small
            └── VPC: 10.0.0.0/16
                ├── Subnet 10.0.1.0/24 (ap-southeast-1a)
                └── Subnet 10.0.2.0/24 (ap-southeast-1b)
```

## Concepts Covered

| Concept | Where |
|---|---|
| VPC, subnets, IGW, route tables | Phase 1 |
| IAM roles + trust policies | Phase 2 |
| EKS cluster + node group via AWS CLI | Phase 3–4 |
| OIDC provider + IRSA (pod-level IAM) | Phase 5 |
| AWS Load Balancer Controller | Phase 5 |
| Deployment, Service, Ingress, ConfigMap | Phase 6 |
| ALB provisioned from Kubernetes Ingress | Phase 7 |

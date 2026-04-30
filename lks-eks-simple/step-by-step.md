# Step-by-Step: EKS + ALB — Managed Node Group

**Goal**: Deploy a simple nginx app on EKS, accessible via ALB, using a managed node group.  
**All commands are copy-pasteable AWS CLI / kubectl / helm.**  
**Region**: ap-southeast-1 | **Cost warning**: EKS = $0.10/hr — delete after use.

> **Node group rules learned from experience:**
> - **Never use a custom launch template** — causes AMI/bootstrap mismatch issues
> - **Never use a plain Ubuntu AMI** — `bootstrap.sh` was removed from AL2023 AMIs
> - **Always use `AL2023_x86_64_STANDARD` amiType** — EKS picks the right AMI and injects the correct bootstrap config automatically
> - **Subnet tags must match the cluster name exactly** — `kubernetes.io/cluster/<cluster-name>`

---

## Timeline

| Phase | Task | Est. Time |
|---|---|---|
| 1 | Variables + VPC + Networking | 5 min |
| 2 | IAM Roles | 3 min |
| 3 | EKS Cluster (wait) | 12 min |
| 4 | Node Group (wait) | 7 min |
| 5 | OIDC + Load Balancer Controller | 5 min |
| 6 | Deploy App | 2 min |
| 7 | Test ALB (wait) | 5 min |
| 8 | Cleanup | 5 min |
| **Total** | | **~44 min** |

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

# Tags required by the built-in Load Balancer Controller to discover subnets
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

for POLICY in \
  AmazonEKSWorkerNodePolicy \
  AmazonEKS_CNI_Policy \
  AmazonEC2ContainerRegistryReadOnly; do
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
  --kubernetes-version 1.35 \
  --role-arn $CLUSTER_ROLE_ARN \
  --resources-vpc-config \
    subnetIds=$SUBNET1_ID,$SUBNET2_ID,\
endpointPublicAccess=true,endpointPrivateAccess=false \
  --access-config authenticationMode=API

echo "Waiting for cluster to be ACTIVE (~12 minutes)..."
aws eks wait cluster-active --name $CLUSTER_NAME --region $AWS_REGION
echo "Cluster ACTIVE!"

# Point kubectl at the new cluster
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
kubectl get svc
# Expected: kubernetes   ClusterIP   10.100.0.1   ...

echo "--- Phase 3 done ---"
```

---

## Phase 4 — Node Group

> **Important**: Do NOT use a launch template or custom AMI. Use `amiType=AL2023_x86_64_STANDARD` and let EKS manage the AMI and bootstrap config automatically. Using a custom AMI or the old `bootstrap.sh` user data will cause nodes to fail to join the cluster.

```bash
aws eks create-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name lks-nodes \
  --node-role $NODE_ROLE_ARN \
  --subnets $SUBNET1_ID $SUBNET2_ID \
  --instance-types t3.small \
  --ami-type AL2023_x86_64_STANDARD \
  --scaling-config minSize=1,maxSize=3,desiredSize=2 \
  --region $AWS_REGION

echo "Waiting for node group to be ACTIVE (~7 minutes)..."
aws eks wait nodegroup-active \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name lks-nodes \
  --region $AWS_REGION
echo "Node group ACTIVE!"

kubectl get nodes
# Expected: 2 nodes in Ready state
echo "--- Phase 4 done ---"
```

---

## Phase 5 — OIDC + AWS Load Balancer Controller

### 5a. Enable OIDC Provider

```bash
OIDC_URL=$(aws eks describe-cluster \
  --name $CLUSTER_NAME --region $AWS_REGION \
  --query "cluster.identity.oidc.issuer" --output text)
OIDC_ID=$(echo $OIDC_URL | awk -F'/' '{print $NF}')
echo "OIDC ID: $OIDC_ID"

THUMBPRINT=$(echo | openssl s_client \
  -connect oidc.eks.${AWS_REGION}.amazonaws.com:443 2>/dev/null \
  | openssl x509 -fingerprint -sha1 -noout \
  | sed 's/.*=//;s/://g' \
  | tr '[:upper:]' '[:lower:]')

aws iam create-open-id-connect-provider \
  --url $OIDC_URL \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list $THUMBPRINT

echo "OIDC provider created"
```

### 5b. IAM Policy + Role for LBC (IRSA)

```bash
curl -sO https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.2/docs/install/iam_policy.json

aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

LBC_POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy"

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

### 5c. Install LBC via Helm

```bash
kubectl create serviceaccount aws-load-balancer-controller -n kube-system

kubectl annotate serviceaccount aws-load-balancer-controller \
  -n kube-system \
  eks.amazonaws.com/role-arn=$LBC_ROLE_ARN

helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=$AWS_REGION \
  --set vpcId=$VPC_ID

kubectl rollout status deployment aws-load-balancer-controller -n kube-system
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

echo "--- Phase 6 done ---"
```

---

## Phase 7 — Test ALB

The LBC provisions the ALB 2–4 minutes after the Ingress is applied.

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
# 1. Delete K8s resources — triggers ALB deletion
kubectl delete -f k8s/
echo "Waiting 60s for ALB to be removed..."
sleep 60

# 2. Uninstall Helm chart
helm uninstall aws-load-balancer-controller -n kube-system

# 3. Delete node group (~5 min)
aws eks delete-nodegroup \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name lks-nodes \
  --region $AWS_REGION
aws eks wait nodegroup-deleted \
  --cluster-name $CLUSTER_NAME \
  --nodegroup-name lks-nodes \
  --region $AWS_REGION
echo "Node group deleted"

# 4. Delete EKS cluster (~5 min)
aws eks delete-cluster --name $CLUSTER_NAME --region $AWS_REGION
aws eks wait cluster-deleted --name $CLUSTER_NAME --region $AWS_REGION
echo "Cluster deleted"

# 5. Delete IAM roles
aws iam detach-role-policy --role-name LKS-LBCRole --policy-arn $LBC_POLICY_ARN
aws iam delete-role --role-name LKS-LBCRole
aws iam delete-policy --policy-arn $LBC_POLICY_ARN

for POLICY in \
  AmazonEKSWorkerNodePolicy \
  AmazonEKS_CNI_Policy \
  AmazonEC2ContainerRegistryReadOnly; do
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
  (internet-facing, provisioned by built-in LBC on Ingress create)
    │  target-type: ip — routes directly to pod IPs
    ▼
Service: hello-app-svc (ClusterIP :80)
    │
    ├── Pod 1: nginx + hello-html ConfigMap
    └── Pod 2: nginx + hello-html ConfigMap

        EKS Cluster (1.35)
        └── Managed Node Group: 2x t3.small (AL2023, no launch template)
            └── VPC: 10.0.0.0/16
                ├── Subnet 10.0.1.0/24 (ap-southeast-1a)
                └── Subnet 10.0.2.0/24 (ap-southeast-1b)
```

## Concepts Covered

| Concept | Where |
|---|---|
| VPC, subnets, IGW, route tables | Phase 1 |
| IAM roles + trust policies | Phase 2 |
| EKS cluster via AWS CLI | Phase 3 |
| Managed node group (AL2023, no launch template) | Phase 4 |
| OIDC provider + IRSA (pod-level IAM) | Phase 5 |
| AWS Load Balancer Controller via Helm | Phase 5 |
| Deployment, Service, Ingress, ConfigMap | Phase 6 |
| ALB provisioned from Kubernetes Ingress | Phase 7 |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pods stuck `Pending` longer than 3 min | Auto Mode node not provisioned | Check `kubectl get events` — usually resolves itself |
| Ingress has no ADDRESS after 5 min | Subnet tags wrong | Ensure `kubernetes.io/cluster/<name>` tag matches cluster name exactly |
| `no such host` on Windows kubectl | DNS issue on LAN | Change DNS to `8.8.8.8` / `1.1.1.1` or use mobile hotspot |
| Node group stuck `CREATING` | Wrong AMI or bootstrap script | Use Auto Mode — avoids this entirely |

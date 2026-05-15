# CloudFormation Fundamentals — Step-by-Step Learning Guide

## Layer Overview

| Layer | What You Build | Checkpoint |
|---|---|---|
| **0** | CloudFormation concepts + CLI setup | `aws cloudformation validate-template` succeeds |
| **1** | VPC — subnets, IGW, NAT, route tables | Stack `CREATE_COMPLETE`, 6 subnets visible |
| **2** | Security Groups — ALB → EC2 → RDS chain | 3 SGs in VPC |
| **3** | ALB — load balancer, target group, listener | ALB status `active` |
| **4** | RDS MySQL — subnet group, instance, Secrets Manager | RDS status `available` |
| **5** | EC2 — IAM, Launch Template, Auto Scaling Group | `curl /health` returns `{"status":"ok"}` |
| **6** | Serverless — DynamoDB, Lambda inline, API Gateway | `POST /items` returns item with UUID |

**All code lives in 1 file:**
```
templates/
  main.yaml   ← ALL resources (read top to bottom)
```

---

## Layer 0 — CloudFormation Concepts

### CloudFormation vs Terraform

| | CloudFormation | Terraform |
|---|---|---|
| Made by | AWS | HashiCorp |
| Language | YAML / JSON | HCL |
| State storage | AWS managed (free) | You manage (`tfstate` file) |
| AWS-only | Yes | Multi-cloud |
| Extra install | No (use AWS CLI) | Yes (`terraform` binary) |
| Drift detection | Built-in | `terraform plan` |

Both do the same thing. CloudFormation is the "native" choice on AWS.

### Core Concepts

**Template** — a YAML/JSON file describing what to create:
```yaml
AWSTemplateFormatVersion: '2010-09-09'
Resources:
  MyVPC:
    Type: AWS::EC2::VPC
    Properties:
      CidrBlock: 10.0.0.0/16
```

**Stack** — a deployed instance of a template. One template → one stack → N resources. Delete the stack = delete all its resources.

**Resource** — one AWS object. Format:
```yaml
Resources:
  LogicalName:          # your name (referenced in the same template)
    Type: AWS::Service::ResourceType
    Properties:
      PropertyName: value
```

**!Ref** — reference another resource or parameter. Returns the resource's primary ID:
```yaml
InternetGateway:
  Type: AWS::EC2::InternetGateway

Attachment:
  Type: AWS::EC2::VPCGatewayAttachment
  Properties:
    InternetGatewayId: !Ref InternetGateway   # ← returns IGW ID
```

**!GetAtt** — get a specific attribute of a resource (not just the primary ID):
```yaml
DBSecret:
  Properties:
    SecretString: !Sub
      host: ${DBInstance.Endpoint.Address}   # ← DBInstance endpoint via GetAtt
```

**!Sub** — string substitution. `${LogicalName}` replaced by resource's Ref value:
```yaml
Value: !Sub 'https://${HttpApi}.execute-api.us-east-1.amazonaws.com'
```

**DependsOn** — force creation order when CloudFormation can't auto-detect dependency:
```yaml
PublicRoute:
  Type: AWS::EC2::Route
  DependsOn: VPCGatewayAttachment   # IGW must be attached before adding route
```

**Parameters** — inputs at deploy time. Use for secrets (passwords) or things that change per environment:
```yaml
Parameters:
  DBPassword:
    Type: String
    NoEcho: true    # hides value in console and CLI output

# Use it:
MasterUserPassword: !Ref DBPassword
```

**Outputs** — values to display after stack creation. Also used for cross-stack references:
```yaml
Outputs:
  ALBURL:
    Value: !GetAtt ALB.DNSName
```

### Workflow

```bash
# Validate syntax before deploying
aws cloudformation validate-template --template-body file://templates/main.yaml

# Deploy (create or update)
aws cloudformation deploy \
  --stack-name lks-fundamentals \
  --template-file templates/main.yaml \
  --parameter-overrides DBPassword=MyPass123 \
  --capabilities CAPABILITY_NAMED_IAM

# Watch events during deployment
aws cloudformation describe-stack-events \
  --stack-name lks-fundamentals \
  --query "StackEvents[*].{Time:Timestamp,Status:ResourceStatus,Resource:LogicalResourceId}" \
  --output table

# Get outputs
aws cloudformation describe-stacks \
  --stack-name lks-fundamentals \
  --query "Stacks[0].Outputs" \
  --output table

# Delete everything
aws cloudformation delete-stack --stack-name lks-fundamentals
```

`--capabilities CAPABILITY_NAMED_IAM` — required when template creates IAM roles/policies with custom names. CloudFormation forces you to acknowledge this explicitly.

---

## Layer 1 — VPC + Networking

### 3-tier subnet design (same as Terraform module)

```
Internet
   │ InternetGateway
   ▼
Public subnets   10.0.1/2.0/24    ← ALB + NAT Gateway
   │ NATGateway (outbound only)
   ▼
Private subnets  10.0.11/12.0/24  ← EC2
   │ (no route out)
   ▼
DB subnets       10.0.21/22.0/24  ← RDS
```

### Key CloudFormation patterns for networking

**IGW must be attached before adding routes** — use `DependsOn`:
```yaml
PublicRoute:
  Type: AWS::EC2::Route
  DependsOn: VPCGatewayAttachment   # ← without this, route creation can fail
  Properties:
    GatewayId: !Ref InternetGateway
```

**NAT Gateway needs Elastic IP first** — CloudFormation handles order via `!GetAtt`:
```yaml
NATEIP:
  Type: AWS::EC2::EIP
  DependsOn: VPCGatewayAttachment   # EIP for NAT needs IGW attached
  Properties:
    Domain: vpc

NATGateway:
  Type: AWS::EC2::NatGateway
  Properties:
    AllocationId: !GetAtt NATEIP.AllocationId   # ← GetAtt returns allocation ID
    SubnetId: !Ref PublicSubnetA
```

**DB route table has no default route** — isolated subnet, no `AWS::EC2::Route` resource for it.

### Deploy layer 1

```bash
# You can't target specific resources in CloudFormation like Terraform's -target
# Deploy the full template; CloudFormation creates what's new, skips what exists

aws cloudformation deploy \
  --stack-name lks-fundamentals \
  --template-file templates/main.yaml \
  --parameter-overrides DBPassword=MyPass123 \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1
```

### Layer 1 checkpoint

```bash
VPC_ID=$(aws cloudformation describe-stacks \
  --stack-name lks-fundamentals \
  --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" \
  --output text)

aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "Subnets[].{Name:Tags[?Key=='Name']|[0].Value,CIDR:CidrBlock}" \
  --output table
# 6 subnets: 2 public, 2 private, 2 db
```

---

## Layer 2 — Security Groups

Same chain pattern as Terraform — `SourceSecurityGroupId` instead of CIDR:

```yaml
EC2SecurityGroup:
  Type: AWS::EC2::SecurityGroup
  Properties:
    SecurityGroupIngress:
      - IpProtocol: tcp
        FromPort: 8080
        ToPort: 8080
        SourceSecurityGroupId: !Ref ALBSecurityGroup   # ← SG reference, not CIDR

RDSSecurityGroup:
  Type: AWS::EC2::SecurityGroup
  Properties:
    SecurityGroupIngress:
      - IpProtocol: tcp
        FromPort: 3306
        ToPort: 3306
        SourceSecurityGroupId: !Ref EC2SecurityGroup   # ← EC2 SG only
```

---

## Layer 3 — ALB

```yaml
ALB:
  Type: AWS::ElasticLoadBalancingV2::LoadBalancer
  Properties:
    Type: application
    Scheme: internet-facing
    SecurityGroups:
      - !Ref ALBSecurityGroup
    Subnets:
      - !Ref PublicSubnetA
      - !Ref PublicSubnetB          # ALB requires ≥2 subnets in different AZs

ALBTargetGroup:
  Type: AWS::ElasticLoadBalancingV2::TargetGroup
  Properties:
    Port: 8080
    Protocol: HTTP
    TargetType: instance            # register EC2 instances (vs ip or lambda)
    HealthCheckPath: /health

ALBListener:
  Type: AWS::ElasticLoadBalancingV2::Listener
  Properties:
    LoadBalancerArn: !Ref ALB
    Port: 80
    Protocol: HTTP
    DefaultActions:
      - Type: forward
        TargetGroupArn: !Ref ALBTargetGroup
```

### Layer 3 checkpoint

```bash
aws elbv2 describe-load-balancers \
  --names lks-alb \
  --query "LoadBalancers[0].State.Code" \
  --output text
# active
```

---

## Layer 4 — RDS MySQL

### DeletionPolicy

CloudFormation default behavior on stack delete is to **retain** RDS instances (to prevent accidental data loss). For exam environments, set `DeletionPolicy: Delete` so `delete-stack` actually removes the DB:

```yaml
DBInstance:
  Type: AWS::RDS::DBInstance
  DeletionPolicy: Delete          # ← without this, delete-stack leaves RDS running
  Properties:
    DeletionProtection: false
    SkipFinalSnapshot: true       # wait, CloudFormation uses different property...
```

Actually in CloudFormation, `SkipFinalSnapshot` is handled differently:
```yaml
DBInstance:
  Type: AWS::RDS::DBInstance
  DeletionPolicy: Delete
  Properties:
    BackupRetentionPeriod: 1      # set to 0 to also disable automated backups
```

### Secret using !Sub

CloudFormation's `!Sub` can interpolate resource attributes inline:
```yaml
DBSecret:
  Type: AWS::SecretsManager::Secret
  Properties:
    SecretString: !Sub |
      {
        "host": "${DBInstance.Endpoint.Address}",
        "password": "${DBPassword}"
      }
```

`${DBInstance.Endpoint.Address}` calls `GetAtt DBInstance.Endpoint.Address` under the hood.

### Layer 4 checkpoint

```bash
aws rds describe-db-instances \
  --db-instance-identifier lks-mysql \
  --query "DBInstances[0].DBInstanceStatus" \
  --output text
# available (takes 5-10 min)

aws secretsmanager get-secret-value \
  --secret-id lks-db-credentials \
  --query SecretString --output text | python3 -m json.tool
```

---

## Layer 5 — EC2 Auto Scaling Group

### SSM Parameter for latest AMI

Instead of hardcoding an AMI ID (which changes per region and update), use SSM Parameter Store:

```yaml
LaunchTemplate:
  Properties:
    LaunchTemplateData:
      ImageId: !Sub '{{resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}}'
```

`{{resolve:ssm:PATH}}` is a CloudFormation dynamic reference — resolved at deploy time, always returns the latest AMI ID for the region.

### UserData in CloudFormation

Must be Base64-encoded. Use `Fn::Base64` + `!Sub` combo:

```yaml
UserData:
  Fn::Base64: !Sub |
    #!/bin/bash
    # !Sub allows ${LogicalName} references here
    SECRET_ARN=${DBSecret}
    aws secretsmanager get-secret-value --secret-id $SECRET_ARN ...
```

`!Sub` runs first (replaces `${DBSecret}` with the ARN), then `Fn::Base64` encodes the result.

### UpdatePolicy for rolling updates

```yaml
AutoScalingGroup:
  UpdatePolicy:
    AutoScalingRollingUpdate:
      MinInstancesInService: 1
      MaxBatchSize: 1
```

When you update the template and redeploy, CloudFormation replaces instances one at a time, keeping at least 1 healthy — zero-downtime deployments.

### Layer 5 checkpoint

```bash
ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name lks-fundamentals \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDnsName'].OutputValue" \
  --output text)

# Wait ~3 min for instance boot + health check
curl http://$ALB_DNS/health
# {"status": "ok"}

curl http://$ALB_DNS/db-test
# {"mysql_version": "8.0.x"}
```

---

## Layer 6 — Serverless

### Lambda inline code

CloudFormation supports Lambda code directly in the template via `ZipFile` — no S3 upload needed for small functions:

```yaml
LambdaFunction:
  Type: AWS::Lambda::Function
  Properties:
    Code:
      ZipFile: |
        import json, boto3, os, uuid
        def lambda_handler(event, context):
            # ...
```

Limitation: max 4096 characters. For larger functions, upload a zip to S3 and reference:
```yaml
Code:
  S3Bucket: my-bucket
  S3Key: lambda.zip
```

### API Gateway permission

Same concept as Terraform — explicit permission required:
```yaml
LambdaPermission:
  Type: AWS::Lambda::Permission
  Properties:
    Action: lambda:InvokeFunction
    Principal: apigateway.amazonaws.com
    SourceArn: !Sub 'arn:aws:execute-api:us-east-1:${AWS::AccountId}:${HttpApi}/*/*'
```

`${AWS::AccountId}` is a **pseudo parameter** — CloudFormation built-in. Others:
- `${AWS::Region}` — current region
- `${AWS::StackName}` — current stack name
- `${AWS::NoValue}` — removes a property (conditional resource config)

### Layer 6 checkpoint

```bash
API_URL=$(aws cloudformation describe-stacks \
  --stack-name lks-fundamentals \
  --query "Stacks[0].Outputs[?OutputKey=='ApiUrl'].OutputValue" \
  --output text)

# Create
curl -X POST "$API_URL/items" \
  -H "Content-Type: application/json" \
  -d '{"name":"laptop","price":1500}'
# {"id":"550e8400-...", "name":"laptop", "price":1500}

# Get
ID=<paste id>
curl "$API_URL/items/$ID"

# Delete
curl -X DELETE "$API_URL/items/$ID"
```

---

## Full Deploy

```bash
./scripts/01-deploy.sh
# Enter DB password when prompted

# Watch progress in another terminal
watch -n 5 'aws cloudformation describe-stack-events \
  --stack-name lks-fundamentals \
  --query "StackEvents[:5].{Status:ResourceStatus,Resource:LogicalResourceId}" \
  --output table'

# Validate
./scripts/02-validate.sh
```

---

## Common Errors

**`ROLLBACK_COMPLETE` on first deploy** — stack failed, resources rolled back. Fix the error, then **delete the stack** before redeploying:
```bash
aws cloudformation delete-stack --stack-name lks-fundamentals
aws cloudformation wait stack-delete-complete --stack-name lks-fundamentals
# Then redeploy
```

**`CAPABILITY_NAMED_IAM` error** — template creates named IAM resources. Add flag:
```bash
--capabilities CAPABILITY_NAMED_IAM
```

**`AlreadyExistsException` on resource names** — hardcoded names like `lks-alb-sg` already exist from a previous stack. Delete old stack or change the name.

**UserData script fails** — check cloud-init log:
```bash
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names lks-asg \
  --query "AutoScalingGroups[0].Instances[0].InstanceId" --output text)
aws ssm start-session --target $INSTANCE_ID
# Inside:
cat /var/log/cloud-init-output.log
```

---

## CloudFormation vs Terraform — Quick Reference

| Task | CloudFormation | Terraform |
|---|---|---|
| Preview changes | `aws cloudformation deploy --no-execute-changeset` | `terraform plan` |
| Apply changes | `aws cloudformation deploy` | `terraform apply` |
| Reference resource | `!Ref LogicalName` | `resource_type.name.id` |
| Get attribute | `!GetAtt Name.Attribute` | `resource_type.name.attribute` |
| String sub | `!Sub '${Name}'` | `"${resource.name.id}"` |
| Import existing | `aws cloudformation import` | `terraform import` |
| Destroy | `delete-stack` | `terraform destroy` |

---

## Destroy

```bash
./scripts/03-destroy.sh

# Verify
aws rds describe-db-instances \
  --query "DBInstances[?DBInstanceIdentifier=='lks-mysql'].DBInstanceStatus" \
  --output text   # empty = deleted

aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available" \
  --query "NatGateways[].NatGatewayId" --output text   # empty = deleted
```

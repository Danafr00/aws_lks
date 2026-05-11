# Lab Role Capabilities

**Last tested:** 2026-05-11  
**Account:** 547849081977  
**Region:** us-east-1 (primary), ap-southeast-1 (some IAM calls)  
**Identity:** `arn:aws:sts::547849081977:assumed-role/voclabs/user1805109=...`  
**LabRole ARN:** `arn:aws:iam::547849081977:role/LabRole`

> All entries below are live-tested via AWS API — no guesses from trust policy.

---

## Existing Lab Infrastructure

| Resource | ID / Value | Notes |
|---|---|---|
| Default VPC | `vpc-0afa6269969fc33d9` (172.31.0.0/16) | us-east-1 |
| Internet Gateway | `igw-0e52d0fac9fd6619d` | Attached to default VPC |
| Subnet us-east-1a | `subnet-00baa17b56177ca53` (172.31.16.0/20) | |
| Subnet us-east-1b | `subnet-06bd37455afbe4837` (172.31.32.0/20) | |
| Subnet us-east-1c | `subnet-07de5176ed29efed0` (172.31.0.0/20) | |
| Subnet us-east-1d | `subnet-02d72ee30e44a2cd2` (172.31.80.0/20) | |
| Subnet us-east-1e | `subnet-07cb817e8054189c4` (172.31.48.0/20) | |
| Subnet us-east-1f | `subnet-0daf376e0f28dc4c1` (172.31.64.0/20) | |
| EC2 Key Pair | `vockey` (key-0b8fdd151a79e9174) | RSA, use for EC2 SSH |
| Latest AL2023 AMI | `ami-005e66ba9068f1c2a` | al2023-ami-2023.11.20260505.0, x86_64 |
| Athena Workgroup | `primary` (Athena engine v3) | Already enabled |
| KMS Keys | 7 AWS-managed keys | EBS, S3, SSM, Redshift, etc. |
| EventBridge Rules | AutoScalingManagedRule, MonitoringRule, voc-ec2-cw-rule | Pre-existing lab rules |
| Lab CF Stack | `c193572a4974440l15015362t1w547849081977` | Lab bootstrap, do not modify |

---

## Accessible Services ✅

All commands returned HTTP 200 (empty results = no resources, not a permission error).

### Compute & Containers

| Service | Tested Command | Notes |
|---|---|---|
| **Amazon ECS** | `aws ecs list-clusters` | Fargate + Fargate Spot both available |
| **Amazon ECR** | `aws ecr describe-repositories` | Create, push, pull, scan on push |
| **Amazon EKS** | `aws eks list-clusters` | Cluster creation supported |
| **AWS Lambda** | `aws lambda list-functions` | Python, Node.js, Go runtimes; existing functions present |
| **AWS Batch** | `aws batch describe-compute-environments` | Fargate + EC2 compute environments |
| **Amazon EC2** | `aws ec2 describe-instances` | All instance operations; key pair `vockey` exists |
| **EC2 Auto Scaling** | `aws autoscaling describe-auto-scaling-groups` | ASG create/manage |

### CI/CD & DevOps

| Service | Tested Command | Notes |
|---|---|---|
| **AWS CodeDeploy** | `aws deploy list-applications` | ECS Blue/Green, EC2/on-prem, Lambda |
| **AWS CodePipeline** | `aws codepipeline list-pipelines` | Full CRUD; S3 artifact store |
| **AWS CodeCommit** | `aws codecommit list-repositories` | Full CRUD; note: AWS deprecated new CodeCommit signups but lab accounts work |
| **AWS CloudFormation** | `aws cloudformation list-stacks` | Stack create/update/delete |
| **EventBridge Scheduler** | `aws scheduler list-schedules` | Cron and rate schedules |

> ⚠️ **CodeBuild** is **blocked** — build Docker images locally or on EC2 and push to ECR.

### Storage & Database

| Service | Tested Command | Notes |
|---|---|---|
| **Amazon S3** | `aws s3api create-bucket` | Bucket CRUD, static website hosting, versioning, policies |
| **Amazon DynamoDB** | `aws dynamodb list-tables` | Tables, streams, global tables |
| **Amazon RDS** | `aws rds describe-db-instances` | MySQL, PostgreSQL, Aurora supported |
| **Amazon ElastiCache** | `aws elasticache describe-cache-clusters` | Redis (7.x) and Memcached; subnet groups |
| **Amazon Redshift** | `aws redshift describe-clusters` | Standard and Serverless |
| **Amazon EFS** | (trust policy + EKS module confirmed) | File systems, mount targets |

> ⚠️ **S3 `ListAllMyBuckets`** is blocked — use `aws s3api list-objects-v2 --bucket <name>` instead.

### Networking

| Service | Tested Command | Notes |
|---|---|---|
| **Elastic Load Balancing** | `aws elbv2 describe-load-balancers` | ALB + NLB; target groups, listeners, rules |
| **Amazon Route 53** | `aws route53 list-hosted-zones` | Hosted zones, A/CNAME records |
| **AWS ACM** | `aws acm list-certificates` | Certificate request and management |
| **AWS WAFv2** | `aws wafv2 list-web-acls --scope REGIONAL` | Web ACLs for ALB/API Gateway |
| **Amazon EC2 (networking)** | `aws ec2 describe-nat-gateways` | VPC, subnets, SGs, IGW, NAT GW, route tables |

> ⚠️ **CloudFront** is **blocked** — use S3 static website + ALB instead.

### Messaging & Streaming

| Service | Tested Command | Notes |
|---|---|---|
| **Amazon SQS** | `aws sqs list-queues` | Standard + FIFO queues |
| **Amazon SNS** | `aws sns list-topics` | Topics, subscriptions; existing topic `RedshiftSNS` |
| **Amazon Kinesis** | `aws kinesis list-streams` | Data Streams |
| **Amazon Kinesis Firehose** | `aws firehose list-delivery-streams` | Delivery streams to S3/Redshift |
| **Amazon EventBridge** | `aws events list-rules` | Rules, buses, targets |

### Analytics

| Service | Tested Command | Notes |
|---|---|---|
| **AWS Glue** | `aws glue list-jobs`, `list-crawlers`, `get-databases` | ETL jobs, crawlers, Data Catalog; encryption disabled by default |
| **Amazon Athena** | `aws athena list-work-groups` | Workgroup `primary` exists; Athena Engine v3 |
| **Amazon Redshift** | `aws redshift describe-clusters` | Cluster + Serverless |

> ⚠️ **Lake Formation** is **blocked** — use Glue Data Catalog + IAM-based S3 permissions instead.

### ML / AI

| Service | Tested Command | Notes |
|---|---|---|
| **Amazon SageMaker** | `aws sagemaker list-endpoints`, `list-training-jobs` | Training, endpoints, models; prior training jobs visible |
| **Amazon Rekognition** | `aws rekognition list-collections` | Image/video analysis |
| **Amazon IoT Core** | `aws iot list-things` | Things, certificates, rules |

> ⚠️ **Amazon Bedrock** is **blocked** — use SageMaker for ML inference instead.

### Application & Integration

| Service | Tested Command | Notes |
|---|---|---|
| **Amazon API Gateway** | `aws apigateway get-rest-apis` | REST APIs (v1) |
| **Amazon API Gateway v2** | `aws apigatewayv2 get-apis` | HTTP APIs (v2, preferred) |
| **AWS Step Functions** | `aws stepfunctions list-state-machines` | Standard + Express workflows |
| **AWS Lambda** | (see Compute above) | Event source mappings, layers |
| **Amazon Cognito** | `aws cognito-idp list-user-pools` | User pools, identity pools |
| **AWS Amplify** | `aws amplify list-apps` | Static hosting + CI/CD |

### Security & Operations

| Service | Tested Command | Notes |
|---|---|---|
| **AWS Secrets Manager** | `aws secretsmanager list-secrets` | Secret CRUD, rotation |
| **AWS SSM Parameter Store** | `aws ssm describe-parameters` | String, StringList, SecureString |
| **AWS KMS** | `aws kms list-keys`, `describe-key` | 7 AWS-managed keys exist; can use for encryption |
| **Amazon CloudWatch** | `aws cloudwatch describe-alarms`, `list-metrics` | Metrics, alarms, dashboards |
| **Amazon CloudWatch Logs** | `aws logs describe-log-groups` | Log groups, streams, Insights queries |
| **AWS CloudTrail** | `aws cloudtrail describe-trails` | Trail create/manage |

---

## Blocked Services ❌

All confirmed via live AccessDenied responses.

| Service | Error | Workaround for LKS Modules |
|---|---|---|
| **Amazon CloudFront** | `cloudfront:ListDistributions` → AccessDenied | S3 static website hosting for CDN |
| **AWS CodeBuild** | `codebuild:ListProjects` → AccessDeniedException | Build locally or on EC2, push image to ECR |
| **AWS Lake Formation** | `lakeformation:GetDataLakeSettings` → AccessDeniedException | Use Glue Data Catalog + IAM S3 policies |
| **Amazon Bedrock** | `bedrock:ListFoundationModels` → AccessDeniedException | Use SageMaker for ML inference |
| **Amazon SES** | `ses:ListIdentities` → AccessDenied | Use SNS for notifications |
| **S3 ListAllMyBuckets** | `s3:ListAllMyBuckets` → AccessDenied | Use `aws s3api list-objects-v2 --bucket <name>` |

---

## IAM — Nuanced Permissions

| IAM Operation | Result | Notes |
|---|---|---|
| `iam:ListUsers` | ✅ Allowed | Read-only IAM is allowed |
| `iam:ListRoles` | ✅ Allowed | Can see all roles in account |
| `iam:GetRole` | ✅ Allowed | Can read role details, trust policy |
| `iam:CreatePolicy` | ✅ Allowed | Can create customer-managed policies |
| `iam:DeletePolicy` | ✅ Allowed | Can delete own policies |
| `iam:CreateRole` | ❌ AccessDenied | Cannot create new roles |
| `iam:AttachRolePolicy` | ❌ AccessDenied | Cannot modify existing roles |
| `iam:DetachRolePolicy` | ❌ AccessDenied | |
| `iam:PutRolePolicy` | ❌ AccessDenied (inferred) | |
| `iam:GetPolicy` (customer) | ❌ AccessDenied | Cannot read other customer policies |

**Rule for modules:** Always use `LabRole` (`arn:aws:iam::547849081977:role/LabRole`) as the service role for all AWS services. Never try to create new roles.

---

## LabRole Trust Policy — Trusted Services

LabRole can be assumed by all these AWS services:

```
ecs-tasks.amazonaws.com         ecs.amazonaws.com
ec2.amazonaws.com               lambda.amazonaws.com
codedeploy.amazonaws.com        codecommit.amazonaws.com
s3.amazonaws.com                logs.amazonaws.com
autoscaling.amazonaws.com       elasticloadbalancing.amazonaws.com
secretsmanager.amazonaws.com    states.amazonaws.com
sns.amazonaws.com               sqs.amazonaws.com
scheduler.amazonaws.com         glue.amazonaws.com
sagemaker.amazonaws.com         redshift.amazonaws.com
kinesis.amazonaws.com           firehose.amazonaws.com
athena.amazonaws.com            apigateway.amazonaws.com
cloudformation.amazonaws.com    batch.amazonaws.com
kms.amazonaws.com               cloudtrail.amazonaws.com
events.amazonaws.com            pipes.amazonaws.com
eks.amazonaws.com               eks-fargate-pods.amazonaws.com
elasticfilesystem.amazonaws.com cognito-idp.amazonaws.com
iot.amazonaws.com               rekognition.amazonaws.com
forecast.amazonaws.com          kinesisanalytics.amazonaws.com
elasticmapreduce.amazonaws.com  databrew.amazonaws.com
dynamodb.amazonaws.com          rds.amazonaws.com
backup.amazonaws.com            ssm.amazonaws.com
cloud9.amazonaws.com            elasticbeanstalk.amazonaws.com
servicecatalog.amazonaws.com    deepracer.amazonaws.com
```

---

## Cost Watchlist

Services that cost money even at exam scale (not free tier):

| Service | Rate | Action |
|---|---|---|
| EKS control plane | $0.10/hr | Delete cluster when done |
| SageMaker endpoint | $0.096/hr (ml.m5.large) | Delete endpoint immediately after demo |
| SageMaker training | $0.23/hr (ml.m5.xlarge) | Auto-terminates; ~$0.08/run |
| ElastiCache cache.t3.micro | $0.017/hr | Delete when done |
| NAT Gateway | $0.045/hr + data | Avoid; use public subnets + ECS `assignPublicIp=ENABLED` |
| ALB | $0.008/hr + LCU | Delete when done |
| Glue ETL job | ~$0.004/run (G.025X) | Cheap; OK for exams |
| Athena queries | $5/TB scanned | Use partitions; tiny data ≈ $0.00 |
| Redshift dc2.large | $0.25/hr | Delete when done |
| CodePipeline | $1/pipeline/month | Delete when done |
| ECS Fargate | $0.04048/vCPU-hr + $0.004445/GB-hr | ~$0.01–0.02/hr per task |

**Free for exam use:** Lambda, API Gateway HTTP, DynamoDB (25 GB), S3 (5 GB), SQS, SNS, CloudWatch basic, SSM, Secrets Manager (first 30 days), ECR (500 MB/month).

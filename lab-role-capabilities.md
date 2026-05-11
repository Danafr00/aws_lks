# Lab Role Capabilities

**Tested:** 2026-05-11  
**Account:** 547849081977  
**Region:** us-east-1  
**Identity:** `arn:aws:sts::547849081977:assumed-role/voclabs/user1805109=...`  
**LabRole ARN:** `arn:aws:iam::547849081977:role/LabRole`

---

## Infrastructure

| Resource | Value |
|---|---|
| Default VPC | `vpc-0afa6269969fc33d9` (172.31.0.0/16) |
| Subnet us-east-1a | `subnet-00baa17b56177ca53` (172.31.16.0/20) |
| Subnet us-east-1b | `subnet-06bd37455afbe4837` (172.31.32.0/20) |
| Subnet us-east-1c | `subnet-07de5176ed29efed0` (172.31.0.0/20) |
| Subnet us-east-1d | `subnet-02d72ee30e44a2cd2` (172.31.80.0/20) |
| Subnet us-east-1e | `subnet-07cb817e8054189c4` (172.31.48.0/20) |
| Subnet us-east-1f | `subnet-0daf376e0f28dc4c1` (172.31.64.0/20) |

---

## Accessible Services (lab-tested ✅)

| Service | Test Command | Notes |
|---|---|---|
| **Amazon ECR** | `aws ecr describe-repositories` | Full access: create, push, pull |
| **Amazon ECS** | `aws ecs list-clusters` | Fargate supported |
| **AWS CodeDeploy** | `aws deploy list-applications` | Blue/Green on ECS supported |
| **AWS CodePipeline** | `aws codepipeline list-pipelines` | Full CRUD |
| **AWS CodeCommit** | `aws codecommit list-repositories` | Full CRUD; note: deprecated for new users in most regions but still works in lab |
| **Amazon ElastiCache** | `aws elasticache describe-cache-clusters` | Redis and Memcached both accessible |
| **Elastic Load Balancing** | `aws elbv2 describe-load-balancers` | ALB + NLB, target groups, listeners |
| **Amazon S3** | `aws s3api create-bucket` | Bucket creation, object operations, static website hosting |
| **Amazon EC2** | `aws ec2 describe-vpcs` | Security groups, key pairs, instances |
| **AWS Secrets Manager** | `aws secretsmanager list-secrets` | Full CRUD |
| **AWS SSM Parameter Store** | `aws ssm describe-parameters` | Standard parameters |
| **Amazon CloudWatch Logs** | `aws logs describe-log-groups` | Log groups, streams, queries |
| **AWS ACM** | `aws acm list-certificates` | Certificate request and management |
| **Amazon Route 53** | `aws route53 list-hosted-zones` | Hosted zones and records |
| **AWS Lambda** | (trust policy) | Available via LabRole trust |
| **Amazon SNS** | (trust policy) | Available via LabRole trust |
| **AWS Step Functions** | (trust policy) | Available via LabRole trust |
| **Amazon Kinesis** | (trust policy) | Available via LabRole trust |
| **AWS Glue** | (trust policy) | Available via LabRole trust |
| **Amazon Athena** | (trust policy) | Available via LabRole trust |
| **Amazon RDS** | (trust policy) | Available via LabRole trust |
| **Amazon DynamoDB** | (trust policy) | Available via LabRole trust |
| **AWS Batch** | (trust policy) | Available via LabRole trust |

---

## Blocked Services (AccessDenied ❌)

| Service | Error | Workaround |
|---|---|---|
| **Amazon CloudFront** | `cloudfront:ListDistributions` → AccessDenied | Use S3 static website + ALB instead |
| **AWS CodeBuild** | `codebuild:ListProjects` → AccessDeniedException | Build images locally or on EC2, push to ECR manually |
| **S3 ListAllMyBuckets** | `s3:ListAllMyBuckets` → AccessDenied | Use `aws s3api list-objects-v2 --bucket <name>` on specific bucket |

---

## LabRole Trust Policy — Trusted AWS Services

LabRole can be assumed by these services (from `sts:AssumeRole`):

```
codedeploy.amazonaws.com        ecs-tasks.amazonaws.com
ecs.amazonaws.com               ec2.amazonaws.com
s3.amazonaws.com                lambda.amazonaws.com
logs.amazonaws.com              autoscaling.amazonaws.com
elasticloadbalancing.amazonaws.com  secretsmanager.amazonaws.com
states.amazonaws.com            sns.amazonaws.com
sqs.amazonaws.com               scheduler.amazonaws.com
codecommit.amazonaws.com        glue.amazonaws.com
sagemaker.amazonaws.com         redshift.amazonaws.com
kinesis.amazonaws.com           firehose.amazonaws.com
athena.amazonaws.com            apigateway.amazonaws.com
cloudformation.amazonaws.com    batch.amazonaws.com
kms.amazonaws.com               cloudtrail.amazonaws.com
events.amazonaws.com            pipes.amazonaws.com
```

---

## IAM Constraints

- **Cannot** create new IAM users, roles, or policies
- **Cannot** modify existing IAM roles or policies  
- **Must** use existing `LabRole` for all service roles (ECS task role, CodeDeploy service role, etc.)
- All scripts and guides use `LabRole` ARN: `arn:aws:iam::547849081977:role/LabRole`

---

## Cost Notes for This Module

| Service | Estimated Cost |
|---|---|
| ECS Fargate (2 tasks × 0.25 vCPU × 0.5 GB) | ~$0.02/hr per task |
| ElastiCache cache.t3.micro | ~$0.017/hr |
| ALB | ~$0.008/hr + LCU charges |
| CodePipeline (1 pipeline) | $1/month |
| ECR storage | $0.10/GB/month |
| S3 static site | < $0.01 for exam use |

**Delete in order:** ECS service → ElastiCache → ALB → ECR repos → S3 bucket → CodePipeline → CodeDeploy → CodeCommit

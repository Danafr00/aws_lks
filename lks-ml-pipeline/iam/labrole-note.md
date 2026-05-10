# IAM Note — LabRole

This module uses the pre-existing **LabRole** for all AWS services.
No new IAM roles are created (`iam:CreateRole` is restricted in Vocareum labs).

**Role ARN pattern:** `arn:aws:iam::<ACCOUNT_ID>:role/LabRole`

## Services using LabRole

| Service | Previously-defined role | Now replaced by |
|---|---|---|
| Lambda | LKS-FeatureLambdaRole | LabRole |
| Glue ETL + Crawler | LKS-GlueETLRole | LabRole |
| SageMaker Training + Endpoint | LKS-SageMakerRole | LabRole |
| ECS Fargate task | LKS-ECSTaskRole | LabRole |
| ECS Fargate execution | LKS-ECSExecutionRole | LabRole |

## IAM JSON Files (documentation only)

The `*-trust.json` and `*-policy.json` files in this folder describe what permissions
each service logically needs. They are kept as reference documentation but are NOT
applied in the Vocareum lab environment — LabRole already has the required permissions.

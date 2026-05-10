# IAM Note — LabRole

This module uses the pre-existing **LabRole** for all AWS services.
No new IAM roles are created.

**Role ARN pattern:** `arn:aws:iam::<ACCOUNT_ID>:role/LabRole`

## Services using LabRole

| Service | How LabRole is used |
|---|---|
| Lambda | Execution role (DynamoDB write, Firehose PutRecord, CloudWatch logs) |
| Glue ETL | Job role (S3 read/write, Glue catalog, CloudWatch logs) |
| Glue Crawler | Crawler role (S3 read, Glue catalog write) |
| Kinesis Firehose | Delivery role (S3 write, CloudWatch logs) |
| Redshift | Associated IAM role for COPY from S3 |

## Required Permissions (already on LabRole in Vocareum labs)

- `s3:GetObject`, `s3:PutObject`, `s3:ListBucket`
- `dynamodb:PutItem`, `dynamodb:GetItem`
- `firehose:PutRecord`, `firehose:PutRecordBatch`
- `glue:GetDatabase`, `glue:CreateTable`, `glue:GetTable`, `glue:UpdateTable`
- `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`
- `kinesis:GetRecords`, `kinesis:GetShardIterator`, `kinesis:DescribeStream`

import json
import boto3
import os

GLUE_JOB_NAME = os.environ['GLUE_JOB_NAME']
S3_PROCESSED_BUCKET = os.environ['S3_PROCESSED_BUCKET']
S3_PROCESSED_PREFIX = os.environ.get('S3_PROCESSED_PREFIX', 'sales')

glue = boto3.client('glue')

def handler(event, context):
    detail = event.get('detail', {})
    bucket = detail.get('bucket', {}).get('name', '')
    key = detail.get('object', {}).get('key', '')

    print(f"Event received: bucket={bucket}, key={key}")

    if not key.lower().endswith('.csv'):
        print(f"Skipping non-CSV file: {key}")
        return {'statusCode': 200, 'body': 'skipped — not a CSV'}

    if not key.startswith('data/sales/'):
        print(f"Skipping file outside data/sales/ prefix: {key}")
        return {'statusCode': 200, 'body': 'skipped — wrong prefix'}

    s3_raw_path = f"s3://{bucket}/{key}"
    print(f"Starting Glue job '{GLUE_JOB_NAME}' for: {s3_raw_path}")

    response = glue.start_job_run(
        JobName=GLUE_JOB_NAME,
        Arguments={
            '--S3_RAW_PATH': s3_raw_path,
            '--S3_PROCESSED_BUCKET': S3_PROCESSED_BUCKET,
            '--S3_PROCESSED_PREFIX': S3_PROCESSED_PREFIX,
        }
    )

    run_id = response['JobRunId']
    print(f"Glue job run started: {run_id}")
    return {
        'statusCode': 200,
        'body': json.dumps({'jobName': GLUE_JOB_NAME, 'jobRunId': run_id})
    }

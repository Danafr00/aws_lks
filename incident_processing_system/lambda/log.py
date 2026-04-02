import boto3
import json

s3 = boto3.client('s3')

LOG_BUCKET = "incident-logs"

def lambda_handler(event, context):

    s3.put_object(
        Bucket=LOG_BUCKET,
        Key=f"log-{event['id']}.json",
        Body=json.dumps(event)
    )

    return event
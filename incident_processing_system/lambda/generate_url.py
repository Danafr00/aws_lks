import boto3
import json
import uuid

s3 = boto3.client('s3')

BUCKET = "incident-input-bucket"

def lambda_handler(event, context):

    file_name = f"{uuid.uuid4()}.json"

    url = s3.generate_presigned_url(
        ClientMethod='put_object',
        Params={
            'Bucket': BUCKET,
            'Key': file_name,
            'ContentType': 'application/json'
        },
        ExpiresIn=300
    )

    return {
        "statusCode": 200,
        "headers": {"Access-Control-Allow-Origin": "*"},
        "body": json.dumps({
            "upload_url": url
        })
    }
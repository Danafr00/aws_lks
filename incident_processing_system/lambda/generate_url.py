import boto3
import json
import os
import uuid
from botocore.config import Config

# The explicit regional endpoint makes the presigned URL point at
# <bucket>.s3.ap-southeast-1.amazonaws.com. Without it boto3 can emit the
# global host, S3 answers 307, and the browser CORS preflight fails.
s3 = boto3.client(
    's3',
    region_name='ap-southeast-1',
    endpoint_url='https://s3.ap-southeast-1.amazonaws.com',
    config=Config(signature_version='s3v4', s3={'addressing_style': 'virtual'})
)

# Set as a Lambda environment variable. S3 bucket names are global, so use
# your own unique name, e.g. incident-input-bucket-<yourname>.
BUCKET = os.environ['bucket_incident']

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
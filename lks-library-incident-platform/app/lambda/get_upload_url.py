import json
import os
import uuid

import boto3
from botocore.config import Config

REGION = os.environ.get("AWS_REGION", "ap-southeast-1")

# Regional endpoint + virtual addressing => the URL host is
# <bucket>.s3.<region>.amazonaws.com, which a browser can call without a redirect.
s3 = boto3.client(
    "s3",
    region_name=REGION,
    endpoint_url=f"https://s3.{REGION}.amazonaws.com",
    config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}),
)

BUCKET = os.environ["BUCKET"]


def lambda_handler(event, context):
    key = f"incoming/{uuid.uuid4()}.json"
    url = s3.generate_presigned_url(
        ClientMethod="put_object",
        Params={"Bucket": BUCKET, "Key": key, "ContentType": "application/json"},
        ExpiresIn=300,
    )
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"upload_url": url, "key": key}),
    }

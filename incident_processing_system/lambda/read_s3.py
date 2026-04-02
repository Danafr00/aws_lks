import boto3
import json

s3 = boto3.client('s3')

def lambda_handler(event, context):

    bucket = event['detail']['bucket']['name']
    key = event['detail']['object']['key']

    response = s3.get_object(Bucket=bucket, Key=key)
    data = json.loads(response['Body'].read())

    return data
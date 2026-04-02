import boto3

dynamodb = boto3.resource('dynamodb')
table = dynamodb.Table('incident-table')

def lambda_handler(event, context):

    table.put_item(Item=event)

    return {"status": "saved"}
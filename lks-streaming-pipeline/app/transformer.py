import base64
import json
import os
import boto3
from datetime import datetime, timezone

dynamodb = boto3.resource('dynamodb', region_name=os.environ.get('AWS_REGION', 'us-east-1'))
firehose = boto3.client('firehose', region_name=os.environ.get('AWS_REGION', 'us-east-1'))

TABLE_NAME = os.environ['DYNAMODB_TABLE']
FIREHOSE_STREAM = os.environ['FIREHOSE_STREAM']

table = dynamodb.Table(TABLE_NAME)


def handler(event, context):
    batch_failures = []
    records = event.get('Records', [])

    for record in records:
        seq = record['kinesis']['sequenceNumber']
        try:
            payload = base64.b64decode(record['kinesis']['data']).decode('utf-8')
            order = json.loads(payload)

            order['category'] = order.get('category', '').lower().replace(' & ', '_').replace(' ', '_')
            order['processed_at'] = datetime.now(timezone.utc).isoformat()

            table.put_item(Item=order)

            firehose.put_record(
                DeliveryStreamName=FIREHOSE_STREAM,
                Record={'Data': (json.dumps(order) + '\n').encode('utf-8')}
            )

        except Exception as e:
            print(f"ERROR seq={seq}: {e}")
            batch_failures.append({'itemIdentifier': seq})

    return {'batchItemFailures': batch_failures}

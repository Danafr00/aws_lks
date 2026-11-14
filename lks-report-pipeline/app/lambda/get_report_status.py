import json
import os

import boto3

table = boto3.resource("dynamodb").Table(os.environ["STATUS_TABLE"])


def number(value):
    # DynamoDB returns numbers as Decimal, which json.dumps cannot write
    return int(value) if value % 1 == 0 else float(value)


def lambda_handler(event, context):
    report_id = (event.get("pathParameters") or {}).get("id", "")
    item = table.get_item(Key={"report_id": report_id}).get("Item")
    if not item:
        return {"statusCode": 404, "headers": {"Content-Type": "application/json"},
                "body": json.dumps({"message": "report not found"})}
    return {"statusCode": 200, "headers": {"Content-Type": "application/json"},
            "body": json.dumps(item, default=number)}

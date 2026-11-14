import json
import os

import boto3
from boto3.dynamodb.conditions import Key

table = boto3.resource("dynamodb").Table(os.environ["INCIDENTS_TABLE"])
SEVERITIES = {"LOW", "MEDIUM", "HIGH", "CRITICAL"}


def lambda_handler(event, context):
    severity = ((event.get("queryStringParameters") or {}).get("severity") or "").upper()

    if severity:
        if severity not in SEVERITIES:
            return {"statusCode": 400, "body": json.dumps({"message": "invalid severity"})}
        # newest first, served by the severity-index GSI (no table scan)
        result = table.query(
            IndexName="severity-index",
            KeyConditionExpression=Key("severity").eq(severity),
            ScanIndexForward=False,
            Limit=50,
        )
        items = result["Items"]
    else:
        items = sorted(table.scan(Limit=200)["Items"], key=lambda i: i["received_at"], reverse=True)[:50]

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(items, default=int),  # DynamoDB numbers arrive as Decimal
    }

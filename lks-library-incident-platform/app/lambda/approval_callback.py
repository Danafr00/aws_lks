import json
import os
import time

import boto3
from boto3.dynamodb.conditions import Attr
from botocore.exceptions import ClientError

sfn = boto3.client("stepfunctions")
table = boto3.resource("dynamodb").Table(os.environ["APPROVALS_TABLE"])


def html(status, title, message):
    page = f"<html><body style='font-family:sans-serif;max-width:480px;margin:60px auto'><h2>{title}</h2><p>{message}</p></body></html>"
    return {"statusCode": status, "headers": {"Content-Type": "text/html"}, "body": page}


def js(status, body):
    return {"statusCode": status, "headers": {"Content-Type": "application/json"}, "body": json.dumps(body)}


def decide(approval_id, decision):
    """Returns (http_status, message)."""
    if decision not in ("APPROVE", "REJECT"):
        return 400, "decision must be APPROVE or REJECT"

    item = table.get_item(Key={"approval_id": approval_id}).get("Item")
    if not item:
        return 404, "approval not found"

    outcome = "APPROVED" if decision == "APPROVE" else "REJECTED"
    try:  # the conditional update makes a double click harmless
        table.update_item(
            Key={"approval_id": approval_id},
            UpdateExpression="SET #s = :new, decided_at = :t",
            ConditionExpression="#s = :pending",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":new": outcome, ":pending": "PENDING", ":t": int(time.time())},
        )
    except ClientError as err:
        if err.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return 409, f"already handled ({item['status']})"
        raise

    try:
        sfn.send_task_success(
            taskToken=item["task_token"],
            output=json.dumps({"decision": outcome}),
        )
    except (sfn.exceptions.TaskTimedOut, sfn.exceptions.TaskDoesNotExist, sfn.exceptions.InvalidToken):
        table.update_item(
            Key={"approval_id": approval_id},
            UpdateExpression="SET #s = :s",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":s": "EXPIRED"},
        )
        return 410, "this approval has expired and was escalated automatically"
    return 200, f"incident {item['incident_id']} {outcome.lower()}"


def lambda_handler(event, context):
    method = event["requestContext"]["http"]["method"]
    path = event["rawPath"]
    params = event.get("queryStringParameters") or {}

    # 1) link inside the e-mail
    if method == "GET" and path == "/approval":
        status, message = decide(params.get("id", ""), params.get("decision", "").upper())
        return html(status, "Incident approval", message)

    # 2) button on the dashboard
    if method == "POST" and path == "/approval":
        try:
            body = json.loads(event.get("body") or "{}")
        except ValueError:
            return js(400, {"message": "invalid JSON"})
        status, message = decide(str(body.get("id", "")), str(body.get("decision", "")).upper())
        return js(status, {"message": message})

    # 3) list for the dashboard
    if method == "GET" and path == "/approvals":
        now = int(time.time())
        items = table.scan(FilterExpression=Attr("status").eq("PENDING") & Attr("expires_at").gt(now))["Items"]
        pending = [
            {k: v for k, v in item.items() if k != "task_token"}  # never expose the token
            for item in sorted(items, key=lambda i: i["created_at"], reverse=True)
        ]
        return js(200, json.loads(json.dumps(pending, default=int)))

    return js(404, {"message": "not found"})

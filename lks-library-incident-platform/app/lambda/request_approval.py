import os
import time
import uuid

import boto3

table = boto3.resource("dynamodb").Table(os.environ["APPROVALS_TABLE"])
sns = boto3.client("sns")

TOPIC_ARN = os.environ["TOPIC_ARN"]
API_BASE_URL = os.environ["API_BASE_URL"].rstrip("/")
WAIT_SECONDS = 900  # same value as TimeoutSeconds in the state machine


def lambda_handler(event, context):
    """Called by Step Functions with .waitForTaskToken: the workflow pauses
    until approval_callback.py calls SendTaskSuccess with this task token."""
    incident = event["incident"]
    now = int(time.time())
    approval_id = uuid.uuid4().hex  # unguessable id; the real task token never leaves the backend

    table.put_item(
        Item={
            "approval_id": approval_id,
            "task_token": event["token"],
            "incident_id": incident["incident_id"],
            "severity": incident["severity"],
            "room": incident["room"],
            "description": incident["description"],
            "status": "PENDING",
            "created_at": now,
            "expires_at": now + WAIT_SECONDS,
            "ttl": now + 86400,
        }
    )

    approve = f"{API_BASE_URL}/approval?id={approval_id}&decision=APPROVE"
    reject = f"{API_BASE_URL}/approval?id={approval_id}&decision=REJECT"
    sns.publish(
        TopicArn=TOPIC_ARN,
        Subject=f"[CRITICAL] Approval needed: {incident['incident_id']}"[:100],
        Message=(
            f"Critical incident {incident['incident_id']} in {incident['room']}\n"
            f"{incident['description']}\n\n"
            f"Approve: {approve}\n"
            f"Reject:  {reject}\n\n"
            f"No answer within {WAIT_SECONDS // 60} minutes escalates automatically."
        ),
    )
    return {"approval_id": approval_id}

import json
import boto3
import os

sns = boto3.client("sns")
SNS_TOPIC_ARN = os.environ["SNS_TOPIC"]


def handler(event, context):
    """
    Step 3 of Step Functions pipeline.
    Publishes a success or failure notification to SNS.
    """
    status = event.get("status", "unknown")

    if status == "processed":
        subject = f"[LKS] Report Processed: {event.get('filename')}"
        message = (
            f"Report successfully processed.\n\n"
            f"File:         {event.get('filename')}\n"
            f"Report ID:    {event.get('report_id')}\n"
            f"Record count: {event.get('record_count')}\n"
            f"Status:       {status}"
        )
    else:
        subject = "[LKS] Report Processing FAILED"
        message = (
            f"Report processing failed.\n\n"
            f"Error: {event.get('error', 'Unknown error')}\n"
            f"Event: {json.dumps(event, default=str)}"
        )

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=subject,
        Message=message,
    )

    return {
        "status": "notified",
        "notification_sent": True,
    }

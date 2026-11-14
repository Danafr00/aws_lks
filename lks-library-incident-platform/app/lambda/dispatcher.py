import hashlib
import json
import os
import time
from urllib.parse import unquote_plus

import boto3
from botocore.exceptions import ClientError

sfn = boto3.client("stepfunctions")
files_table = boto3.resource("dynamodb").Table(os.environ["FILES_TABLE"])
STATE_MACHINE_ARN = os.environ.get("STATE_MACHINE_ARN", "")


def process_file(bucket, key):
    """Claim the file once, then start one Step Functions execution for it."""
    status = "PROCESSING" if STATE_MACHINE_ARN else "RECEIVED"
    try:
        files_table.put_item(
            Item={"file_key": key, "status": status, "received_epoch": int(time.time())},
            ConditionExpression="attribute_not_exists(file_key)",
        )
    except ClientError as err:
        if err.response["Error"]["Code"] == "ConditionalCheckFailedException":
            print(f"duplicate event for {key}, skipped")
            return
        raise

    if not STATE_MACHINE_ARN:
        print(f"claimed {key} (no state machine configured yet)")
        return

    execution_name = hashlib.sha256(f"{bucket}/{key}".encode()).hexdigest()[:40]
    try:
        sfn.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            name=execution_name,
            input=json.dumps({"bucket": bucket, "file_key": key}),
        )
        print(f"started execution {execution_name} for {key}")
    except sfn.exceptions.ExecutionAlreadyExists:
        print(f"execution {execution_name} already exists")
    except Exception:
        # release the claim so the SQS retry can try again
        files_table.delete_item(Key={"file_key": key})
        raise


def lambda_handler(event, context):
    failures = []
    for record in event["Records"]:
        try:
            body = json.loads(record["body"])
            # S3 sends an "s3:TestEvent" message when the notification is created
            if "Records" not in body:
                print("ignoring non-object message")
                continue
            for s3_record in body["Records"]:
                bucket = s3_record["s3"]["bucket"]["name"]
                key = unquote_plus(s3_record["s3"]["object"]["key"])
                process_file(bucket, key)
        except Exception as err:  # report only this message as failed
            print(f"failed message {record['messageId']}: {err}")
            failures.append({"itemIdentifier": record["messageId"]})
    return {"batchItemFailures": failures}

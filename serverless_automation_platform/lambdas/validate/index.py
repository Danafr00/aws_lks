import json
import boto3
import os

s3 = boto3.client("s3")

REQUIRED_FIELDS = {"filename", "data"}


class ValidationError(Exception):
    pass


def handler(event, context):
    """
    Step 1 of Step Functions pipeline.
    Validates the report payload from EventBridge (S3 upload event).
    Passes enriched event to next state.
    """
    try:
        bucket = event["detail"]["bucket"]["name"]
        key = event["detail"]["object"]["key"]

        # Download and parse the uploaded file
        response = s3.get_object(Bucket=bucket, Key=key)
        content = response["Body"].read().decode("utf-8")
        report = json.loads(content)

        # Validate required fields
        missing = REQUIRED_FIELDS - report.keys()
        if missing:
            raise ValidationError(f"Missing required fields: {missing}")

        if not isinstance(report.get("data"), list) or len(report["data"]) == 0:
            raise ValidationError("Field 'data' must be a non-empty list")

        return {
            "status": "valid",
            "bucket": bucket,
            "key": key,
            "report": report,
        }

    except ValidationError as e:
        raise ValidationError(str(e))

    except Exception as e:
        raise Exception(f"Unexpected error during validation: {str(e)}")

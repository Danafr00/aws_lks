import json

import boto3

s3 = boto3.client("s3")

MAX_BYTES = 1024 * 1024  # 1 MB


def check(report):
    """Return an error text, or '' when the report is valid."""
    if not isinstance(report, dict):
        return "the report must be a JSON object"
    missing = [field for field in ("filename", "data") if field not in report]
    if missing:
        return f"missing fields: {', '.join(missing)}"
    rows = report["data"]
    if not isinstance(rows, list) or not rows:
        return "'data' must be a non-empty list"
    for index, row in enumerate(rows):
        if not isinstance(row, dict) or not str(row.get("item", "")).strip():
            return f"row {index}: 'item' is required"
        qty, price = row.get("qty"), row.get("price")
        if isinstance(qty, bool) or not isinstance(qty, int) or qty <= 0:
            return f"row {index}: 'qty' must be a whole number above 0"
        if isinstance(price, bool) or not isinstance(price, (int, float)) or price < 0:
            return f"row {index}: 'price' must be a number of 0 or more"
    return ""


def lambda_handler(event, context):
    # event = {"bucket": ..., "key": ..., "report_id": ...} (built by the Init state)
    obj = s3.get_object(Bucket=event["bucket"], Key=event["key"])
    if obj["ContentLength"] > MAX_BYTES:
        return {"valid": False, "reason": "file is larger than 1 MB", "filename": "", "record_count": 0}
    try:
        report = json.loads(obj["Body"].read())
    except ValueError:
        return {"valid": False, "reason": "file is not valid JSON", "filename": "", "record_count": 0}

    reason = check(report)
    if reason:
        return {"valid": False, "reason": reason, "filename": "", "record_count": 0}
    # always return the same keys: the state machine reads them with fixed paths
    return {"valid": True, "reason": "", "filename": str(report["filename"])[:200], "record_count": len(report["data"])}

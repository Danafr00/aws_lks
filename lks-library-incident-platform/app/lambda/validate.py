import datetime
import json

import boto3

s3 = boto3.client("s3")

SEVERITIES = {"LOW", "MEDIUM", "HIGH", "CRITICAL"}
MAX_INCIDENTS = 100  # keeps the Step Functions payload well below 256 KB


def normalize(raw, received_at):
    """Return (incident, None) when valid, or (None, reason) when not."""
    if not isinstance(raw, dict):
        return None, "incident is not an object"

    incident_id = str(raw.get("incident_id", "")).strip()
    severity = str(raw.get("severity", "")).strip().upper()
    description = str(raw.get("description", "")).strip()

    if not incident_id:
        return None, "incident_id is missing"
    if severity not in SEVERITIES:
        return None, f"invalid severity '{severity}'"
    if not description:
        return None, "description is missing"

    visitor_id = raw.get("visitor_id")
    try:
        visitor_id = int(visitor_id) if visitor_id not in (None, "") else None
    except (TypeError, ValueError):
        return None, "visitor_id must be a number"

    return {
        "incident_id": incident_id[:100],
        "type": (str(raw.get("type", "")).strip().lower() or "other")[:50],
        "severity": severity,
        "room": (str(raw.get("room", "")).strip() or "unspecified")[:100],
        "description": description[:1000],
        "visitor_id": visitor_id,
        "received_at": received_at,
        "report_date": received_at[:10],
    }, None


def lambda_handler(event, context):
    obj = s3.get_object(Bucket=event["bucket"], Key=event["file_key"])
    data = json.loads(obj["Body"].read())  # invalid JSON raises -> Catch in the state machine

    items = data.get("incidents") if isinstance(data, dict) else data
    if not isinstance(items, list):
        raise ValueError("file must contain an 'incidents' array")
    if len(items) > MAX_INCIDENTS:
        raise ValueError(f"too many incidents in one file (max {MAX_INCIDENTS})")

    received_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    valid, invalid = [], []
    for index, raw in enumerate(items):
        incident, reason = normalize(raw, received_at)
        if incident:
            valid.append(incident)
        else:
            invalid.append({"index": index, "reason": reason})

    return {
        "bucket": event["bucket"],
        "file_key": event["file_key"],
        "valid": valid,
        "invalid": invalid,
    }

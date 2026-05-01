import json
import math
import os
import boto3
import csv
import io

s3 = boto3.client("s3")

FEATURES_BUCKET = os.environ["FEATURES_BUCKET"]

MERCHANT_ENCODING = {
    "grocery": 0,
    "electronics": 1,
    "restaurant": 2,
    "gas": 3,
    "travel": 4,
    "online": 5,
}


def engineer_features(row: dict) -> dict:
    merchant_cat = row.get("merchant_category", "online").lower()
    return {
        "amount_log": math.log1p(float(row["amount"])),
        "merchant_cat_encoded": MERCHANT_ENCODING.get(merchant_cat, 5),
        "hour_of_day": int(row["hour_of_day"]),
        "day_of_week": int(row["day_of_week"]),
        "account_age_days": int(row["user_account_age_days"]),
        "prev_fraud_count": int(row["previous_fraud_count"]),
        "distance_km_log": math.log1p(float(row["distance_from_home_km"])),
        "is_foreign": int(row["is_foreign_transaction"]),
        "tx_freq_24h": int(row["transaction_frequency_24h"]),
        "_transaction_id": row["transaction_id"],
    }


def process_csv(bucket: str, key: str) -> str:
    response = s3.get_object(Bucket=bucket, Key=key)
    raw_csv = response["Body"].read().decode("utf-8")

    reader = csv.DictReader(io.StringIO(raw_csv))
    rows = [engineer_features(r) for r in reader]

    output = io.StringIO()
    if rows:
        fieldnames = [k for k in rows[0].keys() if not k.startswith("_")]
        writer = csv.DictWriter(output, fieldnames=fieldnames)
        writer.writeheader()
        for r in rows:
            writer.writerow({k: v for k, v in r.items() if not k.startswith("_")})

    source_filename = key.split("/")[-1]
    dest_key = f"features/{source_filename}"
    s3.put_object(
        Bucket=FEATURES_BUCKET,
        Key=dest_key,
        Body=output.getvalue().encode("utf-8"),
        ContentType="text/csv",
    )
    return dest_key


def handler(event, context):
    processed = []
    failed = []

    for record in event.get("Records", []):
        body = json.loads(record["body"])

        # SQS message body is the S3 event notification
        for s3_record in body.get("Records", []):
            bucket = s3_record["s3"]["bucket"]["name"]
            key = s3_record["s3"]["object"]["key"]

            if not key.endswith(".csv"):
                continue

            try:
                dest_key = process_csv(bucket, key)
                processed.append({"source": key, "dest": dest_key})
                print(f"Processed: s3://{bucket}/{key} → s3://{FEATURES_BUCKET}/{dest_key}")
            except Exception as e:
                print(f"Failed to process {key}: {e}")
                failed.append({"key": key, "error": str(e)})
                raise  # re-raise so SQS retries the message

    return {"processed": processed, "failed": failed}

import json
import os

import boto3
import pymysql

s3 = boto3.client("s3")


def lambda_handler(event, context):
    # event = {"bucket": ..., "key": ..., "report_id": ...}; the file was already validated
    report = json.loads(s3.get_object(Bucket=event["bucket"], Key=event["key"])["Body"].read())
    rows = report["data"]
    record_count = len(rows)
    total_amount = round(sum(row["qty"] * row["price"] for row in rows), 2)

    conn = pymysql.connect(
        host=os.environ["DB_HOST"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASS"],
        database=os.environ["DB_NAME"],
        port=3306,
        connect_timeout=5,
    )
    try:
        with conn.cursor() as cursor:
            # report_id is UNIQUE: a retry or a second run updates the row instead of adding a duplicate
            cursor.execute(
                """INSERT INTO reports (report_id, filename, record_count, total_amount)
                   VALUES (%s, %s, %s, %s)
                   ON DUPLICATE KEY UPDATE filename = VALUES(filename),
                                           record_count = VALUES(record_count),
                                           total_amount = VALUES(total_amount)""",
                (event["report_id"], str(report["filename"])[:200], record_count, total_amount),
            )
        conn.commit()
    finally:
        conn.close()

    return {"report_id": event["report_id"], "record_count": record_count, "total_amount": total_amount}

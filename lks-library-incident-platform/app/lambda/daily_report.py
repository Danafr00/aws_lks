import datetime
import json
import os
from collections import Counter

import boto3
import pymysql
from boto3.dynamodb.conditions import Key

dynamodb = boto3.resource("dynamodb")
incidents = dynamodb.Table(os.environ["INCIDENTS_TABLE"])
s3 = boto3.client("s3")
sns = boto3.client("sns")


def connect():
    return pymysql.connect(
        host=os.environ["DB_HOST"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASS"],
        database=os.environ["DB_NAME"],
        port=3306,
        connect_timeout=5,
        cursorclass=pymysql.cursors.DictCursor,
    )


def incidents_for(report_date):
    items, kwargs = [], {"IndexName": "report-date-index", "KeyConditionExpression": Key("report_date").eq(report_date)}
    while True:
        page = incidents.query(**kwargs)
        items.extend(page["Items"])
        if "LastEvaluatedKey" not in page:
            return items
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def lambda_handler(event, context):
    # The schedule sends no date, so we report on yesterday (UTC).
    # For a manual run pass {"date": "YYYY-MM-DD"}.
    event = event if isinstance(event, dict) else {}
    report_date = event.get("date") or (datetime.datetime.now(datetime.timezone.utc).date() - datetime.timedelta(days=1)).isoformat()

    conn = connect()
    try:
        with conn.cursor() as cursor:
            cursor.execute("SELECT COUNT(*) AS total FROM visitors WHERE DATE(visit_time) = %s", (report_date,))
            visitors = cursor.fetchone()["total"]

            by_severity = Counter(item["severity"] for item in incidents_for(report_date))
            total_incidents = sum(by_severity.values())
            critical = by_severity.get("CRITICAL", 0)

            cursor.execute(
                """INSERT INTO daily_summary (report_date, total_visitors, total_incidents, critical_incidents)
                   VALUES (%s, %s, %s, %s)
                   ON DUPLICATE KEY UPDATE total_visitors = VALUES(total_visitors),
                                           total_incidents = VALUES(total_incidents),
                                           critical_incidents = VALUES(critical_incidents)""",
                (report_date, visitors, total_incidents, critical),
            )
        conn.commit()
    finally:
        conn.close()

    report = {
        "date": report_date,
        "visitors": visitors,
        "incidents": total_incidents,
        "by_severity": dict(by_severity),
    }
    s3.put_object(
        Bucket=os.environ["REPORT_BUCKET"],
        Key=f"daily/{report_date}.json",
        Body=json.dumps(report, indent=2),
        ContentType="application/json",
    )
    sns.publish(
        TopicArn=os.environ["TOPIC_ARN"],
        Subject=f"Library daily report {report_date}"[:100],
        Message=json.dumps(report, indent=2),
    )
    return report

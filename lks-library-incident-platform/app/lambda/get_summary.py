import json
import os

import pymysql


def lambda_handler(event, context):
    conn = pymysql.connect(
        host=os.environ["DB_HOST"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASS"],
        database=os.environ["DB_NAME"],
        port=3306,
        connect_timeout=5,
        cursorclass=pymysql.cursors.DictCursor,
    )
    try:
        with conn.cursor() as cursor:
            cursor.execute("SELECT COUNT(*) AS total FROM visitors WHERE DATE(visit_time) = UTC_DATE()")
            today = cursor.fetchone()["total"]
            cursor.execute(
                "SELECT report_date, total_visitors, total_incidents, critical_incidents "
                "FROM daily_summary ORDER BY report_date DESC LIMIT 7"
            )
            days = cursor.fetchall()
    finally:
        conn.close()

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"visitors_today": today, "last_days": days}, default=str),
    }

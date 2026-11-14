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
            cursor.execute(
                "SELECT report_id, filename, record_count, total_amount, created_at "
                "FROM reports ORDER BY id DESC LIMIT 50"
            )
            rows = cursor.fetchall()
    finally:
        conn.close()

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(rows, default=str),  # Decimal and datetime are not JSON types: turn them into text
    }

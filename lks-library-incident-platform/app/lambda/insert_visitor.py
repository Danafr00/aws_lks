import json
import os

import pymysql


def get_connection():
    return pymysql.connect(
        host=os.environ["DB_HOST"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASS"],
        database=os.environ["DB_NAME"],
        port=3306,
        connect_timeout=5,
        cursorclass=pymysql.cursors.DictCursor,
    )


def response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def lambda_handler(event, context):
    # HTTP API (payload v2) delivers the request body as a JSON *string*.
    try:
        body = json.loads(event.get("body") or "{}")
        name = str(body["name"]).strip()[:100]
        student_class = str(body["class"]).strip()[:20]
        purpose = str(body["purpose"]).strip()[:255]
    except (ValueError, KeyError, TypeError):
        return response(400, {"message": "name, class and purpose are required"})

    if not (name and student_class and purpose):
        return response(400, {"message": "name, class and purpose must not be empty"})

    conn = get_connection()
    try:
        with conn.cursor() as cursor:
            cursor.execute(
                "INSERT INTO visitors (name, class, purpose) VALUES (%s, %s, %s)",
                (name, student_class, purpose),
            )
            visitor_id = cursor.lastrowid
        conn.commit()
    finally:
        conn.close()

    return response(200, {"message": "Visitor recorded", "visitor_id": visitor_id})

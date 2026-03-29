import json
import os
import pymysql

DB_HOST = os.environ['DB_HOST']
DB_NAME = os.environ['DB_NAME']
DB_USER = os.environ['DB_USER']
DB_PASS = os.environ['DB_PASS']

def lambda_handler(event, context):

    body = json.loads(event['body'])

    name = body['name']
    student_class = body['class']
    purpose = body['purpose']

    conn = pymysql.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASS,
        database=DB_NAME,
        port=3306,
        connect_timeout=5,
        cursorclass=pymysql.cursors.DictCursor
    )

    try:
        with conn.cursor() as cursor:

            query = """
                INSERT INTO visitors (name, class, purpose)
                VALUES (%s, %s, %s)
            """

            cursor.execute(query, (name, student_class, purpose))

        conn.commit()

    finally:
        conn.close()

    return {
        "statusCode": 200,
        "headers": {
            "Access-Control-Allow-Origin": "*"
        },
        "body": json.dumps({
            "message": "Visitor recorded"
        })
    }
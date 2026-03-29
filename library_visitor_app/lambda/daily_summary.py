import pymysql
import os
from datetime import date

DB_HOST = os.environ['DB_HOST']
DB_NAME = os.environ['DB_NAME']
DB_USER = os.environ['DB_USER']
DB_PASS = os.environ['DB_PASS']

def lambda_handler(event, context):

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

            query_count = """
                SELECT COUNT(*) AS total
                FROM visitors
                WHERE DATE(visit_time) = CURRENT_DATE
            """

            cursor.execute(query_count)
            result = cursor.fetchone()
            total = result['total']

            insert_summary = """
                INSERT INTO daily_summary (date, total_visitors)
                VALUES (%s, %s)
            """

            cursor.execute(insert_summary, (date.today(), total))

        conn.commit()

    finally:
        conn.close()

    return {
        "statusCode": 200,
        "body": "Daily summary saved"
    }
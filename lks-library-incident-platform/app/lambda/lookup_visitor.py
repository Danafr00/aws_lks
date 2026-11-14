import os

import pymysql

UNKNOWN = {"id": 0, "name": "unknown", "class": ""}


def lambda_handler(event, context):
    # event is one incident (see validate.py)
    visitor_id = event.get("visitor_id")
    if visitor_id is None:
        return {"visitor": UNKNOWN}

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
            cursor.execute("SELECT id, name, class FROM visitors WHERE id = %s", (visitor_id,))
            row = cursor.fetchone()
    finally:
        conn.close()

    return {"visitor": row or UNKNOWN}

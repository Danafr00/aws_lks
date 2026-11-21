import json
import os

import boto3
import pymysql

secrets = boto3.client("secretsmanager")
_conn = None          # kept between invocations while the Lambda environment stays warm
_table_ready = False


def get_connection():
    """Open (or reuse) the database connection.

    The host and database name come from environment variables; the user name and password are
    read from Secrets Manager, so no password is stored in the function configuration.
    """
    global _conn
    if _conn and _conn.open:
        _conn.ping(reconnect=True)
        return _conn
    secret = json.loads(secrets.get_secret_value(SecretId=os.environ["SECRET_ARN"])["SecretString"])
    _conn = pymysql.connect(
        host=os.environ["DB_HOST"],
        user=secret["username"],
        password=secret["password"],
        database=os.environ["DB_NAME"],
        port=3306,
        connect_timeout=5,
        cursorclass=pymysql.cursors.DictCursor,
    )
    return _conn


def ensure_table(conn):
    global _table_ready
    if _table_ready:
        return
    with conn.cursor() as cur:
        cur.execute(
            """CREATE TABLE IF NOT EXISTS items (
                   id INT AUTO_INCREMENT PRIMARY KEY,
                   name VARCHAR(255) NOT NULL,
                   value TEXT,
                   created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)"""
        )
    conn.commit()
    _table_ready = True


def resp(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=str),  # datetime values are not JSON types: write them as text
    }


def lambda_handler(event, context):
    # HTTP API (payload format 2.0): the method and the path live under requestContext / rawPath
    method = event["requestContext"]["http"]["method"]
    path = event["rawPath"]
    try:
        body = json.loads(event.get("body") or "{}")
    except ValueError:
        return resp(400, {"error": "body must be valid JSON"})

    conn = get_connection()
    ensure_table(conn)

    if method == "GET" and path == "/items":
        with conn.cursor() as cur:
            cur.execute("SELECT id, name, value, created_at FROM items ORDER BY id")
            return resp(200, cur.fetchall())

    if method == "POST" and path == "/items":
        name = str(body.get("name", "")).strip()[:255]
        if not name:
            return resp(400, {"error": "name is required"})
        with conn.cursor() as cur:
            cur.execute("INSERT INTO items (name, value) VALUES (%s, %s)", (name, body.get("value")))
            item_id = cur.lastrowid
        conn.commit()
        return resp(201, {"id": item_id})

    if method == "DELETE" and path.startswith("/items/"):
        item_id = (event.get("pathParameters") or {}).get("id", "")
        if not item_id.isdigit():
            return resp(400, {"error": "id must be a number"})
        with conn.cursor() as cur:
            cur.execute("DELETE FROM items WHERE id = %s", (item_id,))
            deleted = cur.rowcount
        conn.commit()
        return resp(200 if deleted else 404, {"deleted": int(item_id)} if deleted else {"error": "item not found"})

    return resp(404, {"error": "route not found"})

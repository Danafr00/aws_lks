import json
import boto3
import pymysql
import os

secrets_client = boto3.client("secretsmanager")
_conn = None


def get_connection():
    global _conn
    if _conn and _conn.open:
        return _conn

    secret = json.loads(
        secrets_client.get_secret_value(SecretId=os.environ["SECRET_ARN"])["SecretString"]
    )
    _conn = pymysql.connect(
        host=secret["host"],
        user=secret["username"],
        password=secret["password"],
        database=secret["dbname"],
        port=int(secret["port"]),
        connect_timeout=5,
        cursorclass=pymysql.cursors.DictCursor,
    )
    return _conn


def handler(event, context):
    """
    Step 2 of Step Functions pipeline — also handles API Gateway requests.
    Saves report records to RDS and returns a summary.
    """
    # Called from Step Functions
    if "report" in event:
        return process_from_pipeline(event)

    # Called from API Gateway
    method = event.get("httpMethod", "GET")
    path = event.get("path", "/")

    if method == "GET" and path == "/reports":
        return get_reports()

    if method == "POST" and path == "/reports":
        body = json.loads(event.get("body") or "{}")
        return save_report(body)

    if method == "GET" and "/reports/" in path:
        report_id = event.get("pathParameters", {}).get("id")
        return get_report(report_id)

    return resp(404, {"error": "route not found"})


# ── Pipeline path ──────────────────────────────────────────────────────────────

def process_from_pipeline(event):
    report = event["report"]
    conn = get_connection()
    bootstrap(conn)

    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO reports (filename, record_count, status) VALUES (%s, %s, %s)",
            (report["filename"], len(report["data"]), "processed"),
        )
        conn.commit()
        report_id = cur.lastrowid

    return {
        "status": "processed",
        "report_id": report_id,
        "filename": report["filename"],
        "record_count": len(report["data"]),
    }


# ── API Gateway paths ──────────────────────────────────────────────────────────

def get_reports():
    conn = get_connection()
    bootstrap(conn)
    with conn.cursor() as cur:
        cur.execute("SELECT * FROM reports ORDER BY created_at DESC LIMIT 50")
        rows = cur.fetchall()
    return resp(200, rows)


def save_report(body):
    conn = get_connection()
    bootstrap(conn)
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO reports (filename, record_count, status) VALUES (%s, %s, %s)",
            (body.get("filename"), body.get("record_count", 0), "manual"),
        )
        conn.commit()
        report_id = cur.lastrowid
    return resp(201, {"id": report_id})


def get_report(report_id):
    conn = get_connection()
    bootstrap(conn)
    with conn.cursor() as cur:
        cur.execute("SELECT * FROM reports WHERE id = %s", (report_id,))
        row = cur.fetchone()
    if not row:
        return resp(404, {"error": "report not found"})
    return resp(200, row)


# ── Helpers ────────────────────────────────────────────────────────────────────

def bootstrap(conn):
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS reports (
                id           INT AUTO_INCREMENT PRIMARY KEY,
                filename     VARCHAR(255) NOT NULL,
                record_count INT DEFAULT 0,
                status       VARCHAR(50),
                created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )
        """)
        conn.commit()


def resp(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=str),
    }

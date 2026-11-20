#!/bin/bash
# Paste this whole script into EC2 -> Advanced details -> User data when you launch the instance.
# It installs the app from ec2/app.py and starts it on port 8080. No SSH needed.

# ---- edit these 4 values (do not use a single quote ' in the password) ----
DB_HOST='your-rds-endpoint'
DB_NAME='your-database-name'
DB_USER='admin'
DB_PASS='your-password'
# ----------------------------------------------------------------------------

dnf install -y python3-pip
pip3 install flask pymysql cryptography gunicorn

mkdir -p /opt/lib-visitor
cat > /opt/lib-visitor/app.py <<'PYEOF'
"""Flow B: the same "insert visitor" logic as lambda/insert_visitor.py, but as a small web app on EC2."""
import json
import os

import pymysql
from flask import Flask, jsonify, request

app = Flask(__name__)

# Connection settings are written to this file by user-data.sh (keeps the password out of the source code)
with open(os.environ.get("LIB_CONFIG", "/etc/lib-visitor.json")) as f:
    CFG = json.load(f)


def connect():
    return pymysql.connect(
        host=CFG["DB_HOST"],
        user=CFG["DB_USER"],
        password=CFG["DB_PASS"],
        database=CFG["DB_NAME"],
        port=3306,
        connect_timeout=5,
    )


@app.get("/health")
def health():
    return jsonify(status="ok")


@app.post("/visitor")
def insert_visitor():
    body = request.get_json(silent=True) or {}
    try:
        name = str(body["name"]).strip()[:100]
        student_class = str(body["class"]).strip()[:20]
        purpose = str(body["purpose"]).strip()[:255]
    except KeyError:
        return jsonify(message="name, class and purpose are required"), 400
    if not (name and student_class and purpose):
        return jsonify(message="name, class and purpose must not be empty"), 400

    conn = connect()
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
    return jsonify(message="Visitor recorded", visitor_id=visitor_id)
PYEOF

# the settings go through environment variables so special characters in the password stay intact
DB_HOST="$DB_HOST" DB_NAME="$DB_NAME" DB_USER="$DB_USER" DB_PASS="$DB_PASS" python3 -c '
import json, os
json.dump({k: os.environ[k] for k in ("DB_HOST", "DB_NAME", "DB_USER", "DB_PASS")}, open("/etc/lib-visitor.json", "w"))'
chmod 600 /etc/lib-visitor.json

cat > /etc/systemd/system/lib-visitor.service <<'UNIT'
[Unit]
Description=Library visitor API
After=network-online.target

[Service]
WorkingDirectory=/opt/lib-visitor
ExecStart=/usr/local/bin/gunicorn -w 2 -b 0.0.0.0:8080 app:app
Restart=always

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lib-visitor

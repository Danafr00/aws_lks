"""
LKS Admin Dashboard — Flask app for EC2 instances behind ALB.
Runs on port 8080. Reads report data from RDS MySQL.

Start:
    python3 app.py

Environment variables (set via EC2 user-data or Systems Manager Parameter Store):
    DB_HOST      RDS endpoint
    DB_PORT      3306 (default)
    DB_USER      admin (default)
    DB_PASSWORD  your RDS password
    DB_NAME      lksdb (default)
"""

import os
import json
import pymysql
from flask import Flask, jsonify, render_template_string, abort

app = Flask(__name__)

# ---------------------------------------------------------------------------
# DB config from environment
# ---------------------------------------------------------------------------
DB_CONFIG = {
    "host":   os.environ.get("DB_HOST", "localhost"),
    "port":   int(os.environ.get("DB_PORT", 3306)),
    "user":   os.environ.get("DB_USER", "admin"),
    "password": os.environ.get("DB_PASSWORD", ""),
    "db":     os.environ.get("DB_NAME", "lksdb"),
    "charset": "utf8mb4",
    "cursorclass": pymysql.cursors.DictCursor,
}


def get_connection():
    return pymysql.connect(**DB_CONFIG)


# ---------------------------------------------------------------------------
# HTML template (inline — no templates folder needed)
# ---------------------------------------------------------------------------
DASHBOARD_HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>LKS Admin Dashboard</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
           background: #1a202c; color: #e2e8f0; }
    header { background: #2d3748; padding: 1rem 2rem; border-bottom: 1px solid #4a5568;
             display: flex; align-items: center; justify-content: space-between; }
    header h1 { font-size: 1.1rem; color: #90cdf4; }
    header span { font-size: 0.8rem; color: #718096; }
    main { max-width: 1000px; margin: 2rem auto; padding: 0 1rem; }

    .stats { display: grid; grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
             gap: 1rem; margin-bottom: 1.5rem; }
    .stat { background: #2d3748; border-radius: 8px; padding: 1.25rem; text-align: center; }
    .stat .val { font-size: 2rem; font-weight: 700; color: #63b3ed; }
    .stat .lbl { font-size: 0.8rem; color: #a0aec0; margin-top: 0.25rem; }

    .card { background: #2d3748; border-radius: 8px; padding: 1.25rem; margin-bottom: 1.5rem; }
    .card h2 { font-size: 0.95rem; color: #90cdf4; margin-bottom: 1rem; }
    table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
    th { text-align: left; padding: 0.5rem 0.75rem; color: #a0aec0;
         border-bottom: 1px solid #4a5568; font-weight: 600; }
    td { padding: 0.5rem 0.75rem; border-bottom: 1px solid #3d4a5a; vertical-align: middle; }
    tr:last-child td { border-bottom: none; }
    tr:hover td { background: #374151; }

    .badge { display: inline-block; padding: 0.15rem 0.5rem; border-radius: 9999px;
             font-size: 0.75rem; font-weight: 600; }
    .badge-success { background: #276749; color: #c6f6d5; }
    .badge-error   { background: #9b2c2c; color: #fed7d7; }
    .badge-info    { background: #2c5282; color: #bee3f8; }
    .badge-warning { background: #7b341e; color: #feebc8; }

    .refresh { float: right; font-size: 0.8rem; background: #4a5568; color: #e2e8f0;
               border: none; padding: 0.3rem 0.75rem; border-radius: 4px; cursor: pointer; }
    .refresh:hover { background: #718096; }
    .empty { text-align: center; padding: 2rem; color: #718096; font-size: 0.875rem; }
  </style>
</head>
<body>
<header>
  <h1>LKS Admin Dashboard</h1>
  <span>EC2 Admin &mdash; {{ instance_id }}</span>
</header>
<main>

  <div class="stats">
    <div class="stat">
      <div class="val">{{ stats.total }}</div>
      <div class="lbl">Total Reports</div>
    </div>
    <div class="stat">
      <div class="val" style="color:#68d391">{{ stats.completed }}</div>
      <div class="lbl">Completed</div>
    </div>
    <div class="stat">
      <div class="val" style="color:#fc8181">{{ stats.failed }}</div>
      <div class="lbl">Failed</div>
    </div>
    <div class="stat">
      <div class="val">{{ stats.total_records }}</div>
      <div class="lbl">Total Records</div>
    </div>
  </div>

  <div class="card">
    <h2>
      Recent Reports
      <button class="refresh" onclick="location.reload()">&#8635; Refresh</button>
    </h2>
    {% if reports %}
    <table>
      <thead>
        <tr>
          <th>ID</th><th>Filename</th><th>Records</th>
          <th>Status</th><th>Created At</th>
        </tr>
      </thead>
      <tbody>
        {% for r in reports %}
        <tr>
          <td>{{ r.id }}</td>
          <td>{{ r.filename }}</td>
          <td>{{ r.record_count }}</td>
          <td>
            {% set s = (r.status or '')|lower %}
            {% if s in ('completed','success') %}
              <span class="badge badge-success">{{ r.status }}</span>
            {% elif s in ('failed','error') %}
              <span class="badge badge-error">{{ r.status }}</span>
            {% elif s == 'processing' %}
              <span class="badge badge-info">{{ r.status }}</span>
            {% else %}
              <span class="badge badge-warning">{{ r.status }}</span>
            {% endif %}
          </td>
          <td>{{ r.created_at }}</td>
        </tr>
        {% endfor %}
      </tbody>
    </table>
    {% else %}
    <div class="empty">No reports in the database yet.</div>
    {% endif %}
  </div>

</main>
</body>
</html>
"""


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/", methods=["GET"])
@app.route("/dashboard", methods=["GET"])
def dashboard():
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM reports ORDER BY id DESC LIMIT 100")
            reports = cur.fetchall()

            cur.execute("SELECT COUNT(*) AS total FROM reports")
            total = cur.fetchone()["total"]

            cur.execute("SELECT COUNT(*) AS cnt FROM reports WHERE status = 'completed'")
            completed = cur.fetchone()["cnt"]

            cur.execute("SELECT COUNT(*) AS cnt FROM reports WHERE status = 'failed'")
            failed = cur.fetchone()["cnt"]

            cur.execute("SELECT COALESCE(SUM(record_count), 0) AS s FROM reports")
            total_records = cur.fetchone()["s"]
    finally:
        conn.close()

    # Try to get EC2 instance ID from metadata (best-effort)
    try:
        import urllib.request
        req = urllib.request.Request(
            "http://169.254.169.254/latest/meta-data/instance-id",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "21600"},
        )
        instance_id = urllib.request.urlopen(req, timeout=1).read().decode()
    except Exception:
        instance_id = "local"

    return render_template_string(
        DASHBOARD_HTML,
        reports=reports,
        stats=dict(total=total, completed=completed, failed=failed, total_records=total_records),
        instance_id=instance_id,
    )


@app.route("/health", methods=["GET"])
def health():
    """ALB health check endpoint."""
    try:
        conn = get_connection()
        conn.ping()
        conn.close()
        return jsonify({"status": "ok", "db": "connected"}), 200
    except Exception as e:
        return jsonify({"status": "error", "detail": str(e)}), 500


@app.route("/api/reports", methods=["GET"])
def api_reports():
    """JSON endpoint — returns all reports."""
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM reports ORDER BY id DESC LIMIT 500")
            rows = cur.fetchall()
    finally:
        conn.close()
    for r in rows:
        if r.get("created_at"):
            r["created_at"] = str(r["created_at"])
    return jsonify(rows)


@app.route("/api/reports/<int:report_id>", methods=["GET"])
def api_report_detail(report_id):
    """JSON endpoint — returns single report."""
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute("SELECT * FROM reports WHERE id = %s", (report_id,))
            row = cur.fetchone()
    finally:
        conn.close()
    if not row:
        abort(404)
    if row.get("created_at"):
        row["created_at"] = str(row["created_at"])
    return jsonify(row)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080, debug=False)

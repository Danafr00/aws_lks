#!/bin/bash
set -euo pipefail

# ─── Variables injected by Terraform templatefile ─────────────────────────────
DB_SECRET_ARN="${db_secret_arn}"
REDIS_ENDPOINT="${redis_endpoint}"
S3_BUCKET="${s3_bucket_name}"
AWS_REGION="${aws_region}"
PROJECT_NAME="${project_name}"
APP_PORT=8080

# ─── System update & packages ─────────────────────────────────────────────────
yum update -y
yum install -y python3 python3-pip nginx jq awscli amazon-cloudwatch-agent

# ─── Fetch DB credentials from Secrets Manager ────────────────────────────────
SECRET_JSON=$(aws secretsmanager get-secret-value \
  --secret-id "$DB_SECRET_ARN" \
  --region "$AWS_REGION" \
  --query SecretString \
  --output text)

DB_HOST=$(echo "$SECRET_JSON"     | jq -r '.host')
DB_USER=$(echo "$SECRET_JSON"     | jq -r '.username')
DB_PASS=$(echo "$SECRET_JSON"     | jq -r '.password')
DB_NAME=$(echo "$SECRET_JSON"     | jq -r '.dbname')

# ─── App directory ────────────────────────────────────────────────────────────
mkdir -p /opt/app
cd /opt/app

# ─── Install Python dependencies ──────────────────────────────────────────────
pip3 install flask flask-sqlalchemy pymysql redis boto3 gunicorn

# ─── Write environment config ─────────────────────────────────────────────────
cat > /opt/app/.env << EOF
DATABASE_URL=mysql+pymysql://$DB_USER:$DB_PASS@$DB_HOST:3306/$DB_NAME
REDIS_URL=redis://$REDIS_ENDPOINT:6379/0
S3_BUCKET=$S3_BUCKET
AWS_REGION=$AWS_REGION
PORT=$APP_PORT
EOF

# ─── Write Flask application ───────────────────────────────────────────────────
cat > /opt/app/app.py << 'APPEOF'
import os, json, boto3, redis
from datetime import datetime
from flask import Flask, request, jsonify, g
from flask_sqlalchemy import SQLAlchemy
from dotenv import load_dotenv

load_dotenv()

app = Flask(__name__)
app.config["SQLALCHEMY_DATABASE_URI"] = os.environ["DATABASE_URL"]
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
db = SQLAlchemy(app)

# ── Models ────────────────────────────────────────────────────────────────────
class Item(db.Model):
    __tablename__ = "items"
    id          = db.Column(db.Integer,    primary_key=True)
    name        = db.Column(db.String(128), nullable=False)
    description = db.Column(db.Text,        nullable=True)
    created_at  = db.Column(db.DateTime,    default=datetime.utcnow)

    def to_dict(self):
        return {
            "id":          self.id,
            "name":        self.name,
            "description": self.description,
            "created_at":  self.created_at.isoformat(),
        }

# ── Redis helper ──────────────────────────────────────────────────────────────
def get_redis():
    if not hasattr(g, "redis"):
        g.redis = redis.from_url(os.environ.get("REDIS_URL", "redis://localhost:6379/0"))
    return g.redis

# ── Routes ────────────────────────────────────────────────────────────────────
@app.route("/health", methods=["GET"])
def health():
    checks = {"status": "healthy", "timestamp": datetime.utcnow().isoformat()}
    try:
        db.session.execute(db.text("SELECT 1"))
        checks["database"] = "ok"
    except Exception as e:
        checks["database"] = f"error: {e}"
        checks["status"] = "degraded"
    try:
        get_redis().ping()
        checks["cache"] = "ok"
    except Exception as e:
        checks["cache"] = f"error: {e}"
    return jsonify(checks), 200 if checks["status"] == "healthy" else 503

@app.route("/api/items", methods=["GET"])
def list_items():
    r = get_redis()
    cached = r.get("items:all")
    if cached:
        return jsonify(json.loads(cached)), 200
    items = Item.query.order_by(Item.created_at.desc()).limit(100).all()
    data = [i.to_dict() for i in items]
    r.setex("items:all", 60, json.dumps(data))   # cache 60s
    return jsonify(data), 200

@app.route("/api/items", methods=["POST"])
def create_item():
    body = request.get_json(silent=True) or {}
    name = (body.get("name") or "").strip()
    if not name:
        return jsonify({"error": "name is required"}), 400
    item = Item(name=name, description=body.get("description", ""))
    db.session.add(item)
    db.session.commit()
    get_redis().delete("items:all")
    return jsonify(item.to_dict()), 201

@app.route("/api/items/<int:item_id>", methods=["GET"])
def get_item(item_id):
    r = get_redis()
    cached = r.get(f"items:{item_id}")
    if cached:
        return jsonify(json.loads(cached)), 200
    item = db.session.get(Item, item_id)
    if not item:
        return jsonify({"error": "not found"}), 404
    r.setex(f"items:{item_id}", 120, json.dumps(item.to_dict()))
    return jsonify(item.to_dict()), 200

@app.route("/api/items/<int:item_id>", methods=["PUT"])
def update_item(item_id):
    item = db.session.get(Item, item_id)
    if not item:
        return jsonify({"error": "not found"}), 404
    body = request.get_json(silent=True) or {}
    item.name        = (body.get("name") or item.name).strip()
    item.description = body.get("description", item.description)
    db.session.commit()
    r = get_redis()
    r.delete("items:all")
    r.delete(f"items:{item_id}")
    return jsonify(item.to_dict()), 200

@app.route("/api/items/<int:item_id>", methods=["DELETE"])
def delete_item(item_id):
    item = db.session.get(Item, item_id)
    if not item:
        return jsonify({"error": "not found"}), 404
    db.session.delete(item)
    db.session.commit()
    r = get_redis()
    r.delete("items:all")
    r.delete(f"items:{item_id}")
    return jsonify({"message": "deleted"}), 200

@app.route("/api/upload-url", methods=["POST"])
def presigned_upload():
    """Return a pre-signed S3 PUT URL so clients upload directly to S3."""
    body     = request.get_json(silent=True) or {}
    filename = body.get("filename", "upload")
    s3       = boto3.client("s3", region_name=os.environ["AWS_REGION"])
    url      = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": os.environ["S3_BUCKET"], "Key": f"uploads/{filename}"},
        ExpiresIn=300,
    )
    return jsonify({"upload_url": url, "key": f"uploads/{filename}"}), 200

if __name__ == "__main__":
    with app.app_context():
        db.create_all()
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
APPEOF

# ─── Install python-dotenv (used by app) ──────────────────────────────────────
pip3 install python-dotenv

# ─── DB migration (create tables) ─────────────────────────────────────────────
cd /opt/app
python3 -c "
from app import app, db
with app.app_context():
    db.create_all()
    print('DB tables created')
" || echo "DB init deferred"

# ─── Systemd service ──────────────────────────────────────────────────────────
cat > /etc/systemd/system/lksapp.service << EOF
[Unit]
Description=LKS App (Gunicorn)
After=network.target

[Service]
User=nobody
Group=nobody
WorkingDirectory=/opt/app
EnvironmentFile=/opt/app/.env
ExecStart=/usr/local/bin/gunicorn --workers 4 --bind 0.0.0.0:$APP_PORT --access-logfile - --error-logfile - app:app
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable lksapp
systemctl start  lksapp

# ─── Nginx as reverse proxy ───────────────────────────────────────────────────
cat > /etc/nginx/conf.d/lksapp.conf << EOF
server {
    listen 8080;
    server_name _;

    location /health {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        access_log off;
    }

    location / {
        proxy_pass         http://127.0.0.1:$APP_PORT;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_read_timeout 60s;
    }
}
EOF

systemctl enable nginx
systemctl restart nginx

# ─── CloudWatch Agent config ──────────────────────────────────────────────────
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << EOF
{
  "agent": { "run_as_user": "root" },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/messages",
            "log_group_name": "/app/${PROJECT_NAME}/system",
            "log_stream_name": "{instance_id}/messages"
          },
          {
            "file_path": "/var/log/nginx/error.log",
            "log_group_name": "/app/${PROJECT_NAME}/nginx",
            "log_stream_name": "{instance_id}/nginx-error"
          }
        ]
      }
    }
  },
  "metrics": {
    "metrics_collected": {
      "mem":  { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["disk_used_percent"], "resources": ["/"] }
    },
    "append_dimensions": {
      "AutoScalingGroupName": "\$${aws:AutoScalingGroupName}",
      "InstanceId":           "\$${aws:InstanceId}"
    }
  }
}
EOF

/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

echo "User data completed successfully"

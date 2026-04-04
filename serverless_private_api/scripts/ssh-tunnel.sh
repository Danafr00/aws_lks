#!/bin/bash
# SSH tunnel through Bastion → RDS
# Usage: ./ssh-tunnel.sh <bastion-ip> <rds-endpoint> <path-to-key.pem>

BASTION_IP="${1:?Usage: $0 <bastion-ip> <rds-endpoint> <key.pem>}"
RDS_HOST="${2:?RDS endpoint required}"
KEY_PATH="${3:?Key path required}"
LOCAL_PORT=3307

echo "Opening SSH tunnel: localhost:$LOCAL_PORT → $RDS_HOST:3306 via Bastion $BASTION_IP"
echo "Connect with: mysql -h 127.0.0.1 -P $LOCAL_PORT -u admin -p lksdb"
echo "Press Ctrl+C to close tunnel."

ssh -i "$KEY_PATH" \
    -N \
    -L "${LOCAL_PORT}:${RDS_HOST}:3306" \
    ec2-user@"$BASTION_IP" \
    -o StrictHostKeyChecking=no

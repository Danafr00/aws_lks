#!/bin/bash
# Destroy all resources — run this after the exam to avoid charges

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

echo "WARNING: This will destroy ALL resources including:"
echo "  - NAT Gateway (~\$0.045/hr)"
echo "  - ALB (~\$0.008/hr)"
echo "  - RDS MySQL (~\$0.017/hr)"
echo "  - Lambda, DynamoDB, API Gateway (free tier)"
echo ""
echo "Type 'yes' to confirm destruction:"
read -r confirm

if [ "$confirm" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

cd "$TF_DIR"
terraform destroy -auto-approve

echo ""
echo "All resources destroyed."

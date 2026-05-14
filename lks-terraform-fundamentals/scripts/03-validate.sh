#!/bin/bash
# End-to-end validation of all layers

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

cd "$TF_DIR"

PASS=0
FAIL=0

check() {
    local name="$1"
    local cmd="$2"
    local expected="$3"

    echo -n "  [$name] ... "
    result=$(eval "$cmd" 2>&1) || true
    if echo "$result" | grep -q "$expected"; then
        echo "PASS"
        ((PASS++))
    else
        echo "FAIL (got: $result)"
        ((FAIL++))
    fi
}

echo "=== Layer 1: VPC ==="
VPC_ID=$(terraform output -raw vpc_id 2>/dev/null || echo "")
check "VPC exists" \
    "aws ec2 describe-vpcs --vpc-ids $VPC_ID --query 'Vpcs[0].State' --output text" \
    "available"

echo ""
echo "=== Layer 2: ALB ==="
ALB_DNS=$(terraform output -raw alb_dns_name 2>/dev/null || echo "")

# Wait up to 3 minutes for EC2 to become healthy
echo "  Waiting for EC2 health check (up to 3 min)..."
for i in $(seq 1 18); do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$ALB_DNS/health" || echo "000")
    if [ "$HTTP_STATUS" = "200" ]; then break; fi
    echo -n "."
    sleep 10
done

check "ALB health check" \
    "curl -s http://$ALB_DNS/health" \
    "ok"

echo ""
echo "=== Layer 3: RDS ==="
DB_SECRET=$(terraform output -raw db_secret_arn 2>/dev/null || echo "")
check "Secret exists" \
    "aws secretsmanager describe-secret --secret-id $DB_SECRET --query 'Name' --output text" \
    "db-credentials"

echo ""
echo "=== Layer 4: Serverless API ==="
API_URL=$(terraform output -raw api_gateway_url 2>/dev/null || echo "")

# Create item
CREATE=$(curl -s -X POST "$API_URL/items" \
    -H "Content-Type: application/json" \
    -d '{"name":"test-item","value":"hello"}')
ITEM_ID=$(echo "$CREATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")

check "POST /items" \
    "echo '$CREATE'" \
    "test-item"

check "GET /items/{id}" \
    "curl -s $API_URL/items/$ITEM_ID" \
    "test-item"

check "DELETE /items/{id}" \
    "curl -s -X DELETE $API_URL/items/$ITEM_ID" \
    "deleted"

echo ""
echo "==================================="
echo "  PASS: $PASS  |  FAIL: $FAIL"
echo "==================================="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

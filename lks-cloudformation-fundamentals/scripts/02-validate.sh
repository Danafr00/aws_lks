#!/bin/bash
# End-to-end validation

set -e

STACK_NAME="lks-fundamentals"
REGION="us-east-1"

PASS=0; FAIL=0

check() {
    local name="$1" cmd="$2" expected="$3"
    echo -n "  [$name] ... "
    result=$(eval "$cmd" 2>&1) || true
    if echo "$result" | grep -q "$expected"; then
        echo "PASS"; ((PASS++))
    else
        echo "FAIL (got: $result)"; ((FAIL++))
    fi
}

get_output() {
    aws cloudformation describe-stacks \
      --stack-name "$STACK_NAME" --region "$REGION" \
      --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" \
      --output text
}

echo "=== Stack status ==="
check "Stack complete" \
    "aws cloudformation describe-stacks --stack-name $STACK_NAME --region $REGION --query 'Stacks[0].StackStatus' --output text" \
    "CREATE_COMPLETE\|UPDATE_COMPLETE"

echo ""
echo "=== Layer 1: VPC ==="
VPC_ID=$(get_output VpcId)
check "VPC available" \
    "aws ec2 describe-vpcs --vpc-ids $VPC_ID --query 'Vpcs[0].State' --output text" \
    "available"

echo ""
echo "=== Layer 2: ALB ==="
ALB_DNS=$(get_output ALBDnsName)
echo "  Waiting for EC2 health check (up to 3 min)..."
for i in $(seq 1 18); do
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://$ALB_DNS/health" || echo "000")
    [ "$STATUS" = "200" ] && break
    echo -n "."; sleep 10
done
check "ALB /health" "curl -s http://$ALB_DNS/health" "ok"
check "ALB /db-test" "curl -s http://$ALB_DNS/db-test" "mysql_version"

echo ""
echo "=== Layer 3: Serverless API ==="
API_URL=$(get_output ApiUrl)
CREATE=$(curl -s -X POST "$API_URL/items" \
    -H "Content-Type: application/json" -d '{"name":"test","value":42}')
ITEM_ID=$(echo "$CREATE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
check "POST /items"       "echo '$CREATE'"                        "test"
check "GET /items/{id}"   "curl -s $API_URL/items/$ITEM_ID"       "test"
check "DELETE /items/{id}" "curl -s -X DELETE $API_URL/items/$ITEM_ID" "deleted"

echo ""
echo "================================"
echo "  PASS: $PASS  |  FAIL: $FAIL"
echo "================================"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0

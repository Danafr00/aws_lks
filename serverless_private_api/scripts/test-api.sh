#!/bin/bash
# Quick API smoke tests
# Usage: API_URL=https://xxxx.execute-api.ap-southeast-1.amazonaws.com/prod ./test-api.sh

API="${API_URL:?Set API_URL env var}"

echo "=== GET /items ==="
curl -s "$API/items" | python3 -m json.tool

echo ""
echo "=== POST /items ==="
curl -s -X POST "$API/items" \
  -H "Content-Type: application/json" \
  -d '{"name":"test-item","value":"hello LKS"}' | python3 -m json.tool

echo ""
echo "=== GET /items (after insert) ==="
curl -s "$API/items" | python3 -m json.tool

echo ""
echo "=== DELETE /items/1 ==="
curl -s -X DELETE "$API/items/1" | python3 -m json.tool

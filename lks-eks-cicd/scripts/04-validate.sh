#!/bin/bash
set -e

CLUSTER_NAME="lks-wallet-eks"
REGION="ap-southeast-1"
NAMESPACE="wallet"

echo "==> Updating kubeconfig"
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"

# ── 1. Pod health ────────────────────────────────────────────────────────────
echo ""
echo "==> [1] Pod status"
kubectl get pods -n "$NAMESPACE" -o wide

# ── 2. EFS mount verification ────────────────────────────────────────────────
echo ""
echo "==> [2] EFS ReadWriteMany test"

POD1=$(kubectl get pod -n "$NAMESPACE" -l app=wallet-api \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "$POD1" ]]; then
  echo "  ERROR: No wallet-api pod found in namespace $NAMESPACE"
  exit 1
fi

echo "  Writing test file from $POD1..."
kubectl exec -n "$NAMESPACE" "$POD1" -- sh -c \
  "echo 'efs-rwx-$(date +%s)' > /app/uploads/validate.txt && echo OK"

echo "  Reading test file back from $POD1..."
kubectl exec -n "$NAMESPACE" "$POD1" -- cat /app/uploads/validate.txt

# If 2+ pods exist, verify the second pod can also see the file
POD2=$(kubectl get pod -n "$NAMESPACE" -l app=wallet-api \
  -o jsonpath='{.items[1].metadata.name}' 2>/dev/null || true)

if [[ -n "$POD2" ]]; then
  echo "  Verifying second pod ($POD2) sees the same file (ReadWriteMany)..."
  kubectl exec -n "$NAMESPACE" "$POD2" -- cat /app/uploads/validate.txt
  echo "  ReadWriteMany confirmed across pods."
else
  echo "  Only 1 pod running — scale to 2 to test cross-pod ReadWriteMany:"
  echo "    kubectl scale deployment wallet-api -n $NAMESPACE --replicas=2"
fi

# ── 3. Liveness endpoint ─────────────────────────────────────────────────────
echo ""
echo "==> [3] Liveness check via port-forward"
kubectl port-forward "svc/wallet-api-svc" 8080:80 -n "$NAMESPACE" &
PF_PID=$!
sleep 3

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health/live)
kill $PF_PID 2>/dev/null

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "  /health/live → $HTTP_CODE OK"
else
  echo "  /health/live → $HTTP_CODE (check pod logs)"
fi

# ── 4. HPA status ────────────────────────────────────────────────────────────
echo ""
echo "==> [4] HPA status"
kubectl get hpa wallet-api-hpa -n "$NAMESPACE"

echo ""
echo "  To trigger HPA scale-up, run:"
echo "    kubectl run load-gen --image=busybox --restart=Never -n $NAMESPACE \\"
echo "      -- sh -c \"while true; do wget -q -O- http://wallet-api-svc/health/live; done\""
echo "    kubectl get hpa wallet-api-hpa -n $NAMESPACE -w"
echo "    kubectl delete pod load-gen -n $NAMESPACE"

# ── 5. PVC bound ────────────────────────────────────────────────────────────
echo ""
echo "==> [5] PVC status"
kubectl get pvc -n "$NAMESPACE"

echo ""
echo "==> Validation complete."

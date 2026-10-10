#!/usr/bin/env bash
# Test HPA: uruchamia obciążenie k6 (hpa-load.yaml), pokazuje skalowanie, czeka na powrót do minReplicas i sprząta.
set -euo pipefail
cd "$(dirname "$0")"
NS=crud
hpa() { kubectl -n "$NS" get hpa crud-app -o jsonpath="{.status.$1}"; }
show() { printf '%s  repliki: %s/%s  CPU: %s%%\n' "$(date +%T)" "$(hpa currentReplicas)" "$(hpa desiredReplicas)" \
  "$(kubectl -n "$NS" get hpa crud-app -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}')"; }
cleanup() { kubectl delete -f hpa-load.yaml --ignore-not-found >/dev/null; }
trap cleanup EXIT

min=$(kubectl -n "$NS" get hpa crud-app -o jsonpath='{.spec.minReplicas}')
kubectl apply -f hpa-load.yaml >/dev/null
echo "Obciążenie k6 uruchomione (~4 min)"
until [ -n "$(kubectl -n "$NS" get job hpa-load -o jsonpath='{.status.succeeded}{.status.failed}')" ]; do show; sleep 15; done
kubectl -n "$NS" logs job/hpa-load | grep -E 'checks_(succeeded|failed)|http_req_failed' || true
echo "Obciążenie zakończone — czekam na powrót do ${min} replik"
until [ "$(hpa currentReplicas)" = "$min" ]; do show; sleep 15; done
show
echo "OK"

#!/usr/bin/env bash
# Test NetworkPolicy w namespace crud: crud-app łączy się z bazą, pod spoza namespace — nie.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=crud
IMAGE=lab-registry:5000/$(grep -oP 'image: lab-registry:5000/\K\S+' gitops/crud/manifests/deployment.yaml)
# próba połączenia TCP z timeoutem 3 s (obraz crud-app ma Pythona, nie trzeba nic pobierać)
probe() { echo "import socket; socket.create_connection(('$1', $2), 3)"; }
fail=0

check() { # opis, oczekiwany wynik (ok|blocked), komenda...
  local desc=$1 want=$2; shift 2
  if "$@" >/dev/null 2>&1; then got=ok; else got=blocked; fi
  if [ "$got" = "$want" ]; then echo "OK    $desc: $got"; else echo "BŁĄD  $desc: $got (oczekiwano $want)"; fail=1; fi
}
outside() { # uruchamia sondę w jednorazowym podzie w namespace default
  kubectl -n default run "netpol-test-$RANDOM" --image="$IMAGE" --restart=Never --rm -i --quiet \
    --command -- python -c "$(probe "$1" "$2")"
}

check "crud-app -> pg-rw:5432"            ok      kubectl -n "$NS" exec deploy/crud-app -- python -c "$(probe pg-rw 5432)"
check "default  -> pg-rw.crud:5432"       blocked outside pg-rw.crud.svc.cluster.local 5432
check "default  -> crud-app.crud:80"      blocked outside crud-app.crud.svc.cluster.local 80
check "HTTPS (Traefik) -> crud-app"       ok      curl -sf https://crud.lab.test/items

echo "Odrzucone połączenia w Hubble:"
kubectl -n kube-system exec ds/cilium -c cilium-agent -- \
  hubble observe --verdict DROPPED --to-namespace "$NS" --last 5 2>/dev/null || true
exit $fail

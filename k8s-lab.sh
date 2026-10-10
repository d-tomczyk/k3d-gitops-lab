#!/usr/bin/env bash
#
# k8s-lab.sh — lab Kubernetes na jednym hoście: k3d + Cilium + Hubble
#
# Użycie:
#   ./k8s-lab.sh install   # instaluje k3d i Cilium CLI, tworzy klaster + rejestr, instaluje Cilium i Hubble
#                          # (values: cluster/cilium-values.yaml)
#   ./k8s-lab.sh up        # idempotentnie: install, gdy brak klastra; start + bpf, gdy zatrzymany
#   ./k8s-lab.sh upgrade   # stosuje zmiany z cluster/cilium-values.yaml (cilium upgrade)
#   ./k8s-lab.sh bpf       # po "k3d cluster start" — ponownie montuje BPF i restartuje Cilium
#   ./k8s-lab.sh stop      # zatrzymuje klaster (stan i obrazy zostają)
#   ./k8s-lab.sh status    # węzły, Cilium, aplikacje Argo CD
#   ./k8s-lab.sh destroy   # usuwa klaster (cache obrazów zostaje)
#   ./k8s-lab.sh purge-cache  # usuwa pull-through cache obrazów i ich wolumeny
#
# Zakłada, że Docker i kubectl są już zainstalowane.

set -euo pipefail

# ---------- Konfiguracja ----------
CLUSTER_NAME="${CLUSTER_NAME:-lab}"
AGENTS="${AGENTS:-2}"
HTTP_PORT="${HTTP_PORT:-80}"            # Ingress (Traefik) HTTP na localhost:HTTP_PORT
HTTPS_PORT="${HTTPS_PORT:-443}"         # Ingress (Traefik) HTTPS na localhost:HTTPS_PORT
REGISTRY_NAME="${REGISTRY_NAME:-lab-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"  # rejestr obrazów na localhost:REGISTRY_PORT
CONTEXT="k3d-${CLUSTER_NAME}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CILIUM_VALUES="${CILIUM_VALUES:-${SCRIPT_DIR}/cluster/cilium-values.yaml}"
REGISTRIES_CONFIG="${SCRIPT_DIR}/cluster/k3d-registries.yaml"
# Pull-through cache obrazów: nazwa|zdalny rejestr|port na localhost.
# Kontenery k3d-cache-* i wolumeny nie są usuwane przez "destroy" — obrazy pobierają się raz.
CACHES=(
  "cache-docker|https://registry-1.docker.io|5101"
  "cache-quay|https://quay.io|5102"
  "cache-ghcr|https://ghcr.io|5103"
  "cache-k8s|https://registry.k8s.io|5104"
)

# ---------- Pomocnicze ----------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

arch() {
  case "$(uname -m)" in
    x86_64)  echo amd64 ;;
    aarch64) echo arm64 ;;
    *) die "Nieobsługiwana architektura: $(uname -m)" ;;
  esac
}

node_containers() {
  docker ps --format '{{.Names}}' | grep -E "^k3d-${CLUSTER_NAME}-(server|agent)-[0-9]+$" || true
}

# Nazwa kontenera rejestru w sieci Dockera (k3d może dodać prefiks "k3d-")
registry_host() {
  docker ps --format '{{.Names}}' | grep -E "^(k3d-)?${REGISTRY_NAME}$" | head -n1 || true
}

cluster_exists() {
  k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER_NAME}\""
}

# ---------- Kroki ----------
check_prereqs() {
  log "Sprawdzam wymagania"
  command -v docker  >/dev/null || die "Brak dockera"
  command -v kubectl >/dev/null || die "Brak kubectl"
  command -v curl    >/dev/null || die "Brak curl"
  docker info >/dev/null 2>&1 || die "Brak dostępu do Dockera (czy jesteś w grupie docker?)"
}

install_k3d() {
  if command -v k3d >/dev/null; then
    log "k3d już zainstalowane: $(k3d version | head -n1)"
    return
  fi
  log "Instaluję k3d"
  curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
}

install_cilium_cli() {
  if command -v cilium >/dev/null; then
    log "Cilium CLI już zainstalowane: $(cilium version --client 2>/dev/null | head -n1)"
    return
  fi
  log "Instaluję Cilium CLI"
  local version a tmp
  version="$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"
  a="$(arch)"
  tmp="$(mktemp -d)"
  (
    cd "$tmp"
    curl -fsSL --remote-name-all \
      "https://github.com/cilium/cilium-cli/releases/download/${version}/cilium-linux-${a}.tar.gz" \
      "https://github.com/cilium/cilium-cli/releases/download/${version}/cilium-linux-${a}.tar.gz.sha256sum"
    sha256sum --check "cilium-linux-${a}.tar.gz.sha256sum"
    sudo tar xzf "cilium-linux-${a}.tar.gz" -C /usr/local/bin
  )
  rm -rf "$tmp"
}

ensure_caches() {
  log "Pull-through cache obrazów"
  local entry name url port
  for entry in "${CACHES[@]}"; do
    IFS='|' read -r name url port <<<"$entry"
    if docker ps -a --format '{{.Names}}' | grep -qx "k3d-${name}"; then
      docker start "k3d-${name}" >/dev/null
      echo "    k3d-${name}: uruchomiony"
    else
      k3d registry create "$name" --proxy-remote-url "$url" \
        -p "127.0.0.1:${port}" -v "k3d-${name}:/var/lib/registry" --no-help
    fi
  done
}

cache_registries_args() {
  local entry name
  for entry in "${CACHES[@]}"; do
    name="${entry%%|*}"
    printf -- '--registry-use\nk3d-%s:5000\n' "$name"
  done
}

create_cluster() {
  if cluster_exists; then
    warn "Klaster '${CLUSTER_NAME}' już istnieje — pomijam tworzenie"
    return
  fi
  local cache_args
  mapfile -t cache_args < <(cache_registries_args)
  log "Tworzę klaster '${CLUSTER_NAME}' (1 server + ${AGENTS} agentów, bez Flannela)"
  k3d cluster create "${CLUSTER_NAME}" \
    --agents "${AGENTS}" \
    -p "${HTTP_PORT}:80@loadbalancer" \
    -p "${HTTPS_PORT}:443@loadbalancer" \
    --registry-create "${REGISTRY_NAME}:0.0.0.0:${REGISTRY_PORT}" \
    --registry-config "${REGISTRIES_CONFIG}" \
    "${cache_args[@]}" \
    --k3s-arg "--flannel-backend=none@server:*" \
    --k3s-arg "--disable-network-policy@server:*"
}

mount_bpf() {
  log "Montuję BPF i cgroup2 w węzłach"
  local nodes
  nodes="$(node_containers)"
  [ -n "$nodes" ] || die "Nie znaleziono uruchomionych węzłów klastra '${CLUSTER_NAME}'"

  for node in $nodes; do
    docker exec "$node" sh -c '
      grep -q " /sys/fs/bpf bpf " /proc/mounts || mount bpffs /sys/fs/bpf -t bpf
      mount --make-shared /sys/fs/bpf

      mkdir -p /run/cilium/cgroupv2
      grep -q " /run/cilium/cgroupv2 cgroup2 " /proc/mounts || mount -t cgroup2 none /run/cilium/cgroupv2
      mount --make-shared /run/cilium/cgroupv2
    ' && echo "    ${node}: OK" || warn "${node}: montowanie nie powiodło się"
  done
}

install_cilium() {
  if kubectl --context "$CONTEXT" -n kube-system get ds cilium >/dev/null 2>&1; then
    warn "Cilium już zainstalowane — pomijam"
  else
    log "Instaluję Cilium"
    # k3s ma wbudowane kube-proxy (nie jako DaemonSet), więc Cilium CLI błędnie
    # włącza kubeProxyReplacement i próbuje łączyć się z API przez adres z kubeconfiga
    # hosta (0.0.0.0:<port>), nieosiągalny z węzłów. Zostawiamy kube-proxy z k3s
    # i wskazujemy API server po nazwie kontenera w sieci Dockera.
    cilium install --context "$CONTEXT" \
      --values "$CILIUM_VALUES" \
      --set ipam.mode=kubernetes \
      --set kubeProxyReplacement=false \
      --set k8sServiceHost="k3d-${CLUSTER_NAME}-server-0" \
      --set k8sServicePort=6443
  fi
  log "Czekam na gotowość Cilium"
  cilium status --context "$CONTEXT" --wait
}

summary() {
  echo
  log "Gotowe"
  kubectl --context "$CONTEXT" get nodes -o wide
  cat <<EOF

  Kontekst kubectl:  ${CONTEXT}
  Ingress:           http://localhost:${HTTP_PORT}  https://localhost:${HTTPS_PORT}
  Rejestr obrazów:   docker push localhost:${REGISTRY_PORT}/<obraz>  (w klastrze: $(registry_host):${REGISTRY_PORT})
  Hubble UI:         cilium hubble ui
  Test łączności:    cilium connectivity test   (kilka minut)

  Stop/start:        k3d cluster stop ${CLUSTER_NAME} / k3d cluster start ${CLUSTER_NAME}
  Po każdym start:   $0 bpf
EOF
}

# ---------- Komendy ----------
cmd_install() {
  check_prereqs
  install_k3d
  install_cilium_cli
  ensure_caches
  create_cluster
  mount_bpf
  install_cilium
  summary
}

cmd_bpf() {
  check_prereqs
  ensure_caches
  mount_bpf
  log "Restartuję Cilium"
  kubectl --context "$CONTEXT" -n kube-system rollout restart ds/cilium
  cilium status --context "$CONTEXT" --wait
}

cmd_up() {
  check_prereqs
  if ! cluster_exists; then
    cmd_install
  elif [ -z "$(node_containers)" ]; then
    ensure_caches
    log "Uruchamiam zatrzymany klaster '${CLUSTER_NAME}'"
    k3d cluster start "${CLUSTER_NAME}"
    cmd_bpf
  elif ! bpf_mounted; then
    # Np. po restarcie hosta: Docker sam podnosi węzły, ale montowania BPF przepadają
    warn "Węzły działają, ale bez montowań BPF — naprawiam"
    cmd_bpf
  else
    log "Klaster '${CLUSTER_NAME}' działa"
    ensure_caches
  fi
}

bpf_mounted() {
  local node
  for node in $(node_containers); do
    docker exec "$node" grep -q " /sys/fs/bpf bpf " /proc/mounts || return 1
  done
}

cmd_upgrade() {
  check_prereqs
  log "Aktualizuję Cilium wg ${CILIUM_VALUES}"
  cilium upgrade --context "$CONTEXT" \
    --reset-values \
    --values "$CILIUM_VALUES" \
    --set ipam.mode=kubernetes \
    --set kubeProxyReplacement=false \
    --set k8sServiceHost="k3d-${CLUSTER_NAME}-server-0" \
    --set k8sServicePort=6443
  cilium status --context "$CONTEXT" --wait
}

cmd_stop() {
  check_prereqs
  log "Zatrzymuję klaster '${CLUSTER_NAME}'"
  k3d cluster stop "${CLUSTER_NAME}"
}

cmd_status() {
  check_prereqs
  if [ -z "$(node_containers)" ]; then
    warn "Klaster '${CLUSTER_NAME}' nie działa (./k8s-lab.sh up)"
    return
  fi
  kubectl --context "$CONTEXT" get nodes
  echo
  cilium status --context "$CONTEXT" 2>/dev/null | sed -n '1,6p'
  echo
  kubectl --context "$CONTEXT" -n argocd get applications 2>/dev/null || warn "Brak Argo CD"
  echo
  local bad
  bad="$(kubectl --context "$CONTEXT" get pods -A --no-headers 2>/dev/null | grep -vE 'Running|Completed' || true)"
  if [ -n "$bad" ]; then warn "Pody, które nie działają:"; echo "$bad"; else log "Wszystkie pody działają"; fi
}

cmd_purge_cache() {
  check_prereqs
  local entry name
  for entry in "${CACHES[@]}"; do
    name="${entry%%|*}"
    log "Usuwam k3d-${name} i wolumen"
    k3d registry delete "k3d-${name}" 2>/dev/null || true
    docker volume rm "k3d-${name}" >/dev/null 2>&1 || true
  done
}

cmd_destroy() {
  check_prereqs
  log "Usuwam klaster '${CLUSTER_NAME}'"
  k3d cluster delete "${CLUSTER_NAME}"
}

case "${1:-}" in
  install) cmd_install ;;
  up)      cmd_up ;;
  bpf)     cmd_bpf ;;
  upgrade) cmd_upgrade ;;
  stop)    cmd_stop ;;
  status)  cmd_status ;;
  purge-cache) cmd_purge_cache ;;
  destroy) cmd_destroy ;;
  *) echo "Użycie: $0 {install|up|bpf|upgrade|stop|status|destroy|purge-cache}"; exit 1 ;;
esac

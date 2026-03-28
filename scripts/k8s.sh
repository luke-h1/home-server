#!/usr/bin/env bash

# Usage:
#   cp kubernetes/.env.example kubernetes/.env   # then edit
#   ./scripts/k8s.sh secrets
#   ./scripts/k8s.sh apply all
#   ./scripts/k8s.sh apply immich
#   ./scripts/k8s.sh upgrade-apps
#   ./scripts/k8s.sh upgrade-k3s
#
# Requires: kubectl, envsubst (gettext package: apt install gettext-base)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${K8S_ENV_FILE:-${ROOT}/kubernetes/.env}"

ENV_SUBST_FORMAT='${IMMICH_DOMAIN}${IMMICH_PUBLIC_URL}${GRAFANA_DOMAIN}${PROMETHEUS_DOMAIN}${ALERTS_DOMAIN}${GRAFANA_ROOT_URL}${BACKUP_S3_BUCKET}${BACKUP_S3_PREFIX}${AWS_REGION}'

usage() {
  sed -n '2,20p' "$0" | sed 's/^# //'
  echo "
Commands:
  env-check          Verify kubectl and envsubst; load .env
  secrets            Create/update immich + monitoring secrets (incl. Alertmanager Traefik basic auth)
  apply all|immich|immich-backup|monitoring   Kustomize + envsubst + kubectl apply (server-side; large ConfigMaps)
  deploy all            secrets + apply all (first-time convenience)
  diff all|immich|immich-backup|monitoring   Preview changes
  delete immich|monitoring     Delete namespace (destructive)
  restart [ns]       Rollout restart all deployments in namespace (default: both ns)
  restart-deploy NS/DEPLOY     e.g. immich/immich-server
  upgrade-apps       Rollout restart immich + monitoring deployments (image pull latest :release)
  upgrade-k3s        Re-run k3s installer (INSTALL_K3S_CHANNEL / K3S_CHANNEL from .env)
  node-labels        Apply NODE_LABELS from .env to node (see .env.example)
  node-taint         Apply NODE_TAINT from .env (you must add tolerations to workloads)
  node-taint-rm      Remove taint named in NODE_TAINT from .env
  backup-suspend     Suspend immich-pgdump-s3 CronJob
  backup-resume      Resume immich-pgdump-s3 CronJob
"
}

require_backup_s3_env() {
  : "${BACKUP_S3_BUCKET:?Set BACKUP_S3_BUCKET in ${ENV_FILE} (S3 bucket for DB dumps)}"
  : "${AWS_REGION:?Set AWS_REGION (e.g. eu-west-2)}"
  export BACKUP_S3_PREFIX="${BACKUP_S3_PREFIX:-immich/pgdump}"
}

load_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Missing ${ENV_FILE}. Copy kubernetes/.env.example to kubernetes/.env" >&2
    exit 1
  fi
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
  export KUBECONFIG="${KUBECONFIG:-}"
}

require_tools() {
  command -v kubectl >/dev/null 2>&1 || {
    echo "kubectl not found" >&2
    exit 1
  }
  command -v envsubst >/dev/null 2>&1 || {
    echo "envsubst not found (apt install gettext-base / brew install gettext)" >&2
    exit 1
  }
}

require_domain_vars() {
  : "${IMMICH_DOMAIN:?Set IMMICH_DOMAIN in ${ENV_FILE}}"
  : "${IMMICH_PUBLIC_URL:?Set IMMICH_PUBLIC_URL in ${ENV_FILE}}"
  : "${GRAFANA_DOMAIN:?Set GRAFANA_DOMAIN in ${ENV_FILE}}"
  : "${GRAFANA_ROOT_URL:?Set GRAFANA_ROOT_URL in ${ENV_FILE}}"
  : "${PROMETHEUS_DOMAIN:?Set PROMETHEUS_DOMAIN in ${ENV_FILE}}"
  : "${ALERTS_DOMAIN:?Set ALERTS_DOMAIN in ${ENV_FILE}}"
}

kustomize_render() {
  local dir="$1"
  kubectl kustomize "${dir}" | envsubst "${ENV_SUBST_FORMAT}"
}

# Server-side apply avoids kubectl.kubernetes.io/last-applied-configuration growing past the
# 256KiB annotation limit (large Grafana dashboard ConfigMaps from kustomize fail otherwise).
apply_kustomize_stream() {
  kubectl apply --server-side --force-conflicts --field-manager=home-server-kustomize -f -
}

apply_stack() {
  local target="$1"
  require_domain_vars
  case "${target}" in
    all)
      require_backup_s3_env
      kustomize_render "${ROOT}/kubernetes" | apply_kustomize_stream
      ;;
    immich)
      kustomize_render "${ROOT}/kubernetes/immich" | apply_kustomize_stream
      ;;
    immich-backup)
      require_backup_s3_env
      kustomize_render "${ROOT}/kubernetes/immich-backup" | apply_kustomize_stream
      ;;
    monitoring)
      kustomize_render "${ROOT}/kubernetes/monitoring" | apply_kustomize_stream
      ;;
    *)
      echo "Unknown target: ${target}" >&2
      exit 1
      ;;
  esac
}

diff_stack() {
  local target="$1"
  require_domain_vars
  case "${target}" in
    all)
      require_backup_s3_env
      kustomize_render "${ROOT}/kubernetes" | kubectl diff -f - || true
      ;;
    immich) kustomize_render "${ROOT}/kubernetes/immich" | kubectl diff -f - || true ;;
    immich-backup)
      require_backup_s3_env
      kustomize_render "${ROOT}/kubernetes/immich-backup" | kubectl diff -f - || true
      ;;
    monitoring) kustomize_render "${ROOT}/kubernetes/monitoring" | kubectl diff -f - || true ;;
    *) echo "Unknown target" >&2; exit 1 ;;
  esac
}

cmd_secrets() {
  : "${IMMICH_DB_PASSWORD:?Set IMMICH_DB_PASSWORD in ${ENV_FILE}}"
  : "${GRAFANA_ADMIN_USER:?Set GRAFANA_ADMIN_USER in ${ENV_FILE}}"
  : "${GRAFANA_ADMIN_PASSWORD:?Set GRAFANA_ADMIN_PASSWORD in ${ENV_FILE}}"

  kubectl create namespace immich 2>/dev/null || true
  kubectl create namespace monitoring 2>/dev/null || true

  kubectl create secret generic immich-secrets \
    -n immich \
    --from-literal=DB_PASSWORD="${IMMICH_DB_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic grafana-admin \
    -n monitoring \
    --from-literal=admin-user="${GRAFANA_ADMIN_USER}" \
    --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  : "${ALERTS_BASIC_AUTH_USER:?Set ALERTS_BASIC_AUTH_USER in ${ENV_FILE} (Traefik basic auth for ${ALERTS_DOMAIN:-alerts})}"
  : "${ALERTS_BASIC_AUTH_PASSWORD:?Set ALERTS_BASIC_AUTH_PASSWORD in ${ENV_FILE}}"
  local alerts_hash
  alerts_hash="$(openssl passwd -apr1 "${ALERTS_BASIC_AUTH_PASSWORD}")"
  kubectl create secret generic alertmanager-basic-auth \
    -n monitoring \
    --from-literal=users="${ALERTS_BASIC_AUTH_USER}:${alerts_hash}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "alertmanager-basic-auth applied (HTTP basic auth on Alertmanager ingress / ${ALERTS_DOMAIN:-alerts})."

  if [[ -n "${BACKUP_S3_ACCESS_KEY_ID:-}" && -n "${BACKUP_S3_SECRET_ACCESS_KEY:-}" ]]; then
    kubectl create secret generic backup-s3-credentials \
      -n immich \
      --from-literal=AWS_ACCESS_KEY_ID="${BACKUP_S3_ACCESS_KEY_ID}" \
      --from-literal=AWS_SECRET_ACCESS_KEY="${BACKUP_S3_SECRET_ACCESS_KEY}" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "backup-s3-credentials applied in immich."
  else
    echo "Skipping backup-s3-credentials (set BACKUP_S3_ACCESS_KEY_ID and BACKUP_S3_SECRET_ACCESS_KEY for S3 dumps)."
  fi

  if [[ -n "${CLOUDFLARE_EXPORTER_API_TOKEN:-}" ]]; then
    declare -a cf_secret=(
      kubectl create secret generic cloudflare-exporter
      -n monitoring
      --from-literal=CF_API_TOKEN="${CLOUDFLARE_EXPORTER_API_TOKEN}"
    )
    [[ -n "${CLOUDFLARE_ACCOUNT_IDS:-}" ]] && cf_secret+=(--from-literal=CF_ACCOUNTS="${CLOUDFLARE_ACCOUNT_IDS}")
    [[ -n "${CLOUDFLARE_EXPORTER_ZONES:-}" ]] && cf_secret+=(--from-literal=CF_ZONES="${CLOUDFLARE_EXPORTER_ZONES}")
    [[ -n "${CLOUDFLARE_EXPORTER_EXCLUDE_ZONES:-}" ]] &&
      cf_secret+=(--from-literal=CF_EXCLUDE_ZONES="${CLOUDFLARE_EXPORTER_EXCLUDE_ZONES}")
    "${cf_secret[@]}" --dry-run=client -o yaml | kubectl apply -f -
    echo "cloudflare-exporter secret applied in monitoring (worker metrics → Prometheus → Grafana)."
  else
    echo "Skipping cloudflare-exporter secret (set CLOUDFLARE_EXPORTER_API_TOKEN for Cloudflare Workers metrics)."
  fi

  echo "Secrets applied. Roll out workloads if they were already running: ./scripts/k8s.sh restart"
}

cmd_restart() {
  local ns="${1:-}"
  if [[ -z "${ns}" ]]; then
    for n in immich monitoring; do
      kubectl rollout restart deployment -n "${n}" 2>/dev/null || true
    done
    echo "Restarted deployments in immich and monitoring (if present)."
    return 0
  fi
  kubectl rollout restart deployment -n "${ns}"
}

cmd_restart_deploy() {
  local pair="$1"
  [[ "${pair}" == */* ]] || {
    echo "Use NS/NAME e.g. immich/immich-server" >&2
    exit 1
  }
  local ns="${pair%%/*}"
  local dep="${pair#*/}"
  kubectl rollout restart "deployment/${dep}" -n "${ns}"
}

cmd_upgrade_apps() {
  cmd_restart
  echo "To pull fresh :release images, ensure imagePullPolicy is IfNotPresent/Always as desired."
}

cmd_upgrade_k3s() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    echo "Run upgrade-k3s as root on the server (sudo)." >&2
    exit 1
  fi
  load_env
  export INSTALL_K3S_CHANNEL="${K3S_CHANNEL:-stable}"
  curl -sfL https://get.k3s.io | sh -
  echo "k3s upgraded (channel ${INSTALL_K3S_CHANNEL}). Check: kubectl get nodes"
}

primary_node() {
  if [[ -n "${NODE_NAME:-}" ]]; then
    echo "${NODE_NAME}"
    return
  fi
  kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

cmd_node_labels() {
  [[ -n "${NODE_LABELS:-}" ]] || {
    echo "Set NODE_LABELS in .env (comma-separated key=value)" >&2
    exit 1
  }
  local node
  node="$(primary_node)"
  [[ -n "${node}" ]] || {
    echo "No node found" >&2
    exit 1
  }
  IFS=',' read -ra pairs <<<"${NODE_LABELS}"
  for p in "${pairs[@]}"; do
    key="${p%%=*}"
    val="${p#*=}"
    kubectl label node "${node}" "${key}=${val}" --overwrite
  done
  echo "Labeled node ${node}"
}

cmd_node_taint() {
  [[ -n "${NODE_TAINT:-}" ]] || {
    echo "Set NODE_TAINT=key=value:NoSchedule in .env" >&2
    exit 1
  }
  local node
  node="$(primary_node)"
  kubectl taint node "${node}" "${NODE_TAINT}" --overwrite
  echo "Tainted ${node} with ${NODE_TAINT}. Add matching tolerations to Pods or they will not schedule."
}

cmd_node_taint_rm() {
  [[ -n "${NODE_TAINT:-}" ]] || {
    echo "Set NODE_TAINT in .env (same key=value:Effect as when adding)" >&2
    exit 1
  }
  local node
  node="$(primary_node)"
  kubectl taint node "${node}" "${NODE_TAINT}-" 2>/dev/null || true
  echo "Removed taint ${NODE_TAINT} from ${node} (if it existed)."
}

cmd_delete() {
  local target="$1"
  case "${target}" in
    immich) kubectl delete namespace immich --wait=false ;;
    monitoring) kubectl delete namespace monitoring --wait=false ;;
    *) echo "Use: delete immich | delete monitoring" >&2; exit 1 ;;
  esac
}

main() {
  local cmd="${1:-}"
  shift || true
  case "${cmd}" in
    "" | -h | --help | help) usage ;;
    env-check)
      require_tools
      load_env
      require_domain_vars
      kubectl cluster-info
      ;;
    secrets)
      require_tools
      load_env
      cmd_secrets
      ;;
    apply)
      require_tools
      load_env
      apply_stack "${1:-all}"
      ;;
    deploy)
      require_tools
      load_env
      cmd_secrets
      apply_stack all
      echo "Deployed. Check: kubectl get pods -A"
      ;;
    diff)
      require_tools
      load_env
      diff_stack "${1:-all}"
      ;;
    delete) require_tools; load_env; cmd_delete "${1:?immich or monitoring}" ;;
    restart)
      require_tools
      load_env
      cmd_restart "${1:-}"
      ;;
    restart-deploy) require_tools; load_env; cmd_restart_deploy "${1:?NS/DEPLOY}" ;;
    upgrade-apps) require_tools; load_env; cmd_upgrade_apps ;;
    upgrade-k3s) load_env; cmd_upgrade_k3s ;;
    node-labels) require_tools; load_env; cmd_node_labels ;;
    node-taint) require_tools; load_env; cmd_node_taint ;;
    node-taint-rm) require_tools; load_env; cmd_node_taint_rm ;;
    backup-suspend)
      require_tools
      kubectl patch cronjob immich-pgdump-s3 -n immich -p '{"spec":{"suspend":true}}' --type=merge
      ;;
    backup-resume)
      require_tools
      kubectl patch cronjob immich-pgdump-s3 -n immich -p '{"spec":{"suspend":false}}' --type=merge
      ;;
    diagnose-immich-routing)
      command -v kubectl >/dev/null 2>&1 || {
        echo "kubectl not found" >&2
        exit 1
      }
      if [[ -f "${ENV_FILE}" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "${ENV_FILE}"
        set +a
        export KUBECONFIG="${KUBECONFIG:-}"
      fi
      bash "${ROOT}/scripts/diagnose-immich-routing.sh"
      ;;
    *)
      echo "Unknown command: ${cmd}" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"

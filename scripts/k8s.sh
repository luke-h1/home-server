#!/usr/bin/env bash

# Usage:
#   cp kubernetes/.env.example kubernetes/.env   # then edit
#   ./scripts/k8s.sh secrets
#   ./scripts/k8s.sh apply all
#   ./scripts/k8s.sh apply immich
#   ./scripts/k8s.sh apply paperless
#   ./scripts/k8s.sh apply n8n
#   ./scripts/k8s.sh upgrade-apps
#   ./scripts/k8s.sh upgrade-k3s
#   ./scripts/k8s.sh dns-flush
#
# Requires: kubectl, envsubst (gettext package: apt install gettext-base)
# For n8n chart actions: helm

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${K8S_ENV_FILE:-${ROOT}/kubernetes/.env}"

ENV_SUBST_FORMAT='${IMMICH_DOMAIN}${IMMICH_PUBLIC_URL}${DOCUMENT_DOMAIN}${N8N_DOMAIN}${GRAFANA_DOMAIN}${PROMETHEUS_DOMAIN}${ALERTS_DOMAIN}${PUSHGATEWAY_DOMAIN}${GRAFANA_ROOT_URL}${ALERTS_BASIC_AUTH_USER}${ALERTS_BASIC_AUTH_PASSWORD}${BACKUP_S3_BUCKET}${BACKUP_S3_PREFIX}${AWS_REGION}${ALERTMANAGER_TELEGRAM_CHAT_ID}${PAPERLESS_TIME_ZONE}${PAPERLESS_ADMIN_MAIL}${N8N_HELM_CHART_VERSION}'

usage() {
  sed -n '2,20p' "$0" | sed 's/^# //'
  echo "
Commands:
  env-check          Verify kubectl and envsubst; load .env
  secrets            Create/update immich + paperless + n8n + monitoring secrets (incl. Traefik basic auth on Alertmanager, Prometheus, Pushgateway)
  apply all|immich|immich-backup|monitoring|paperless|n8n   Deploy selected stack
  deploy all            secrets + apply all (first-time convenience)
  diff all|immich|immich-backup|monitoring|paperless|n8n   Preview changes
  delete immich|paperless|n8n|monitoring     Delete namespace (destructive)
  restart [ns]       Rollout restart all deployments in namespace (default: both ns)
  restart-deploy NS/DEPLOY     e.g. immich/immich-server
  upgrade-apps       Rollout restart immich + monitoring deployments (image pull latest :release)
  upgrade-k3s        Re-run k3s installer (INSTALL_K3S_CHANNEL / K3S_CHANNEL from .env)
  node-labels        Apply NODE_LABELS from .env to node (see .env.example)
  node-taint         Apply NODE_TAINT from .env (you must add tolerations to workloads)
  node-taint-rm      Remove taint named in NODE_TAINT from .env
  backup-suspend     Suspend immich-pgdump-s3 CronJob
  backup-resume      Resume immich-pgdump-s3 CronJob
  dns-flush          Rollout-restart CoreDNS in kube-system (clears in-cluster DNS cache)
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

require_helm() {
  command -v helm >/dev/null 2>&1 || {
    echo "helm not found (required for n8n chart deploys)" >&2
    exit 1
  }
}

require_domain_vars() {
  : "${IMMICH_DOMAIN:?Set IMMICH_DOMAIN in ${ENV_FILE}}"
  : "${IMMICH_PUBLIC_URL:?Set IMMICH_PUBLIC_URL in ${ENV_FILE}}"
  : "${DOCUMENT_DOMAIN:?Set DOCUMENT_DOMAIN in ${ENV_FILE}}"
  : "${N8N_DOMAIN:?Set N8N_DOMAIN in ${ENV_FILE}}"
  : "${GRAFANA_DOMAIN:?Set GRAFANA_DOMAIN in ${ENV_FILE}}"
  : "${GRAFANA_ROOT_URL:?Set GRAFANA_ROOT_URL in ${ENV_FILE}}"
  : "${PROMETHEUS_DOMAIN:?Set PROMETHEUS_DOMAIN in ${ENV_FILE}}"
  : "${ALERTS_DOMAIN:?Set ALERTS_DOMAIN in ${ENV_FILE}}"
  : "${PUSHGATEWAY_DOMAIN:?Set PUSHGATEWAY_DOMAIN in ${ENV_FILE}}"
  : "${ALERTS_BASIC_AUTH_USER:?Set ALERTS_BASIC_AUTH_USER in ${ENV_FILE} (Blackbox probe + Traefik basic auth on Alertmanager)}"
  : "${ALERTS_BASIC_AUTH_PASSWORD:?Set ALERTS_BASIC_AUTH_PASSWORD in ${ENV_FILE}}"
}

kustomize_render() {
  local dir="$1"
  kubectl kustomize "${dir}" | envsubst "${ENV_SUBST_FORMAT}"
}

n8n_values_render() {
  envsubst "${ENV_SUBST_FORMAT}" <"${ROOT}/kubernetes/n8n/values.yaml"
}

n8n_chart_deploy() {
  require_helm
  n8n_values_render | helm upgrade --install n8n \
    oci://ghcr.io/n8n-io/n8n-helm-chart/n8n \
    --version "${N8N_HELM_CHART_VERSION:-1.4.3}" \
    --namespace n8n \
    -f -
}

n8n_chart_diff() {
  require_helm
  n8n_values_render | helm template n8n \
    oci://ghcr.io/n8n-io/n8n-helm-chart/n8n \
    --version "${N8N_HELM_CHART_VERSION:-1.4.3}" \
    --namespace n8n \
    -f - | kubectl diff -f - || true
}

# Server-side apply avoids 256KiB last-applied-configuration limits on large ConfigMaps.
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
      n8n_chart_deploy
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
    paperless)
      kustomize_render "${ROOT}/kubernetes/paperless" | apply_kustomize_stream
      ;;
    n8n)
      kustomize_render "${ROOT}/kubernetes/n8n" | apply_kustomize_stream
      n8n_chart_deploy
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
      n8n_chart_diff
      ;;
    immich) kustomize_render "${ROOT}/kubernetes/immich" | kubectl diff -f - || true ;;
    immich-backup)
      require_backup_s3_env
      kustomize_render "${ROOT}/kubernetes/immich-backup" | kubectl diff -f - || true
      ;;
    monitoring) kustomize_render "${ROOT}/kubernetes/monitoring" | kubectl diff -f - || true ;;
    paperless) kustomize_render "${ROOT}/kubernetes/paperless" | kubectl diff -f - || true ;;
    n8n)
      kustomize_render "${ROOT}/kubernetes/n8n" | kubectl diff -f - || true
      n8n_chart_diff
      ;;
    *) echo "Unknown target" >&2; exit 1 ;;
  esac
}

cmd_secrets() {
  : "${IMMICH_DB_PASSWORD:?Set IMMICH_DB_PASSWORD in ${ENV_FILE}}"
  : "${PAPERLESS_DB_PASSWORD:?Set PAPERLESS_DB_PASSWORD in ${ENV_FILE}}"
  : "${PAPERLESS_SECRET_KEY:?Set PAPERLESS_SECRET_KEY in ${ENV_FILE}}"
  : "${PAPERLESS_ADMIN_USER:?Set PAPERLESS_ADMIN_USER in ${ENV_FILE}}"
  : "${PAPERLESS_ADMIN_PASSWORD:?Set PAPERLESS_ADMIN_PASSWORD in ${ENV_FILE}}"
  : "${PAPERLESS_ADMIN_MAIL:?Set PAPERLESS_ADMIN_MAIL in ${ENV_FILE}}"
  : "${N8N_DB_PASSWORD:?Set N8N_DB_PASSWORD in ${ENV_FILE}}"
  : "${N8N_ENCRYPTION_KEY:?Set N8N_ENCRYPTION_KEY in ${ENV_FILE}}"
  : "${GRAFANA_ADMIN_USER:?Set GRAFANA_ADMIN_USER in ${ENV_FILE}}"
  : "${GRAFANA_ADMIN_PASSWORD:?Set GRAFANA_ADMIN_PASSWORD in ${ENV_FILE}}"

  kubectl create namespace immich 2>/dev/null || true
  kubectl create namespace paperless 2>/dev/null || true
  kubectl create namespace n8n 2>/dev/null || true
  kubectl create namespace monitoring 2>/dev/null || true

  kubectl create secret generic immich-secrets \
    -n immich \
    --from-literal=DB_PASSWORD="${IMMICH_DB_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic paperless-secrets \
    -n paperless \
    --from-literal=DB_PASSWORD="${PAPERLESS_DB_PASSWORD}" \
    --from-literal=PAPERLESS_SECRET_KEY="${PAPERLESS_SECRET_KEY}" \
    --from-literal=PAPERLESS_ADMIN_USER="${PAPERLESS_ADMIN_USER}" \
    --from-literal=PAPERLESS_ADMIN_PASSWORD="${PAPERLESS_ADMIN_PASSWORD}" \
    --from-literal=PAPERLESS_ADMIN_MAIL="${PAPERLESS_ADMIN_MAIL}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic n8n-db-password \
    -n n8n \
    --from-literal=password="${N8N_DB_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic n8n-secret-config \
    -n n8n \
    --from-literal=N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY}" \
    --from-literal=N8N_HOST="${N8N_DOMAIN}" \
    --from-literal=N8N_PORT="443" \
    --from-literal=N8N_PROTOCOL="https" \
    --dry-run=client -o yaml | kubectl apply -f -

  kubectl create secret generic grafana-admin \
    -n monitoring \
    --from-literal=admin-user="${GRAFANA_ADMIN_USER}" \
    --from-literal=admin-password="${GRAFANA_ADMIN_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f -

  : "${PUSHGATEWAY_BASIC_AUTH_USER:?Set PUSHGATEWAY_BASIC_AUTH_USER in ${ENV_FILE}}"
  : "${PUSHGATEWAY_BASIC_AUTH_PASSWORD:?Set PUSHGATEWAY_BASIC_AUTH_PASSWORD in ${ENV_FILE}}"
  local pushgateway_hash
  pushgateway_hash="$(openssl passwd -apr1 "${PUSHGATEWAY_BASIC_AUTH_PASSWORD}")"
  kubectl create secret generic pushgateway-basic-auth \
    -n monitoring \
    --from-literal=users="${PUSHGATEWAY_BASIC_AUTH_USER}:${pushgateway_hash}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "pushgateway-basic-auth applied (HTTP basic auth on Pushgateway ingress / ${PUSHGATEWAY_DOMAIN})."

  : "${ALERTS_BASIC_AUTH_USER:?Set ALERTS_BASIC_AUTH_USER in ${ENV_FILE} (Traefik basic auth for ${ALERTS_DOMAIN:-alerts})}"
  : "${ALERTS_BASIC_AUTH_PASSWORD:?Set ALERTS_BASIC_AUTH_PASSWORD in ${ENV_FILE}}"
  local alerts_hash
  alerts_hash="$(openssl passwd -apr1 "${ALERTS_BASIC_AUTH_PASSWORD}")"
  kubectl create secret generic alertmanager-basic-auth \
    -n monitoring \
    --from-literal=users="${ALERTS_BASIC_AUTH_USER}:${alerts_hash}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "alertmanager-basic-auth applied (HTTP basic auth on Alertmanager ingress / ${ALERTS_DOMAIN:-alerts})."

  kubectl create secret generic prometheus-basic-auth \
    -n monitoring \
    --from-literal=users="${ALERTS_BASIC_AUTH_USER}:${alerts_hash}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "prometheus-basic-auth applied (HTTP basic auth on Prometheus ingress / ${PROMETHEUS_DOMAIN:-prometheus})."

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

  if [[ -n "${ALERTMANAGER_TELEGRAM_BOT_TOKEN:-}" && -n "${ALERTMANAGER_TELEGRAM_CHAT_ID:-}" ]]; then
    kubectl create secret generic alertmanager-telegram \
      -n monitoring \
      --from-literal=bot-token="${ALERTMANAGER_TELEGRAM_BOT_TOKEN}" \
      --from-literal=chat-id="${ALERTMANAGER_TELEGRAM_CHAT_ID}" \
      --dry-run=client -o yaml | kubectl apply -f -
    echo "alertmanager-telegram secret applied in monitoring (Telegram Alertmanager receiver)."
  else
    echo "Skipping alertmanager-telegram secret (set ALERTMANAGER_TELEGRAM_BOT_TOKEN and ALERTMANAGER_TELEGRAM_CHAT_ID for Telegram alerts)."
  fi

  echo "Secrets applied. Roll out workloads if they were already running: ./scripts/k8s.sh restart"
}

cmd_restart() {
  local ns="${1:-}"
  if [[ -z "${ns}" ]]; then
    for n in immich paperless n8n monitoring; do
      kubectl rollout restart deployment -n "${n}" 2>/dev/null || true
    done
    echo "Restarted deployments in immich, paperless, n8n, and monitoring (if present)."
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

# CoreDNS holds any plugin cache in process memory; restarting pods is the supported way to clear it.
# Does not flush the Linux host resolver (systemd-resolved, etc.).
cmd_dns_flush() {
  local ns="${DNS_COREDNS_NAMESPACE:-kube-system}"
  local deps dep
  deps="$(kubectl get deploy -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -Ei 'coredns' || true)"
  if [[ -z "${deps}" ]]; then
    echo "No deployment matching *coredns* in namespace ${ns}." >&2
    echo "Set DNS_COREDNS_NAMESPACE or: kubectl get deploy -A | grep -i coredns" >&2
    exit 1
  fi
  while IFS= read -r dep; do
    [[ -z "${dep}" ]] && continue
    echo "Rolling restart ${ns}/deployment/${dep}..."
    kubectl rollout restart "deployment/${dep}" -n "${ns}"
    kubectl rollout status "deployment/${dep}" -n "${ns}" --timeout=120s
  done <<< "${deps}"
  echo "CoreDNS restarted (in-cluster DNS cache cleared for new pods)."
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
    paperless) kubectl delete namespace paperless --wait=false ;;
    n8n)
      helm uninstall n8n -n n8n 2>/dev/null || true
      kubectl delete namespace n8n --wait=false
      ;;
    monitoring) kubectl delete namespace monitoring --wait=false ;;
    *) echo "Use: delete immich | paperless | n8n | monitoring" >&2; exit 1 ;;
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
      [[ "${1:-all}" == "n8n" || "${1:-all}" == "all" ]] && require_helm
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
      [[ "${1:-all}" == "n8n" || "${1:-all}" == "all" ]] && require_helm
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
    dns-flush)
      require_tools
      if [[ -f "${ENV_FILE}" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "${ENV_FILE}"
        set +a
        export KUBECONFIG="${KUBECONFIG:-}"
      fi
      cmd_dns_flush
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

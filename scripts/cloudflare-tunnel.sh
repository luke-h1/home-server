#!/usr/bin/env bash
# Cloudflare Tunnel helpers: token-based install (dashboard) or file-based config for custom domains.
# Domains must match kubernetes/.env (IMMICH_DOMAIN, GRAFANA_DOMAIN, …).
#
# Docs: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
#
# Quick path (recommended):
#   Zero Trust → Networks → Tunnels → create tunnel → copy token
#   sudo ./scripts/cloudflare-tunnel.sh install-token
#
# File-based (this repo template):
#   cloudflared tunnel login
#   cloudflared tunnel create home-server
#   Set CLOUDFLARE_TUNNEL_ID and CLOUDFLARE_TUNNEL_CREDENTIALS_FILE in kubernetes/.env
#   sudo ./scripts/cloudflare-tunnel.sh write-config
#   sudo cloudflared --config /etc/cloudflared/config.yml tunnel run
#   # or: sudo cloudflared service install (after config + credentials in place)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${K8S_ENV_FILE:-${ROOT}/kubernetes/.env}"
TPL="${ROOT}/kubernetes/cloudflared-config.yml.tpl"

ENV_SUBST_CF='${IMMICH_DOMAIN}${GRAFANA_DOMAIN}${PROMETHEUS_DOMAIN}${ALERTS_DOMAIN}${CLOUDFLARE_TUNNEL_ORIGIN}${CLOUDFLARE_TUNNEL_ID}${CLOUDFLARE_TUNNEL_CREDENTIALS_FILE}'

usage() {
  cat <<'EOF'
Usage:
  cloudflare-tunnel.sh install-token   Install systemd service (needs CLOUDFLARE_TUNNEL_TOKEN in .env, run as root)
  cloudflare-tunnel.sh write-config    Write /etc/cloudflared/config.yml from template + .env (root)
  cloudflare-tunnel.sh render-config   Print config to stdout (no root)
  cloudflare-tunnel.sh print-dns-hints Show CNAME-style hints for your zones

Requires kubernetes/.env (copy from kubernetes/.env.example).
EOF
}

load_env() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "Missing ${ENV_FILE}" >&2
    exit 1
  fi
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
}

require_root() {
  if [[ "${EUID:-0}" -ne 0 ]]; then
    echo "Run as root for this command." >&2
    exit 1
  fi
}

require_domains() {
  : "${IMMICH_DOMAIN:?}"
  : "${GRAFANA_DOMAIN:?}"
  : "${PROMETHEUS_DOMAIN:?}"
  : "${ALERTS_DOMAIN:?}"
  : "${CLOUDFLARE_TUNNEL_ORIGIN:?}"
}

cmd_install_token() {
  require_root
  load_env
  : "${CLOUDFLARE_TUNNEL_TOKEN:?Set CLOUDFLARE_TUNNEL_TOKEN in kubernetes/.env}"
  if ! command -v cloudflared >/dev/null 2>&1; then
    echo "Install cloudflared first (scripts/setup-server or Cloudflare docs)." >&2
    exit 1
  fi
  cloudflared service install "${CLOUDFLARE_TUNNEL_TOKEN}"
  echo "Installed. Configure public hostnames in Zero Trust → Tunnels → your tunnel (match .env domains → ${CLOUDFLARE_TUNNEL_ORIGIN:-http://127.0.0.1:80})."
}

cmd_write_config() {
  require_root
  load_env
  require_domains
  : "${CLOUDFLARE_TUNNEL_ID:?Set CLOUDFLARE_TUNNEL_ID}"
  : "${CLOUDFLARE_TUNNEL_CREDENTIALS_FILE:?Set CLOUDFLARE_TUNNEL_CREDENTIALS_FILE (path to tunnel JSON)}"
  [[ -f "${CLOUDFLARE_TUNNEL_CREDENTIALS_FILE}" ]] || {
    echo "Credentials file not found: ${CLOUDFLARE_TUNNEL_CREDENTIALS_FILE}" >&2
    exit 1
  }
  command -v envsubst >/dev/null 2>&1 || {
    echo "envsubst missing (apt install gettext-base)" >&2
    exit 1
  }
  install -d -m 0700 /etc/cloudflared
  envsubst "${ENV_SUBST_CF}" <"${TPL}" >/etc/cloudflared/config.yml
  chmod 0600 /etc/cloudflared/config.yml
  echo "Wrote /etc/cloudflared/config.yml"
  echo "Run: cloudflared --config /etc/cloudflared/config.yml tunnel run"
  echo "Or install service pointing at this config (see Cloudflare docs for your cloudflared version)."
}

cmd_render_config() {
  load_env
  require_domains
  : "${CLOUDFLARE_TUNNEL_ID:?}"
  : "${CLOUDFLARE_TUNNEL_CREDENTIALS_FILE:?}"
  command -v envsubst >/dev/null 2>&1 || {
    echo "envsubst missing" >&2
    exit 1
  }
  envsubst "${ENV_SUBST_CF}" <"${TPL}"
}

cmd_print_dns_hints() {
  load_env
  require_domains
  echo "In Cloudflare DNS for each zone, create CNAMEs as shown in Zero Trust → Tunnels → your tunnel → Public hostnames."
  echo "Hostnames to register (proxy ON):"
  echo "  - ${IMMICH_DOMAIN}"
  echo "  - ${GRAFANA_DOMAIN}"
  echo "  - ${PROMETHEUS_DOMAIN}"
  echo "  - ${ALERTS_DOMAIN}"
  echo "Origin service in tunnel UI should match Traefik on the node, e.g. ${CLOUDFLARE_TUNNEL_ORIGIN:-http://127.0.0.1:80}"
}

main() {
  case "${1:-}" in
    install-token) cmd_install_token ;;
    write-config) cmd_write_config ;;
    render-config) cmd_render_config ;;
    print-dns-hints) cmd_print_dns_hints ;;
    -h | --help | "") usage ;;
    *)
      echo "Unknown: $1" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"

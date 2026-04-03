#!/usr/bin/env bash
#
# Send a synthetic alert to Alertmanager to verify notification delivery.
#
# Usage:
#   ./scripts/test-alert.sh
#   ./scripts/test-alert.sh --summary "Telegram test" --description "Manual test"
#   ./scripts/test-alert.sh --port-forward
#
# Requires: kubectl. For --port-forward, access to namespace monitoring.

set -euo pipefail

ALERTMANAGER_URL="${ALERTMANAGER_URL:-http://127.0.0.1:9093}"
SUMMARY="Telegram test alert"
DESCRIPTION="This is a manual Alertmanager delivery test."
ALERTNAME="TelegramTest"
SERVICE="monitoring"
SEVERITY="info"
PORT_FORWARD=0

usage() {
  sed -n '2,10p' "$0" | sed 's/^# //'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --summary)
      SUMMARY="${2:?}"
      shift
      ;;
    --description)
      DESCRIPTION="${2:?}"
      shift
      ;;
    --alertname)
      ALERTNAME="${2:?}"
      shift
      ;;
    --service)
      SERVICE="${2:?}"
      shift
      ;;
    --severity)
      SEVERITY="${2:?}"
      shift
      ;;
    --alertmanager-url)
      ALERTMANAGER_URL="${2:?}"
      shift
      ;;
    --port-forward)
      PORT_FORWARD=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl not found" >&2
  exit 1
}

pf_pid=""
cleanup() {
  if [[ -n "${pf_pid}" ]]; then
    kill "${pf_pid}" 2>/dev/null || true
    wait "${pf_pid}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ "${PORT_FORWARD}" -eq 1 ]]; then
  kubectl port-forward -n monitoring svc/alertmanager 9093:9093 >/tmp/test-alert-port-forward.log 2>&1 &
  pf_pid="$!"
  sleep 2
fi

payload="$(cat <<EOF
[
  {
    "labels": {
      "alertname": "${ALERTNAME}",
      "service": "${SERVICE}",
      "severity": "${SEVERITY}"
    },
    "annotations": {
      "summary": "${SUMMARY}",
      "description": "${DESCRIPTION}"
    }
  }
]
EOF
)"

curl -fsS -X POST "${ALERTMANAGER_URL}/api/v2/alerts" \
  -H 'Content-Type: application/json' \
  -d "${payload}"

echo
echo "Synthetic alert sent to ${ALERTMANAGER_URL}."

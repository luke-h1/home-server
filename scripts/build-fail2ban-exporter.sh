#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${FAIL2BAN_EXPORTER_IMAGE:-fail2ban-security-exporter:local}"
PLATFORM="${FAIL2BAN_EXPORTER_PLATFORM:-linux/amd64}"
ARCHIVE="${FAIL2BAN_EXPORTER_ARCHIVE:-/tmp/fail2ban-security-exporter.tar}"

docker build --platform "${PLATFORM}" -t "${IMAGE}" "${ROOT}/exporters/fail2ban"
docker save "${IMAGE}" -o "${ARCHIVE}"

if command -v k3s >/dev/null 2>&1; then
  sudo k3s ctr images import "${ARCHIVE}"
elif command -v ctr >/dev/null 2>&1; then
  sudo ctr -n k8s.io images import "${ARCHIVE}"
else
  echo "Neither k3s nor ctr was found; image built but not imported into the Kubernetes runtime." >&2
  exit 1
fi

echo "Imported ${IMAGE} into the Kubernetes runtime."
echo "Next:"
echo "  ./scripts/k8s.sh apply monitoring"
echo "  kubectl -n monitoring rollout status ds/fail2ban-exporter --timeout=120s"

#!/usr/bin/env bash
# Upload latest k3s embedded-etcd snapshot to S3
#
# Prereq: k3s with embedded etcd (default single-server install).
# IAM user needs s3:PutObject on BACKUP_S3_BUCKET.

set -euo pipefail

if [[ "${EUID:-0}" -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${K8S_ENV_FILE:-${ROOT}/kubernetes/.env}"
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

: "${BACKUP_S3_BUCKET:?}"
: "${AWS_REGION:?}"
PREFIX="${K3S_SNAPSHOT_S3_PREFIX:-k3s-etcd}"

command -v aws >/dev/null 2>&1 || {
  echo "Install aws CLI (e.g. apt install awscli)." >&2
  exit 1
}

k3s etcd-snapshot save --name "cron-$(date -u +%Y%m%dT%H%M%SZ)"

SNAP_DIR="/var/lib/rancher/k3s/server/db/snapshots"
LATEST="$(ls -t "${SNAP_DIR}"/* 2>/dev/null | head -1 || true)"
if [[ -z "${LATEST}" ]]; then
  echo "No snapshot file under ${SNAP_DIR}" >&2
  exit 1
fi

key="${PREFIX}/$(basename "${LATEST}")"

export AWS_DEFAULT_REGION="${AWS_REGION}"
aws s3 cp "${LATEST}" "s3://${BACKUP_S3_BUCKET}/${key}"
echo "Uploaded s3://${BACKUP_S3_BUCKET}/${key}"

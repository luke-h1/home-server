#!/usr/bin/env bash
#
# Restore Immich's Postgres database from an S3 object produced by immich-pgdump-s3
# (kubernetes/immich-backup/backup-cronjob.yaml). This does NOT restore library files:
# /usr/src/app/upload must already match the backup (same machine or separate media sync).
#
# Usage:
#   ./scripts/restore-immich-from-s3.sh --s3-key immich/pgdump/immich-20250101T0400Z.dump
#   ./scripts/restore-immich-from-s3.sh s3://my-bucket/immich/pgdump/immich-20250101T0400Z.dump
#   ./scripts/restore-immich-from-s3.sh --latest
#
# Requires: kubectl, kubernetes/.env (BACKUP_S3_BUCKET, BACKUP_S3_PREFIX, AWS_REGION),
#           secrets backup-s3-credentials + immich-secrets in namespace immich (./scripts/k8s.sh secrets).
# For --latest: AWS CLI on PATH and credentials (e.g. same keys as backup, or aws configure).
#
# Options:
#   --dry-run          Print actions only
#   --no-scale         Do not scale immich-server / immich-machine-learning (risky: open DB connections)
#   --wait-timeout SEC kubectl wait timeout (default 3600)
#   -h, --help

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${K8S_ENV_FILE:-${ROOT}/kubernetes/.env}"
NS="immich"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-3600}"

usage() {
  sed -n '2,22p' "$0" | sed 's/^# //'
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
  : "${BACKUP_S3_BUCKET:?Set BACKUP_S3_BUCKET in ${ENV_FILE}}"
  : "${AWS_REGION:?Set AWS_REGION in ${ENV_FILE}}"
  export BACKUP_S3_PREFIX="${BACKUP_S3_PREFIX:-immich/pgdump}"
}

command -v kubectl >/dev/null 2>&1 || {
  echo "kubectl not found" >&2
  exit 1
}

DRY_RUN=0
NO_SCALE=0
S3_KEY=""
S3_BUCKET=""
LATEST=0
POS_S3_URI=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --dry-run) DRY_RUN=1 ;;
    --no-scale) NO_SCALE=1 ;;
    --latest) LATEST=1 ;;
    --s3-key)
      S3_KEY="${2:?}"
      shift
      ;;
    --wait-timeout)
      WAIT_TIMEOUT="${2:?}"
      shift
      ;;
    s3://*)
      POS_S3_URI="$1"
      ;;
    *)
      echo "Unknown option or argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

load_env

if [[ -n "${POS_S3_URI}" ]]; then
  # s3://bucket/key
  without="${POS_S3_URI#s3://}"
  S3_BUCKET="${without%%/*}"
  S3_KEY="${without#*/}"
  [[ -n "${S3_KEY}" && "${S3_KEY}" != "${without}" ]] || {
    echo "Invalid S3 URI: ${POS_S3_URI}" >&2
    exit 1
  }
else
  S3_BUCKET="${BACKUP_S3_BUCKET}"
fi

if [[ "${LATEST}" -eq 1 ]]; then
  [[ -z "${S3_KEY}" ]] || {
    echo "Do not combine --latest with --s3-key or s3:// URI" >&2
    exit 1
  }
  command -v aws >/dev/null 2>&1 || {
    echo "aws CLI required for --latest" >&2
    exit 1
  }
  prefix="${BACKUP_S3_PREFIX%/}/"
  echo "Finding latest dump under s3://${S3_BUCKET}/${prefix}immich-*.dump"
  # shellcheck disable=SC2016
  S3_KEY="$(
    aws s3api list-objects-v2 \
      --bucket "${S3_BUCKET}" \
      --prefix "${prefix}" \
      --query 'Contents[?ends_with(Key, `.dump`)].Key' \
      --output text 2>/dev/null |
      tr '\t' '\n' |
      { grep -E 'immich-.*\.dump$' || true; } |
      sort |
      tail -n 1
  )"
  [[ -n "${S3_KEY}" ]] || {
    echo "No immich-*.dump objects found under s3://${S3_BUCKET}/${prefix}" >&2
    exit 1
  }
  echo "Using latest: s3://${S3_BUCKET}/${S3_KEY}"
elif [[ -z "${S3_KEY}" ]]; then
  echo "Provide --s3-key, s3://bucket/key, or --latest" >&2
  usage >&2
  exit 1
fi

[[ "${S3_KEY}" == *..* ]] && {
  echo "Refusing S3 key containing .." >&2
  exit 1
}

JOB_NAME="immich-pgrestore-$(date +%s)"
S3_URI="s3://${S3_BUCKET}/${S3_KEY}"

run() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '[dry-run] %q\n' "$@"
    return 0
  fi
  "$@"
}

scale_deployments() {
  local replicas="$1"
  run kubectl scale deployment/immich-server deployment/immich-machine-learning \
    -n "${NS}" --replicas="${replicas}"
}

render_job() {
  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NS}
  labels:
    app: immich-pgrestore-s3
spec:
  ttlSecondsAfterFinished: 86400
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: immich-pgrestore-s3
    spec:
      restartPolicy: Never
      initContainers:
        - name: s3-download
          image: amazon/aws-cli:2.17.44
          imagePullPolicy: IfNotPresent
          env:
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: backup-s3-credentials
                  key: AWS_ACCESS_KEY_ID
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: backup-s3-credentials
                  key: AWS_SECRET_ACCESS_KEY
            - name: AWS_DEFAULT_REGION
              value: "${AWS_REGION}"
            - name: S3_URI
              value: "${S3_URI}"
          command:
            - /bin/sh
            - -c
            - |
              set -eux
              aws s3 cp "${S3_URI}" /restore/immich.dump
              ls -la /restore/immich.dump
          volumeMounts:
            - name: restore
              mountPath: /restore
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: "1"
              memory: 512Mi
      containers:
        - name: pgrestore
          image: postgres:14-alpine
          imagePullPolicy: IfNotPresent
          env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: immich-secrets
                  key: DB_PASSWORD
            - name: PGHOST
              value: immich-database
            - name: PGUSER
              value: immich
            - name: PGDATABASE
              value: immich
          command:
            - /bin/sh
            - -c
            - |
              set -eux
              psql -d postgres -v ON_ERROR_STOP=1 -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'immich' AND pid <> pg_backend_pid();" || true
              pg_restore --verbose --clean --if-exists --no-owner --no-acl -d immich /restore/immich.dump
              echo "pg_restore finished successfully"
          volumeMounts:
            - name: restore
              mountPath: /restore
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 2Gi
      volumes:
        - name: restore
          emptyDir:
            sizeLimit: 12Gi
EOF
}

echo "WARNING: This replaces the immich database with s3://${S3_BUCKET}/${S3_KEY}"
echo "Library files on the PVC are unchanged; thumbnails may be wrong until media matches the DB."
if [[ "${DRY_RUN}" -eq 0 ]]; then
  read -r -p "Type RESTORE to continue: " confirm
  [[ "${confirm}" == "RESTORE" ]] || {
    echo "Aborted."
    exit 1
  }
fi

if [[ "${NO_SCALE}" -eq 0 ]]; then
  echo "Scaling down immich-server and immich-machine-learning..."
  scale_deployments 0
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    kubectl rollout status deployment/immich-server -n "${NS}" --timeout=300s || true
    kubectl rollout status deployment/immich-machine-learning -n "${NS}" --timeout=300s || true
  fi
else
  echo "Skipping scale-down (--no-scale)."
fi

cleanup_job() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    return 0
  fi
  kubectl delete job "${JOB_NAME}" -n "${NS}" --ignore-not-found=true >/dev/null 2>&1 || true
}

restore_scale_up() {
  if [[ "${NO_SCALE}" -eq 0 ]]; then
    echo "Scaling immich back up..."
    scale_deployments 1
  fi
}

trap restore_scale_up EXIT

if [[ "${DRY_RUN}" -eq 0 ]]; then
  cleanup_job
fi

echo "Creating Job ${JOB_NAME}..."
render_job | run kubectl apply -f -

if [[ "${DRY_RUN}" -eq 1 ]]; then
  trap - EXIT
  exit 0
fi

if kubectl wait --for=condition=complete "job/${JOB_NAME}" -n "${NS}" --timeout="${WAIT_TIMEOUT}s"; then
  :
else
  echo "Restore job failed or timed out. Recent logs:" >&2
  kubectl logs -n "${NS}" "job/${JOB_NAME}" -c pgrestore --tail=200 2>/dev/null || true
  kubectl logs -n "${NS}" "job/${JOB_NAME}" -c s3-download --tail=200 2>/dev/null || true
  exit 1
fi
trap - EXIT

if [[ "${NO_SCALE}" -eq 0 ]]; then
  echo "Scaling immich back up..."
  scale_deployments 1
  kubectl rollout status deployment/immich-server -n "${NS}" --timeout=600s || true
  kubectl rollout status deployment/immich-machine-learning -n "${NS}" --timeout=600s || true
fi

echo "Done. Job logs: kubectl logs -n ${NS} job/${JOB_NAME} -c pgrestore"

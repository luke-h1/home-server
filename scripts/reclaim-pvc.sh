#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  reclaim-pvc.sh list
  reclaim-pvc.sh reclaim <namespace>/<pvc> --yes

Commands:
  list                     Show local-path PVCs, backing PVs, host paths, and disk usage.
  reclaim NS/PVC --yes     Delete the PVC, wait for the PV to disappear, and remove any leftover local-path directory.

Notes:
  - This only supports `local-path` PVCs.
  - Reclaim exits if any pods still mount the PVC.
  - Run on the k3s node if you want automatic leftover directory cleanup.
EOF
}

require_kubectl() {
  command -v kubectl >/dev/null 2>&1 || {
    echo "kubectl not found" >&2
    exit 1
  }
}

pv_field() {
  local pv="$1"
  local field="$2"
  kubectl get pv "${pv}" -o "jsonpath=${field}" 2>/dev/null || true
}

size_of_path() {
  local path="$1"
  if [[ -d "${path}" ]]; then
    du -sh "${path}" 2>/dev/null | awk '{print $1}'
  else
    echo "-"
  fi
}

pods_using_claim() {
  local namespace="$1"
  local claim="$2"
  kubectl get pods -A -o go-template='{{range .items}}{{ $ns := .metadata.namespace }}{{ $name := .metadata.name }}{{range .spec.volumes}}{{if .persistentVolumeClaim}}{{printf "%s\t%s\t%s\n" $ns $name .persistentVolumeClaim.claimName}}{{end}}{{end}}{{end}}' |
    awk -F'\t' -v ns="${namespace}" -v pvc="${claim}" '$1 == ns && $3 == pvc { print $2 }'
}

list_local_path_pvcs() {
  printf '%-14s %-24s %-38s %-8s %-6s %s\n' "NAMESPACE" "PVC" "PV" "STATUS" "SIZE" "HOST_PATH"
  kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.storageClassName}{"\t"}{.status.phase}{"\t"}{.spec.volumeName}{"\n"}{end}' |
    while IFS=$'\t' read -r namespace pvc storage_class status pv; do
      [[ "${storage_class}" == "local-path" ]] || continue
      local host_path size
      host_path="$(pv_field "${pv}" '{.spec.local.path}')"
      size="$(size_of_path "${host_path}")"
      printf '%-14s %-24s %-38s %-8s %-6s %s\n' "${namespace}" "${pvc}" "${pv}" "${status}" "${size}" "${host_path}"
    done
}

cleanup_local_path_dir() {
  local host_path="$1"
  [[ -d "${host_path}" ]] || return 0
  [[ "${host_path}" == /var/lib/rancher/k3s/storage/* ]] || {
    echo "Refusing to remove unexpected path: ${host_path}" >&2
    return 1
  }

  if [[ -w "${host_path}" ]]; then
    rm -rf "${host_path}"
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo rm -rf "${host_path}"
    return 0
  fi

  echo "Leftover local-path directory still exists and needs manual cleanup: ${host_path}" >&2
  return 1
}

reclaim_pvc() {
  local target="${1:-}"
  local confirm="${2:-}"

  [[ "${target}" == */* ]] || {
    echo "Use <namespace>/<pvc>." >&2
    exit 1
  }
  [[ "${confirm}" == "--yes" ]] || {
    echo "Pass --yes to confirm PVC deletion." >&2
    exit 1
  }

  local namespace="${target%%/*}"
  local pvc="${target#*/}"
  local storage_class status pv host_path size

  storage_class="$(kubectl get pvc "${pvc}" -n "${namespace}" -o jsonpath='{.spec.storageClassName}')"
  status="$(kubectl get pvc "${pvc}" -n "${namespace}" -o jsonpath='{.status.phase}')"
  pv="$(kubectl get pvc "${pvc}" -n "${namespace}" -o jsonpath='{.spec.volumeName}')"

  [[ "${storage_class}" == "local-path" ]] || {
    echo "${namespace}/${pvc} uses ${storage_class:-<none>}, not local-path." >&2
    exit 1
  }
  [[ -n "${pv}" ]] || {
    echo "${namespace}/${pvc} is not bound to a PV." >&2
    exit 1
  }

  local consumers
  consumers="$(pods_using_claim "${namespace}" "${pvc}")"
  if [[ -n "${consumers}" ]]; then
    echo "Pods still using ${namespace}/${pvc}:" >&2
    echo "${consumers}" | sed 's/^/  - /' >&2
    echo "Scale down or remove those pods first, then rerun reclaim." >&2
    exit 1
  fi

  host_path="$(pv_field "${pv}" '{.spec.local.path}')"
  size="$(size_of_path "${host_path}")"

  echo "Reclaiming ${namespace}/${pvc}"
  echo "  status: ${status}"
  echo "  pv: ${pv}"
  echo "  size: ${size}"
  echo "  host path: ${host_path}"

  kubectl delete pvc "${pvc}" -n "${namespace}" --wait=true
  kubectl wait --for=delete "pv/${pv}" --timeout=90s 2>/dev/null || true

  cleanup_local_path_dir "${host_path}" || true

  echo "PVC reclaimed: ${namespace}/${pvc}"
}

main() {
  require_kubectl

  case "${1:-}" in
    list)
      list_local_path_pvcs
      ;;
    reclaim)
      reclaim_pvc "${2:-}" "${3:-}"
      ;;
    -h | --help | "")
      usage
      ;;
    *)
      echo "Unknown command: $1" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"

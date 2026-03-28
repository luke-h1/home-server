#!/usr/bin/env bash
# Persistent swap file. Idempotent; grows swap if existing file is smaller than SWAP_SIZE_GB.
#
# Usage: sudo ./scripts/setup-swap.sh
# Env: SWAP_SIZE_GB (default 16), SWAP_FILE (default /swapfile)

set -euo pipefail

: "${SWAP_SIZE_GB:=16}"
: "${SWAP_FILE:=/swapfile}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

if ! [[ "${SWAP_SIZE_GB}" =~ ^[1-9][0-9]*$ ]]; then
  echo "Invalid SWAP_SIZE_GB=${SWAP_SIZE_GB} (want a positive integer GiB)." >&2
  exit 1
fi

swapfile="${SWAP_FILE}"
parent="$(dirname "${swapfile}")"
install -d -m 0755 "${parent}"

want_kb=$(( SWAP_SIZE_GB * 1024 * 1024 + 512 * 1024 ))
avail_kb="$(df -Pk "${parent}" | awk 'NR==2 {print $4}')"
if [[ "${avail_kb}" =~ ^[0-9]+$ ]] && [[ "${avail_kb}" -lt "${want_kb}" ]]; then
  echo "Warning: low free space on ${parent} (${avail_kb} KiB); ${SWAP_SIZE_GB}G swap needs ~${want_kb} KiB including margin." >&2
fi

want_bytes=$(( SWAP_SIZE_GB * 1024 * 1024 * 1024 ))

if [[ -f "${swapfile}" ]]; then
  current_bytes="$(stat -c%s "${swapfile}" 2>/dev/null || stat -f%z "${swapfile}" 2>/dev/null || echo 0)"
  if ! [[ "${current_bytes}" =~ ^[0-9]+$ ]]; then
    current_bytes=0
  fi
  if [[ "${current_bytes}" -lt "${want_bytes}" ]]; then
    echo "Existing ${swapfile} is ${current_bytes} bytes; target is ${SWAP_SIZE_GB}GiB — replacing."
    swapoff "${swapfile}" 2>/dev/null || true
    rm -f "${swapfile}"
  fi
fi

if swapon --show 2>/dev/null | awk 'NR>1 {print $1}' | grep -qxF "${swapfile}"; then
  echo "Swap already active on ${swapfile} (${SWAP_SIZE_GB}GiB target met)."
elif [[ -f "${swapfile}" ]]; then
  echo "Enabling existing ${swapfile}."
  if ! swapon "${swapfile}" 2>/dev/null; then
    echo "swapon failed; recreating ${swapfile}." >&2
    swapoff "${swapfile}" 2>/dev/null || true
    rm -f "${swapfile}"
  fi
fi

if [[ ! -f "${swapfile}" ]]; then
  echo "Creating ${SWAP_SIZE_GB}GiB swap at ${swapfile}..."
  if ! fallocate -l "${SWAP_SIZE_GB}G" "${swapfile}" 2>/dev/null; then
    dd if=/dev/zero of="${swapfile}" bs=1M count=$(( SWAP_SIZE_GB * 1024 )) status=progress
  fi
  chmod 600 "${swapfile}"
  mkswap -L homelab-swap "${swapfile}"
  swapon "${swapfile}"
fi

if ! grep -qF "${swapfile} none swap sw 0 0" /etc/fstab; then
  echo "${swapfile} none swap sw 0 0" >>/etc/fstab
  echo "Added ${swapfile} to /etc/fstab for boot persistence."
fi

echo "Done. swapon --show:"
swapon --show
echo ""
free -h

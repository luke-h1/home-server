#!/usr/bin/env bash
set -euo pipefail

SSH_DIR="${HOME}/.ssh"
KEY_BASENAME="${1:-id_ed25519}"
KEY_PATH="${SSH_DIR}/${KEY_BASENAME}"

if [[ -n "${2-}" ]]; then
  COMMENT="$2"
else
  COMMENT="${SSH_KEY_COMMENT:-$(whoami)@$(hostname -s 2>/dev/null || hostname)}"
fi

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -e "${KEY_PATH}" ]] || [[ -e "${KEY_PATH}.pub" ]]; then
  echo "Refusing to overwrite: ${KEY_PATH} (or .pub) already exists." >&2
  exit 1
fi

exec ssh-keygen -t ed25519 -f "$KEY_PATH" -C "$COMMENT"

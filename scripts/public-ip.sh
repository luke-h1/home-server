#!/usr/bin/env bash
set -euo pipefail

# Print this machine's public IP (IPv4 or IPv6, whichever the service returns first).
# Usage:
#   ./scripts/public-ip.sh           → 203.0.113.50
#   ./scripts/public-ip.sh --cidr    → 203.0.113.50/32  or  2001:db8::1/128

cidr=false
case "${1-}" in
  -c | --cidr) cidr=true ;;
  -h | --help)
    echo "Usage: $(basename "$0") [--cidr]" >&2
    exit 0
    ;;
  "")
    ;;
  *)
    echo "Unknown option: $1" >&2
    exit 1
    ;;
esac

endpoints=(
  "https://api.ipify.org"
  "https://ifconfig.me/ip"
  "https://icanhazip.com"
)

ip=""
for url in "${endpoints[@]}"; do
  raw="$(curl -fsS --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ -n "$raw" ]]; then
    if [[ "$raw" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
      ip="$raw"
      break
    fi
    if [[ "$raw" == *:* ]]; then
      ip="$raw"
      break
    fi
  fi
done

if [[ -z "$ip" ]]; then
  echo "Could not determine public IP (check network or try again)." >&2
  exit 1
fi

if [[ "$cidr" == true ]]; then
  if [[ "$ip" == *:* ]]; then
    echo "${ip}/128"
  else
    echo "${ip}/32"
  fi
else
  echo "$ip"
fi

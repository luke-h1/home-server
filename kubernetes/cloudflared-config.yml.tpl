# Render: ./scripts/cloudflare-tunnel.sh render-config
# Install credentials JSON from: cloudflared tunnel login && cloudflared tunnel create NAME
tunnel: ${CLOUDFLARE_TUNNEL_ID}
credentials-file: ${CLOUDFLARE_TUNNEL_CREDENTIALS_FILE}
ingress:
  - hostname: ${IMMICH_DOMAIN}
    service: ${CLOUDFLARE_TUNNEL_ORIGIN}
  - hostname: ${GRAFANA_DOMAIN}
    service: ${CLOUDFLARE_TUNNEL_ORIGIN}
  - hostname: ${PROMETHEUS_DOMAIN}
    service: ${CLOUDFLARE_TUNNEL_ORIGIN}
  - hostname: ${ALERTS_DOMAIN}
    service: ${CLOUDFLARE_TUNNEL_ORIGIN}
  - service: http_status:404

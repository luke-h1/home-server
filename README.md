# home-server

## Contents

- [Terraform](#terraform) — VPS
- [Bootstrap](#bootstrap) — k3s + tooling + Docker
- [Deploy](#deploy) — `.env`, secrets, `k8s.sh`
- [Cloudflare Tunnel](#cloudflare-tunnel)
- [Stacks](#stacks)
- [Scripts](#scripts)
- [Health checks](#health-checks)

## Terraform

```bash
cd terraform
cp terraform.tfvars.example envs/prod.tfvars
# edit envs/prod.tfvars — keep secrets out of git
terraform init
terraform apply -var-file=envs/prod.tfvars
```

## Bootstrap

```bash
git clone https://github.com/luke-h1/home-server
cd home-server
sudo ./scripts/setup-server
```

Check: `systemctl status k3s`, `kubectl get nodes`.

## Deploy

Needs `kubectl`, `envsubst` (e.g. `gettext-base`).

```bash
cp kubernetes/.env.example kubernetes/.env
```

Fill in at least:

- **URLs:** `DOCUMENT_DOMAIN`, `N8N_DOMAIN`, `GRAFANA_DOMAIN`, `GRAFANA_ROOT_URL`, `PROMETHEUS_DOMAIN`, `ALERTS_DOMAIN`, `PUSHGATEWAY_DOMAIN`, `UPTIME_LHOWSAM_DOMAIN`, `UPTIME_FOAM_DOMAIN`
- **Secrets:** `PAPERLESS_DB_PASSWORD`, `PAPERLESS_SECRET_KEY`, `PAPERLESS_ADMIN_*`, `N8N_DB_PASSWORD`, `N8N_ENCRYPTION_KEY`, `GRAFANA_ADMIN_*`, `ALERTS_BASIC_AUTH_*` (Alertmanager + Prometheus ingress), `PUSHGATEWAY_BASIC_AUTH_*` (Pushgateway ingress), `ALERTMANAGER_TELEGRAM_*` (Alertmanager notifications)
- **S3 backups:** `BACKUP_S3_BUCKET`, `BACKUP_S3_PREFIX`, `AWS_REGION`, optional `BACKUP_S3_ACCESS_KEY_ID` / `BACKUP_S3_SECRET_ACCESS_KEY` for `./scripts/k8s.sh secrets`
- **Tunnel:** `CLOUDFLARE_TUNNEL_TOKEN`, `CLOUDFLARE_TUNNEL_ORIGIN` (default `http://127.0.0.1:80` → Traefik)

Domains in `.env` should match tunnel public hostnames + DNS.

```bash
./scripts/k8s.sh env-check
./scripts/k8s.sh secrets
./scripts/k8s.sh apply all          # needs S3 vars; includes monitoring, paperless, n8n, uptime-kuma
# or: ./scripts/k8s.sh deploy all
```

Partial: `apply monitoring` | `apply paperless` | `apply n8n` | `apply uptime-kuma`. Preview: `diff all`.

## Cloudflare Tunnel

1. Zero Trust → Tunnels → create tunnel → copy **install token** → `CLOUDFLARE_TUNNEL_TOKEN` in `.env`.
2. On the server: `sudo ./scripts/cloudflare-tunnel.sh install-token`
3. For **each** hostname in `.env`, add a **public hostname** pointing to **`http://127.0.0.1:80`** (same as `CLOUDFLARE_TUNNEL_ORIGIN`). Traefik routes by `Host`; do **not** point the tunnel at Immich’s pod port `2283`.
4. DNS: CNAME to the tunnel target (proxied), as shown in the tunnel UI.

```bash
./scripts/cloudflare-tunnel.sh print-dns-hints
```

Optional: `render-config` / `write-config` from `kubernetes/cloudflared-config.yml.tpl` if you run cloudflared with a config file.

## Stacks

| Namespace    | What                                                                                                                                                                                                                                                                |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `paperless`  | Paperless-ngx on `document.*` with Postgres, Redis, Apache Tika, Gotenberg, local PVCs for media/data/consume/export, daily S3 sync of persistent files to `documents/`, and a daily `document_exporter` archive upload to `documents/exports/`                |
| `n8n`        | n8n on `n8n.*` using the official `n8n-io/n8n-hosting` Helm chart, backed by in-cluster Postgres + Redis in queue mode                                                                                                                                                |
| `monitoring` | Prometheus, Grafana, Alertmanager (basic auth on Prometheus + alerts ingresses), Pushgateway (basic auth ingress for foam-proxy), Loki, Promtail, node-exporter, local `fail2ban-security-exporter` DaemonSet (needs host fail2ban) |
| `uptime-kuma` | Two Uptime Kuma instances: `uptime-kuma-lhowsam` on `UPTIME_LHOWSAM_DOMAIN` (lhowsam.com stack) and `uptime-kuma-foam` on `UPTIME_FOAM_DOMAIN` (foam-app.com stack), each with its own PVC |

Grafana dashboards include Traefik, app-specific boards, and a small **Server security signals** board (`f2b_*` + node metrics) with Loki available for raw pod and auth logs.

### Cluster logs with Loki

`./scripts/k8s.sh apply monitoring` now also deploys Loki + Promtail. Promtail tails Kubernetes pod logs cluster-wide and host `/var/log/auth.log`, and Grafana provisions a `Loki` datasource automatically.

Useful Explore queries:

```logql
{job="node-authlog"} |= "sshd"
{namespace="paperless"} |= "error"
```

### Local fail2ban exporter image

The fail2ban exporter is built from `exporters/fail2ban` and the DaemonSet uses a local-only image tag:

```bash
./scripts/build-fail2ban-exporter.sh
./scripts/k8s.sh apply monitoring
kubectl -n monitoring rollout status ds/fail2ban-exporter --timeout=120s
```

The script builds `fail2ban-security-exporter:local`, saves it, and imports it into the local k3s/containerd runtime. The manifest uses `imagePullPolicy: Never`, so the image must exist on the node before rollout.

Alert delivery defaults to Telegram once `ALERTMANAGER_TELEGRAM_BOT_TOKEN` and `ALERTMANAGER_TELEGRAM_CHAT_ID` are set and `./scripts/k8s.sh secrets` has created the `alertmanager-telegram` secret.

## Scripts

| Command                                             | Purpose                                               |
| --------------------------------------------------- | ----------------------------------------------------- |
| `./scripts/k8s.sh restart`                          | Rollout restart deployments in app namespaces         |
| `./scripts/reclaim-pvc.sh list` / `reclaim NS/PVC --yes` | Inspect and reclaim local-path PVC disk usage   |
| `./scripts/snapshot-k3s-s3.sh`                      | k3s etcd snapshot → S3 (server, root)                 |
| `./scripts/k8s.sh delete monitoring` \| `uptime-kuma` | Destructive                                         |

More flags: `./scripts/k8s.sh` (no args) or read `k8s.sh` usage block.

## Health checks

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "https://<GRAFANA_DOMAIN>/api/health"
curl -sS -o /dev/null -w '%{http_code}\n' -u 'USER:PASS' "https://<PROMETHEUS_DOMAIN>/-/ready"
curl -sS -o /dev/null -w '%{http_code}\n' -u 'USER:PASS' "https://<ALERTS_DOMAIN>/-/healthy"
curl -sS -o /dev/null -w '%{http_code}\n' "https://<UPTIME_LHOWSAM_DOMAIN>/"
curl -sS -o /dev/null -w '%{http_code}\n' "https://<UPTIME_FOAM_DOMAIN>/"
```

Uptime Kuma has no cluster secret: create the admin account in each UI on first visit (`UPTIME_LHOWSAM_DOMAIN` vs `UPTIME_FOAM_DOMAIN`).

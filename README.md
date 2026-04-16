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

- **URLs:** `IMMICH_DOMAIN`, `IMMICH_PUBLIC_URL`, `GRAFANA_DOMAIN`, `GRAFANA_ROOT_URL`, `PROMETHEUS_DOMAIN`, `ALERTS_DOMAIN`
- **Secrets:** `IMMICH_DB_PASSWORD`, `GRAFANA_ADMIN_*`, `ALERTS_BASIC_AUTH_*` (Alertmanager + Prometheus ingress; Blackbox probes), `ALERTMANAGER_TELEGRAM_*` (Alertmanager notifications)
- **S3 backups:** `BACKUP_S3_BUCKET`, `BACKUP_S3_PREFIX`, `AWS_REGION`, optional `BACKUP_S3_ACCESS_KEY_ID` / `BACKUP_S3_SECRET_ACCESS_KEY` for `./scripts/k8s.sh secrets`
- **Tunnel:** `CLOUDFLARE_TUNNEL_TOKEN`, `CLOUDFLARE_TUNNEL_ORIGIN` (default `http://127.0.0.1:80` → Traefik)
- **Optional:** `CLOUDFLARE_EXPORTER_API_TOKEN`, `CLOUDFLARE_ACCOUNT_IDS` for the Cloudflare exporter

Domains in `.env` should match tunnel public hostnames + DNS.

```bash
./scripts/k8s.sh env-check
./scripts/k8s.sh secrets
./scripts/k8s.sh apply all          # needs S3 vars; includes immich, backup cron, monitoring
# or: ./scripts/k8s.sh deploy all
```

Partial: `apply immich` | `apply immich-backup` | `apply monitoring` (Prometheus + Loki stack). Preview: `diff all`.

Weekly **Friday 00:00 UTC:** Postgres dump to S3 + library `aws s3 sync` from the `immich-server` sidecar (RWO PVC).

## Cloudflare Tunnel

1. Zero Trust → Tunnels → create tunnel → copy **install token** → `CLOUDFLARE_TUNNEL_TOKEN` in `.env`.
2. On the server: `sudo ./scripts/cloudflare-tunnel.sh install-token`
3. For **each** hostname in `.env`, add a **public hostname** pointing to **`http://127.0.0.1:80`** (same as `CLOUDFLARE_TUNNEL_ORIGIN`). Traefik routes by `Host`; do **not** point the tunnel at Immich’s pod port `2283`.
4. DNS: CNAME to the tunnel target (proxied), as shown in the tunnel UI.

```bash
./scripts/cloudflare-tunnel.sh print-dns-hints
```

Optional: `render-config` / `write-config` from `kubernetes/cloudflared-config.yml.tpl` if you run cloudflared with a config file.

**Immich mobile:** server URL = `https://<IMMICH_DOMAIN>` (same as `IMMICH_PUBLIC_URL`). Example in this repo uses `photos.*`; keep tunnel, DNS, `.env`, and app aligned.

## Stacks

| Namespace    | What                                                                                                                                                                                                                                                                |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `immich`     | Immich (Traefik `IngressRoute`, auth rate limit), Postgres, Redis, ML (HPA max 1 by default), library S3 sidecar; weekly `pg_dump` CronJob → S3                                                                                                                     |
| `monitoring` | Prometheus, Grafana, Alertmanager (basic auth on Prometheus + alerts ingresses), Loki, Promtail, node-exporter, kube-state-metrics, blackbox, optional Cloudflare exporter, local `fail2ban-security-exporter` DaemonSet (needs host fail2ban) |

Grafana dashboards include community Immich / k8s / Traefik JSON, a **Service Reliability** board for blackbox-monitored services, plus a small **Server security signals** board (`f2b_*` + node/kube metrics) with Loki available for raw pod and auth logs.

### Cluster logs with Loki

`./scripts/k8s.sh apply monitoring` now also deploys Loki + Promtail. Promtail tails Kubernetes pod logs cluster-wide and host `/var/log/auth.log`, and Grafana provisions a `Loki` datasource automatically.

Useful Explore queries:

```logql
{job="node-authlog"} |= "sshd"
{namespace="immich"} |= "error"
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
| `./scripts/k8s.sh restart`                          | Rollout restart deployments in `immich`, `monitoring` |
| `./scripts/k8s.sh backup-suspend` / `backup-resume` | Immich pgdump CronJob                                 |
| `./scripts/restore-immich-from-s3.sh`               | Restore DB from S3 (see script header)                |
| `./scripts/snapshot-k3s-s3.sh`                      | k3s etcd snapshot → S3 (server, root)                 |
| `./scripts/k8s.sh delete immich` \| `monitoring`    | Destructive                                           |

More flags: `./scripts/k8s.sh` (no args) or read `k8s.sh` usage block.

## Health checks

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "https://<IMMICH_DOMAIN>/api/server/ping"
curl -sS -o /dev/null -w '%{http_code}\n' "https://<GRAFANA_DOMAIN>/api/health"
curl -sS -o /dev/null -w '%{http_code}\n' -u 'USER:PASS' "https://<PROMETHEUS_DOMAIN>/-/ready"
curl -sS -o /dev/null -w '%{http_code}\n' -u 'USER:PASS' "https://<ALERTS_DOMAIN>/-/healthy"
```

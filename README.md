# home-server

k3s on a VPS: Immich, Prometheus/Grafana/Alertmanager, Uptime Kuma, S3 backups, Cloudflare Tunnel in front of Traefik.

## Contents

- [Terraform](#terraform) — VPS
- [Bootstrap](#bootstrap) — k3s + tooling
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

- **URLs:** `IMMICH_DOMAIN`, `IMMICH_PUBLIC_URL`, `GRAFANA_DOMAIN`, `GRAFANA_ROOT_URL`, `PROMETHEUS_DOMAIN`, `ALERTS_DOMAIN`, `UPTIME_KUMA_DOMAIN`
- **Secrets:** `IMMICH_DB_PASSWORD`, `GRAFANA_ADMIN_*`, `ALERTS_BASIC_AUTH_*` (Alertmanager ingress)
- **S3 backups:** `BACKUP_S3_BUCKET`, `BACKUP_S3_PREFIX`, `AWS_REGION`, optional `BACKUP_S3_ACCESS_KEY_ID` / `BACKUP_S3_SECRET_ACCESS_KEY` for `./scripts/k8s.sh secrets`
- **Tunnel:** `CLOUDFLARE_TUNNEL_TOKEN`, `CLOUDFLARE_TUNNEL_ORIGIN` (default `http://127.0.0.1:80` → Traefik)
- **Optional:** `CLOUDFLARE_EXPORTER_API_TOKEN`, `CLOUDFLARE_ACCOUNT_IDS` for the Cloudflare exporter

Domains in `.env` should match tunnel public hostnames + DNS.

```bash
./scripts/k8s.sh env-check
./scripts/k8s.sh secrets
./scripts/k8s.sh apply all          # needs S3 vars; includes immich, backup cron, monitoring, uptime-kuma
# or: ./scripts/k8s.sh deploy all
```

Partial: `apply immich` | `apply immich-backup` | `apply monitoring` | `apply uptime-kuma`. Preview: `diff all`.

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

| Namespace     | What                                                                                                                                                                                                                                                 |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `immich`      | Immich (Traefik `IngressRoute`, auth rate limit), Postgres, Redis, ML (HPA max 1 by default), library S3 sidecar; weekly `pg_dump` CronJob → S3                                                                                                      |
| `monitoring`  | Prometheus, Grafana, Alertmanager (basic auth on alerts ingress), node-exporter, kube-state-metrics, blackbox, optional Cloudflare exporter, [fail2ban-exporter](https://github.com/hectorjsmith/fail2ban-prometheus-exporter) (needs host fail2ban) |
| `uptime-kuma` | [Uptime Kuma](https://github.com/louislam/uptime-kuma), SQLite on RWO PVC                                                                                                                                                                            |

Grafana dashboards include community Immich / k8s / Traefik JSON plus a small **Server security signals** board (`f2b_*` + node/kube metrics; not raw auth logs).

## Scripts

| Command                                                           | Purpose                                                              |
| ----------------------------------------------------------------- | -------------------------------------------------------------------- |
| `./scripts/k8s.sh restart`                                        | Rollout restart deployments in `immich`, `monitoring`, `uptime-kuma` |
| `./scripts/k8s.sh backup-suspend` / `backup-resume`               | Immich pgdump CronJob                                                |
| `./scripts/restore-immich-from-s3.sh`                             | Restore DB from S3 (see script header)                               |
| `./scripts/snapshot-k3s-s3.sh`                                    | k3s etcd snapshot → S3 (server, root)                                |
| `./scripts/k8s.sh delete immich` \| `monitoring` \| `uptime-kuma` | Destructive                                                          |

More flags: `./scripts/k8s.sh` (no args) or read `k8s.sh` usage block.

## Health checks

```bash
curl -sS -o /dev/null -w '%{http_code}\n' "https://<IMMICH_DOMAIN>/api/server/ping"
curl -sS -o /dev/null -w '%{http_code}\n' "https://<GRAFANA_DOMAIN>/api/health"
curl -sS -o /dev/null -w '%{http_code}\n' "https://<PROMETHEUS_DOMAIN>/-/ready"
curl -sS -o /dev/null -w '%{http_code}\n' -u 'USER:PASS' "https://<ALERTS_DOMAIN>/-/healthy"
curl -sS -L -o /dev/null -w '%{http_code}\n' "https://<UPTIME_KUMA_DOMAIN>/"
```

# home-server

my home server

## 1. Provision the VPS (Terraform)

```bash
cd terraform
cp terraform.tfvars.example envs/prod.tfvars
# edit envs/prod.tfvars (token, SSH allowlist, etc.) — keep it out of git if it has secrets
terraform init
terraform apply -var-file=envs/prod.tfvars
```

## 2. Bootstrap the server (k3s, cloudflared, tooling)

```bash
cd /projects
git clone https://github.com/luke-h1/home-server
cd home-server
sudo ./scripts/setup-server
```

Verify:

```bash
systemctl status k3s
kubectl get nodes
```

## 3. Configure `kubernetes/.env`

```bash
cp kubernetes/.env.example kubernetes/.env
```

Edit **at least**:

| Area              | Variables                                                                                                                                                                           |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ingress / URLs    | `IMMICH_DOMAIN`, `IMMICH_PUBLIC_URL`, `GRAFANA_DOMAIN`, `GRAFANA_ROOT_URL`, `PROMETHEUS_DOMAIN`, `ALERTS_DOMAIN`                                                                    |
| Secrets           | `IMMICH_DB_PASSWORD`, `GRAFANA_ADMIN_USER`, `GRAFANA_ADMIN_PASSWORD`, `ALERTS_BASIC_AUTH_USER`, `ALERTS_BASIC_AUTH_PASSWORD` (Traefik basic auth on `ALERTS_DOMAIN` / Alertmanager) |
| S3 backups        | `BACKUP_S3_BUCKET`, `BACKUP_S3_PREFIX`, `AWS_REGION` — plus `BACKUP_S3_ACCESS_KEY_ID` / `BACKUP_S3_SECRET_ACCESS_KEY` for `k8s.sh secrets` (see below)                              |
| Cloudflare Tunnel | `CLOUDFLARE_TUNNEL_TOKEN` (from Zero Trust → Tunnels → install token) and `CLOUDFLARE_TUNNEL_ORIGIN` (`http://127.0.0.1:80` with default k3s Traefik)                               |
| Optional metrics  | `CLOUDFLARE_EXPORTER_API_TOKEN`, `CLOUDFLARE_ACCOUNT_IDS` for Grafana/Prometheus Cloudflare Worker metrics                                                                          |

Domains in `.env` must match what you configure in Cloudflare (tunnel hostnames and DNS).

## 4. Deploy Kubernetes workloads

From the repo root, with `kubectl` and `envsubst` available:

```bash
./scripts/k8s.sh env-check
./scripts/k8s.sh secrets          # creates immich + monitoring secrets; S3 backup creds if keys set in .env
./scripts/k8s.sh apply all       # immich + immich-backup + monitoring (requires backup S3 vars)
```

or

```bash
./scripts/k8s.sh deploy all
```

**Partial applies:**

- `./scripts/k8s.sh apply immich` — Immich stack only (no backup CronJob unless you apply that separately).
- `./scripts/k8s.sh apply immich-backup` — Postgres dump CronJob (needs S3 env in `.env`).
- `./scripts/k8s.sh apply monitoring` — Prometheus (scrapes **Traefik** in `kube-system:9100`, **immich-server** `:8081/metrics` when telemetry is enabled), Grafana, Alertmanager, **blackbox-exporter** (HTTPS probes), optional Cloudflare exporter.

Use `./scripts/k8s.sh diff all` to preview manifests.

**Backups:** Postgres dump and library `aws s3 sync` run on a **weekly schedule (Friday 00:00 UTC)** by default. Library sync runs in the **immich-server** sidecar (same pod as Immich; required because the library PVC is ReadWriteOnce).

## 5. Cloudflare Tunnel (token + CLI)

Traffic must reach **Traefik on the node** at `CLOUDFLARE_TUNNEL_ORIGIN` (default `http://127.0.0.1:80`). Host-based routing uses the domains in `kubernetes/.env`.

1. Cloudflare **Zero Trust** → **Networks** → **Tunnels** → **Create a tunnel** → choose **Docker** or **Cloudflared** install flow and copy the **token** (looks like a long JWT).
2. Set `CLOUDFLARE_TUNNEL_TOKEN` in `kubernetes/.env` (or export it for a one-off install).
3. On the server as root, install the systemd service (wraps `cloudflared service install`):

   ```bash
   sudo ./scripts/cloudflare-tunnel.sh install-token
   ```

4. Still in **Zero Trust** → your tunnel → **Public hostnames** (or **Route traffic** → **Published application**): add **one published app per hostname** you use in `kubernetes/.env` (`IMMICH_DOMAIN`, `GRAFANA_DOMAIN`, `PROMETHEUS_DOMAIN`, `ALERTS_DOMAIN`). For each row, use the table below.

### Zero Trust “Route traffic” form (what to enter)

For **each** published application (Immich, Grafana, etc.):

| Field            | Value                                                                                                                                                                                                                    |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Subdomain**    | For Immich use **`photos`** if the app is at **`photos.lhowsam.com`** (subdomain + zone must match **`IMMICH_DOMAIN`** in `kubernetes/.env` and the Traefik host — do not use `images` if your tunnel/DNS use `photos`). |
| **Domain**       | Your Cloudflare zone (e.g. `example.com`)                                                                                                                                                                                |
| **Path**         | Leave **empty** unless you intentionally want a path prefix                                                                                                                                                              |
| **Service type** | **HTTP**                                                                                                                                                                                                                 |
| **Service URL**  | **`http://127.0.0.1:80`** (same as `CLOUDFLARE_TUNNEL_ORIGIN`; `http://localhost:80` is equivalent)                                                                                                                      |

Use the **same** service URL for every hostname. **Do not** point the tunnel at Immich’s container port **`2283`** — Traefik listens on **port 80** on the node and routes to the correct backend using the **`Host`** header from the public hostname you configured.

Repeat the published application once per hostname (Immich, Grafana, Prometheus, Alertmanager).

5. **DNS:** for each hostname, use the **CNAME** target Cloudflare shows for the tunnel (proxied). You do not need an A record to the VPS public IP for those names when using the tunnel only.

**Hostnames checklist (reference):**

```bash
./scripts/cloudflare-tunnel.sh print-dns-hints
```

### Immich mobile app

Use **`https://<IMMICH_DOMAIN>`** as the server URL (same as `IMMICH_PUBLIC_URL`). This repo’s example uses **`photos.lhowsam.com`**, not `images.*`, so the tunnel published hostname, DNS, `.env`, and app must all agree on **`photos`**. Do not rely on the raw VPS IP/port when using the tunnel and `allow_public_http = false`.

## 6. What gets installed

| Component                            | Namespace    | Notes                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| ------------------------------------ | ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Immich (server, Postgres, Redis, ML) | `immich`     | Traefik `IngressRoute` for `IMMICH_DOMAIN`; rate limit on `/api/auth` + `/api/oauth`; **`IMMICH_TELEMETRY_INCLUDE=all`** in `immich-env` exposes **Prometheus metrics on port 8081** ([Immich monitoring](https://docs.immich.app/features/monitoring))                                                                                                                                                                                                                                                                   |
| Immich DB backup CronJob             | `immich`     | Weekly `pg_dump` → S3                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Library backup                       | `immich`     | Sidecar on `immich-server`: weekly `aws s3 sync` → `s3://…/library/`                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| Prometheus, Grafana, Alertmanager    | `monitoring` | Separate ingress hostnames; scrapes **Immich** metrics (`immich-server.immich:8081`) with labels expected by community dashboards; **node-exporter**, **kube-state-metrics**, **blackbox-exporter**; cAdvisor via API server for [K8S dashboard 15661](https://grafana.com/grafana/dashboards/15661-k8s-dashboard-en-20250125/); Grafana **Applications**: [Immich Overview 22555](https://grafana.com/grafana/dashboards/22555-immich-overview/); **Infrastructure**: Node Exporter, kube-state-metrics, Blackbox, 15661 |
| Cloudflare exporter (optional)       | `monitoring` | Needs `CLOUDFLARE_EXPORTER_API_TOKEN` in `k8s.sh secrets`                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |

## 7. Operations (reference)

| Task                        | Command / script                                                            |
| --------------------------- | --------------------------------------------------------------------------- |
| Restart app deployments     | `./scripts/k8s.sh restart` or `./scripts/k8s.sh upgrade-apps`               |
| Suspend / resume DB CronJob | `./scripts/k8s.sh backup-suspend` / `backup-resume`                         |
| Restore Postgres from S3    | `./scripts/restore-immich-from-s3.sh` (see script header)                   |
| k3s etcd snapshot → S3      | `./scripts/snapshot-k3s-s3.sh` (on server, root; separate from app backups) |

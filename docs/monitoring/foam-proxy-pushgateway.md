# Foam Proxy Pushgateway Ingestion

## Current state

Validated over SSH on `root@204.168.194.176` on 2026-04-21:

- The live `monitoring` namespace already has `pushgateway` running on port `9091`.
- Prometheus had not reloaded its config yet, so `pushgateway` was not being scraped even though the ConfigMap already contained a `pushgateway` job.
- `otel-collector` was still deployed and exposed even though the target state is Pushgateway-only ingestion.

## What this repo now adds

- A repo-managed `pushgateway` Deployment and Service in `monitoring`.
- Traefik basic auth on the Pushgateway ingress using the `pushgateway-basic-auth` secret.
- A Prometheus scrape job for `pushgateway:9091` with `honor_labels: true`.
- A Grafana `foam-proxy` dashboard description aligned to Pushgateway ingestion.
- Removal of the in-cluster OTEL collector manifests and OTEL dashboard.

## Required app settings

Set the `foam-proxy` Lambda environment to:

- `PUSHGATEWAY_URL=https://${PUSHGATEWAY_DOMAIN}`
- `PUSHGATEWAY_AUTH_HEADER=Authorization=Basic <base64(username:password)>`

Set the home-server `.env` values to:

- `PUSHGATEWAY_DOMAIN`
- `PUSHGATEWAY_BASIC_AUTH_USER`
- `PUSHGATEWAY_BASIC_AUTH_PASSWORD`

Then run:

```bash
./scripts/k8s.sh secrets
./scripts/k8s.sh apply monitoring
./scripts/k8s.sh restart monitoring
```

## Validation checks

```bash
kubectl -n monitoring get deploy pushgateway
kubectl -n monitoring get svc pushgateway
kubectl -n monitoring exec deploy/prometheus -- wget -qO- 'http://127.0.0.1:9090/api/v1/query?query=up{job="pushgateway"}'
kubectl -n monitoring exec deploy/prometheus -- wget -qO- 'http://127.0.0.1:9090/api/v1/label/__name__/values' | tr ',' '\n' | grep foam_proxy
kubectl -n monitoring get deploy otel-collector
```

Expected result:

- `pushgateway` is `Available`.
- Prometheus reports `up{job="pushgateway"} == 1`.
- Prometheus contains `foam_proxy_requests_total`, `foam_proxy_request_duration_seconds_bucket`, `foam_proxy_twitch_requests_total`, `foam_proxy_twitch_request_duration_seconds_bucket`, and `foam_proxy_config_info`.
- `otel-collector` is not found.

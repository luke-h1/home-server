# Foam Proxy OTEL Ingestion

## Current state

Validated over SSH on `root@204.168.194.176` on 2026-04-20:

- The live `monitoring` namespace has `prometheus`, `grafana`, and `loki`, but no OpenTelemetry Collector, Grafana Alloy, Grafana Agent, or `vmagent`.
- The live Prometheus config only contains scrape jobs. It does not contain `remote_write`, `remote_read`, federation, or an OTLP receiver.
- Querying the live Prometheus API for metric names returned no `foam_proxy_*` series.

That means the pre-change `home-server` setup was not ingesting `foam-proxy` OTLP metrics at all.

## What this repo now adds

- An in-cluster OpenTelemetry Collector that receives OTLP over HTTP on port `4318`.
- Basic auth on the collector receiver using the `otel-collector-basic-auth` Kubernetes secret.
- A Prometheus exporter on the collector on port `9464`.
- A Prometheus scrape job for `otel-collector:9464`.
- A Grafana application dashboard for `foam_proxy_*` metrics.

## Required app settings

Set the `foam-proxy` OTEL environment to:

- `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=https://${OTEL_INGEST_DOMAIN}/v1/metrics`
- `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`
- `OTEL_EXPORTER_OTLP_HEADERS=Authorization=Basic <base64(username:password)>`

Use the same username and password you place in `kubernetes/.env` as:

- `OTEL_OTLP_BASIC_AUTH_USER`
- `OTEL_OTLP_BASIC_AUTH_PASSWORD`

Then run:

```bash
./scripts/k8s.sh secrets
./scripts/k8s.sh apply monitoring
```

## Validation checks

After deploy, check the collector and scrape path:

```bash
kubectl -n monitoring get deploy otel-collector
kubectl -n monitoring get svc otel-collector
kubectl -n monitoring logs deploy/otel-collector --tail=100
kubectl -n monitoring exec deploy/prometheus -- wget -qO- 'http://127.0.0.1:9090/api/v1/targets'
kubectl -n monitoring exec deploy/prometheus -- wget -qO- 'http://127.0.0.1:9090/api/v1/label/__name__/values' | tr ',' '\n' | grep foam_proxy
```

Expected result:

- The `otel-collector` target is `up`.
- Prometheus contains `foam_proxy_requests_total`, `foam_proxy_request_duration_seconds_bucket`, `foam_proxy_twitch_requests_total`, `foam_proxy_twitch_request_duration_seconds_bucket`, and `foam_proxy_config_info`.

## PromQL

Requests per second by app:

```promql
sum by (app) (
  rate(foam_proxy_requests_total{service_name="foam-proxy"}[5m])
)
```

Inbound error rate percentage by app:

```promql
100 *
sum by (app) (
  rate(foam_proxy_requests_total{
    service_name="foam-proxy",
    status_code_class=~"4xx|5xx"
  }[5m])
)
/
clamp_min(
  sum by (app) (
    rate(foam_proxy_requests_total{service_name="foam-proxy"}[5m])
  ),
  0.0001
)
```

Inbound latency p95 by app:

```promql
histogram_quantile(
  0.95,
  sum by (le, app) (
    rate(foam_proxy_request_duration_seconds_bucket{service_name="foam-proxy"}[5m])
  )
)
```

Twitch upstream requests per second by operation and outcome:

```promql
sum by (operation, outcome) (
  rate(foam_proxy_twitch_requests_total{service_name="foam-proxy"}[5m])
)
```

Twitch upstream latency p95 by operation:

```promql
histogram_quantile(
  0.95,
  sum by (le, operation) (
    rate(foam_proxy_twitch_request_duration_seconds_bucket{service_name="foam-proxy"}[5m])
  )
)
```

Current deployed build metadata:

```promql
max by (app, git_sha, environment) (
  foam_proxy_config_info{service_name="foam-proxy"}
)
```

## Grafana charts

The provisioned `Foam Proxy Overview` dashboard includes:

- Inbound requests per second
- Inbound error rate
- Inbound latency p95
- Twitch upstream requests per second
- Inbound requests by app
- Inbound error rate by app
- Inbound latency p95 by app
- Twitch upstream requests by operation and outcome
- Twitch upstream latency p95 by operation
- Current deployed build metadata

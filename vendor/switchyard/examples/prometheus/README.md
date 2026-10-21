# Switchyard observability stack

Local Prometheus, Grafana, and Tempo configuration for a Switchyard server
running on the host. It provides metric dashboards, alert rules, and an OTLP
trace backend. Pair it with
[`docs/internal/metrics_reference.md`](../../docs/internal/metrics_reference.md) for
the full metric inventory and label semantics.

## Files

| File | Purpose |
|---|---|
| `compose.yaml` | Starts Prometheus, Grafana, and Tempo, bound to loopback-only ports. |
| `prometheus.yml` | A single `scrape_configs:` entry. Targets the host's Switchyard `/metrics`. |
| `switchyard.rules.yaml` | Alert rule group implementing the operational and success-criterion alerts. Validates with `promtool check rules`. |
| `tempo.yaml` | OTLP/HTTP receiver with 48-hour local trace retention. |
| `grafana/` | Provisioned Prometheus and Tempo data sources plus the `Switchyard Overview` dashboard. |

## Local quick start

1. Start the observability services:

```bash
cd examples/prometheus
cp .env.example .env
# Set GRAFANA_ADMIN_PASSWORD in .env.
docker compose up -d
```

2. Start Switchyard with OTLP trace export. Prometheus scrapes metrics from
   `http://host.docker.internal:4000/metrics`; this is mapped to the Docker
   host on Docker Desktop and through `host-gateway` on Linux.

```bash
OTEL_SERVICE_NAME=switchyard-local \
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
cargo run --release -p switchyard-server -- --config /path/to/routes.toml --port 4000
```

`GET /metrics` is enabled by default. To disable trace export temporarily,
omit `OTEL_EXPORTER_OTLP_ENDPOINT`; metrics and the dashboard continue to
work.

3. Open Grafana at `http://127.0.0.1:3000`, authenticate with the credentials
   from `.env`, then select
   **Dashboards > Switchyard > Switchyard Routing Overview**.
   The dashboard covers request/error rate, retryable-error reduction,
   end-to-end and routing latency, endpoint traffic, token throughput, retries,
   classifier fail-open events, and upstream HTTP failures. Use its
   **Tempo trace explorer** link to inspect exported request traces.

Prometheus is available at `http://127.0.0.1:9090`. Stop and delete local
telemetry data with:

```bash
docker compose down -v
```

## Production wiring

Merge the `scrape_configs:` entry from `prometheus.yml` into your existing
Prometheus configuration, replacing its `static_configs` target with your
deployment's host, service discovery, or `kubernetes_sd_configs`. The endpoint
is plain `GET /metrics` over HTTP, without authentication, so keep it on a
trusted network.

Load the included rules after adjusting thresholds to your SLOs:

```bash
cp switchyard.rules.yaml /etc/prometheus/rules/
promtool check rules /etc/prometheus/rules/switchyard.rules.yaml
```

Then add it to Prometheus's `rule_files` and reload Prometheus. For traces,
point `OTEL_EXPORTER_OTLP_ENDPOINT` at your managed or self-hosted OTLP/HTTP
collector instead of Tempo.

## Alert tuning notes

Default thresholds and `for:` windows in `switchyard.rules.yaml` are
conservative — tuned to avoid pages during routine scrape-config rolls
or single-poll blips. Review them against your SLOs before enabling
notifications:

* `RouterOverheadHigh` fires per `algorithm` at p99 > 10 s for 15 m. It is a
  pathology detector, not a cost measurement: an algorithm that consults a
  classifier or judge spends a whole LLM call inside the routing-overhead
  histogram, so a tight millisecond bar cannot hold for one. When it fires,
  check `switchyard_algorithms_in_flight` and
  `switchyard_classifier_fail_open_total` — a hung judge target shows up in all
  three at once — then cross-check classifier traffic in `/v1/stats`.

* `RouterOverheadShareHigh` fires when more than half of end-to-end latency was
  spent choosing a target rather than answering, for 15 m. This is the portable
  form of the routing-cost criterion: it scales with your own model latency
  instead of an absolute millisecond bar, so it means the same thing on a
  passthrough route and a classifier-backed one.

* The sub-millisecond routing criterion still applies to algorithms that make no
  LLM call, but only to those. There is no shipped rule for it, because the
  algorithm names that qualify are deployment-specific. Check it per algorithm
  and add a rule narrowed to your own non-LLM algorithms:

  ```promql
  histogram_quantile(
    0.99,
    sum by (algorithm, le) (rate(switchyard_routing_overhead_ms_bucket[15m]))
  ) > 1.0
  ```

* `RouterErrorRateNotReducing` compares two ratios, so it holds off until at
  least 10 client responses land in the window. Below that the comparison is
  noise rather than evidence. Raise the floor on a busy deployment.

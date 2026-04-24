# Service Initialization Timelines

Expected startup durations for each service after `docker compose up -d`. These are normal — do not restart containers before the listed ready time.

## Apache Kafka® Brokers (KRaft Election)

| Elapsed | Status | Notes |
|---------|--------|-------|
| T+0–30s | Container starting | JVM initializing |
| T+30–120s | KRaft controller election | Expected — not hung |
| T+120–300s | Election finalizing | Some port timeouts are normal during quorum negotiation |
| T+300s+ | **Ready** | Port 9093 listening; brokers accepting connections |

**Check readiness:**
```bash
echo > /dev/tcp/localhost/9093 2>/dev/null && echo "Broker ready" || echo "Not ready"
```

All three brokers must be ready before deploying connectors.

## Schema Registry

| Elapsed | Status | Notes |
|---------|--------|-------|
| T+0–15s | Container starting | Depends on brokers being reachable |
| T+15–45s | Connecting to Kafka | Retries if brokers not yet ready |
| T+45s+ | **Ready** | Port 8081 responding |

**Check readiness:**
```bash
curl -sf http://localhost:8081/subjects && echo "Schema Registry ready"
```

## Connect Workers (REST API)

| Elapsed | Status | Notes |
|---------|--------|-------|
| T+0–30s | JVM starting | Memory allocation |
| T+30–60s | Plugins loading | Debezium + JDBC connectors scanning |
| T+60–120s | REST API starting | May return 503 — normal |
| T+120s+ | **Ready** | Responds to `curl http://localhost:8083/connectors` |

**Check readiness:**
```bash
curl -sf http://localhost:8083/connectors && echo "Connect Worker 1 ready"
curl -sf http://localhost:8084/connectors && echo "Connect Worker 2 ready"
```

> **Note:** The Connect image includes Debezium SQL Server, Debezium PostgreSQL, and JDBC Sink connectors. Scanning the plugin path on startup takes 30–60 seconds.

## Control Center

| Elapsed | Status | Notes |
|---------|--------|-------|
| T+0–60s | JVM + Kafka Streams starting | Depends on brokers |
| T+60–180s | Internal topics being created | ~48 `_confluent-controlcenter-*` topics |
| T+3–5m | **Ready** | Port 9021 responding |

Control Center creates its internal topics on first start. Subsequent starts are faster.

> **If Control Center crash-loops**, see the [MetricsAggregateStore issue](troubleshooting.md#control-center-crash-loop-metricsaggregatestore-partition-mismatch) in troubleshooting.md.

## ksqlDB

| Elapsed | Status | Notes |
|---------|--------|-------|
| T+0–30s | JVM starting | |
| T+30–90s | Connecting to Kafka, Schema Registry | |
| T+90s+ | **Ready** | Port 8088 responding |

## Prometheus + Grafana

Both start within 15–30 seconds. Grafana dashboards may show "No data" until Prometheus completes its first scrape cycle (15 seconds after startup).

## Full Parallel Startup Timeline

When starting all nodes simultaneously (Option B in [README-DEPLOYMENT.md](../README-DEPLOYMENT.md)):

| Time | Event |
|------|-------|
| T+0 | All `5-start-node.sh` commands sent |
| T+1–2m | Brokers electing KRaft leader |
| T+3–5m | All brokers ready (port 9092/9093) |
| T+5–8m | Schema Registry + Connect workers initializing |
| T+10m | Connect REST API ready (8083, 8084) |
| T+15–20m | Control Center ready (9021) |

Proceed to Phase 6 (deploy connectors) once all three brokers and both Connect workers are ready.

---

*Apache, Apache Kafka, Kafka, and the Kafka logo are trademarks of The Apache Software Foundation.*

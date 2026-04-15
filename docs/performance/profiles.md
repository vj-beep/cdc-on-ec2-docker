# Deployment Tuning Profiles

Two pre-built tuning profiles ship with this repo, optimized for different phases of a CDC deployment.

## Profiles at a Glance

| Profile | File | When to use | Goal |
|---------|------|-------------|------|
| **snapshot** | `profiles/.env.snapshot` | Initial deployment, bulk data load | Maximum throughput |
| **streaming** | `profiles/.env.streaming` | After snapshot completes, steady-state CDC | Minimum latency |

## Switching Profiles

Use the helper script — it merges the selected profile into your local `.env`, distributes it to all nodes via SSM, and restarts all services:

```bash
# Switch to streaming (after initial snapshot finishes)
./scripts/on-demand-switch-profile.sh streaming

# Switch back to snapshot (e.g., to re-snapshot new tables)
./scripts/on-demand-switch-profile.sh snapshot
```

The script shows a diff of all changes before applying and asks for confirmation.

> **After every profile switch, redeploy connectors:**
> ```bash
> ./scripts/6-deploy-connectors.sh
> ```
> Connector tuning values (`max.batch.size`, `max.queue.size`, `batch.size`, `poll.interval.ms`, etc.) are applied at deploy time via `.env` substitution — restarting the Connect worker alone does not update them. The script reminds you of this after each switch.

## When to Switch

| Trigger | Action |
|---------|--------|
| Fresh deployment | Default — streaming profile is pre-configured |
| Before initial bulk data load | Switch to snapshot profile |
| Snapshot completes (connector status `STREAMING`) | Switch back to streaming profile |
| Adding new tables that need full snapshot | Switch back to snapshot, reconfigure connector |

Check whether snapshot is complete:

```bash
curl -s http://localhost:8083/connectors/debezium-sqlserver-source/status \
  | jq '.tasks[].state'
# "RUNNING" after initial scan = snapshot done, streaming active
```

## Key Differences

### Connect Worker Settings

| Setting | Snapshot | Streaming |
|---------|----------|-----------|
| `CONNECT_OFFSET_FLUSH_INTERVAL_MS` | 60,000 (60s) | **1,000 (1s)** |
| `CONNECT_CONSUMER_FETCH_MIN_BYTES` | 1,048,576 (1 MB) | **1** |
| `CONNECT_CONSUMER_FETCH_MAX_WAIT_MS` | 500 ms | **10 ms** |
| `CONNECT_PRODUCER_LINGER_MS` | 100 ms | **5 ms** |
| `CONNECT_PRODUCER_BATCH_SIZE` | 512 KB | 32 KB |
| `CONNECT_CONSUMER_MAX_POLL_RECORDS` | 5000 | 500 |
| `CONNECT_PRODUCER_COMPRESSION_TYPE` | snappy | lz4 |

### SQL Server Source Connector

| Setting | Snapshot | Streaming |
|---------|----------|-----------|
| `SQLSERVER_SOURCE_SNAPSHOT_MODE` | `initial` | `no_data` |
| `SQLSERVER_SOURCE_MAX_BATCH_SIZE` | 4096 | 256 |
| `SQLSERVER_SOURCE_POLL_INTERVAL_MS` | 100 | 50 |
| `CDC_CAPTURE_MAXTRANS` | 10000 | 50 |

### Aurora PG Source Connector

| Setting | Snapshot | Streaming |
|---------|----------|-----------|
| `AURORA_SOURCE_SNAPSHOT_MODE` | `initial` | `no_data` |
| `AURORA_SOURCE_MAX_BATCH_SIZE` | 4096 | 256 |
| `AURORA_SOURCE_POLL_INTERVAL_MS` | 100 | 50 |

### JDBC Sink Connectors

| Setting | Snapshot | Streaming |
|---------|----------|-----------|
| `JDBC_SINK_AURORA_BATCH_SIZE` | 5000 | 500 |
| `JDBC_SINK_SQLSERVER_BATCH_SIZE` | 5000 | 500 |
| `JDBC_SINK_AURORA_TASKS_MAX` | 4 | 2 |
| `JDBC_SINK_SQLSERVER_TASKS_MAX` | 1 | 1 |

For full tuning rationale and advanced configuration, see [best-practices.md](best-practices.md).

---

*Apache, Apache Kafka, Kafka, and the Kafka logo are trademarks of The Apache Software Foundation.*

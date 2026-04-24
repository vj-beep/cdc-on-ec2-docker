# Deployment Tuning Profiles

Two pre-built tuning profiles ship with this repo, optimized for different phases of a CDC deployment.

## Profiles at a Glance

| Profile | File | When to use | Goal |
|---------|------|-------------|------|
| **snapshot** | `profiles/.env.snapshot` | Initial deployment, bulk data load | Maximum throughput |
| **streaming** | `profiles/.env.streaming` | After snapshot completes, steady-state CDC | Minimum latency |

## Switching Profiles

Use the helper script — it merges the selected profile into your local `.env`, distributes it to all nodes, and restarts all services:

```bash
./scripts/on-demand-switch-profile.sh snapshot    # Before initial data load
./scripts/on-demand-switch-profile.sh streaming   # After snapshot completes
```

The script shows a diff of all changes before applying and asks for confirmation.

> **After every profile switch, redeploy connectors:**
> ```bash
> ./scripts/6-deploy-connectors.sh
> ```
> Connector tuning values (`max.batch.size`, `max.queue.size`, `batch.size`, `poll.interval.ms`, etc.) are applied at deploy time via `.env` substitution — restarting the Connect worker alone does not update them. The script reminds you of this after each switch.

## Operational Runbooks

### Switching to Snapshot Mode (for initial bulk load)

When you have existing data in your source database and need Debezium to capture it all via `snapshot.mode=initial`, follow this sequence:

```
Step 1 — Stop connectors
         Prevents CDC capture during profile switch and avoids partial offsets.

  ./scripts/ops-stop-all-connectors.sh -y

Step 2 — Clear Kafka state (offsets, topics, schemas)
         Required so Debezium sees no stored offsets and triggers a fresh snapshot.
         If offsets exist, Debezium skips the snapshot even with snapshot.mode=initial.

  ./scripts/teardown-reset-kafka.sh -y

Step 3 — Switch to snapshot profile
         Tunes batching, compression, and queue sizes for throughput.
         Distributes .env to all nodes and restarts services.

  ./scripts/on-demand-switch-profile.sh snapshot

Step 4 — Wait for Connect REST APIs (~90-120s after restart)

  curl -s http://<connect-ip>:8083/connectors   # Should return []
  curl -s http://<connect-ip>:8084/connectors   # Should return []

Step 5 — Deploy connectors (triggers snapshot)
         Connectors start with no offsets → snapshot.mode=initial takes effect.

  ./scripts/6-deploy-connectors.sh

Step 6 — Monitor snapshot progress

  # Check connector state (RUNNING = actively snapshotting or streaming)
  curl -s http://<connect-ip>:8083/connectors/debezium-sqlserver-source/status | jq '.tasks[].state'

  # Watch for "Snapshot completed" in Connect logs
  ssh <connect-node> "cd ~/cdc-on-ec2-docker && docker compose logs -f connect-1 2>&1 | grep -i snapshot"

  # Monitor consumer lag in Grafana or via CLI
  kafka-consumer-groups --bootstrap-server <broker>:9092 --describe --group connect-jdbc-sink-aurora
```

**Timing note:** Snapshot duration depends on data volume and RDS IOPS. A 500 GB SQL Server database takes approximately 60-100 hours to snapshot through Debezium on gp2 storage.

### Switching Back to Streaming Mode (after snapshot completes)

Once the source connector transitions from snapshot to streaming (visible in logs as "Snapshot completed"), switch to low-latency tuning:

```
Step 1 — Verify snapshot is complete

  # Check Connect logs for completion
  ssh <connect-node> "cd ~/cdc-on-ec2-docker && docker compose logs connect-1 2>&1 | grep -i 'snapshot completed'"

  # Connector task should be RUNNING (not FAILED)
  curl -s http://<connect-ip>:8083/connectors/debezium-sqlserver-source/status | jq '.tasks[].state'

Step 2 — Switch to streaming profile
         Reduces batch sizes, linger, and queue depths for sub-second latency.
         Distributes .env and restarts all services.

  ./scripts/on-demand-switch-profile.sh streaming

Step 3 — Redeploy connectors with new tuning
         Connectors resume from stored offsets — no re-snapshot.

  ./scripts/6-deploy-connectors.sh

Step 4 — Verify connectors are RUNNING

  curl -s http://<connect-ip>:8083/connectors?expand=status | jq '.[].status.connector.state'
  curl -s http://<connect-ip>:8084/connectors?expand=status | jq '.[].status.connector.state'
```

### Quick Profile Check

Verify which profile is active on the cluster:

```bash
# From the jumpbox (reads .env)
./scripts/ops-node-status-ssm.sh
# Shows "● Streaming" or "● Snapshot" at the top

# Or check directly
grep CONNECT_CONSUMER_FETCH_MIN_BYTES .env
# =1 → Streaming | =1048576 → Snapshot
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

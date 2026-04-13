# Deployment Tuning Profiles

Two pre-built tuning profiles ship with this repo, optimized for different phases of a CDC deployment.

## Profiles at a Glance

| Profile | File | When to use | Goal |
|---------|------|-------------|------|
| **snapshot** | `profiles/.env.snapshot` | Initial deployment, bulk data load | Maximum throughput |
| **streaming** | `profiles/.env.streaming` | After snapshot completes, steady-state CDC | Minimum latency |

## Switching Profiles

Use the helper script — it merges the selected profile into your local `.env`, distributes it to all nodes via SSM, and restarts services in order:

```bash
# Switch to streaming (after initial snapshot finishes)
./scripts/on-demand-switch-profile.sh streaming

# Switch back to snapshot (e.g., to re-snapshot new tables)
./scripts/on-demand-switch-profile.sh snapshot
```

The script shows a diff of all changes before applying and asks for confirmation.

## When to Switch

| Trigger | Action |
|---------|--------|
| Deployment complete, snapshot starting | Default — snapshot profile is pre-configured |
| Connector status changes from `SNAPSHOT` to `STREAMING` | Switch to streaming profile |
| Adding new tables that need full snapshot | Switch back to snapshot, reconfigure connector |

Check whether snapshot is complete:

```bash
curl -s http://localhost:8083/connectors/debezium-sqlserver-source/status \
  | jq '.tasks[].state'
# "RUNNING" after initial scan = snapshot done, streaming active
```

## Key Differences

| Setting | Snapshot | Streaming |
|---------|----------|-----------|
| `DEBEZIUM_SNAPSHOT_MODE` | `initial` | `no_data` |
| `JDBC_SINK_BATCH_SIZE` | 5000 | 500 |
| `JDBC_SINK_TASKS_MAX` | 4 | 2 |
| `CONNECT_PRODUCER_LINGER_MS` | 100 ms | 5 ms |
| `CONNECT_PRODUCER_BATCH_SIZE` | 512 KB | 16 KB |
| `CONNECT_CONSUMER_MAX_POLL_RECORDS` | 5000 | 500 |
| `CONNECT_PRODUCER_COMPRESSION_TYPE` | snappy | lz4 |

For full tuning rationale and advanced configuration, see [TUNING-BEST-PRACTICES.md](TUNING-BEST-PRACTICES.md).

---

*Apache, Apache Kafka, Kafka, and the Kafka logo are trademarks of The Apache Software Foundation.*

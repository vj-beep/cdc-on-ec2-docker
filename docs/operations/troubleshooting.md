# Troubleshooting & Diagnostics

Common issues, diagnostic commands, and solutions for the CDC deployment.

## Quick Links

- **Service startup delays?** → See [../operations/startup.md](../operations/startup.md) for expected timelines
- **Common operations?** → See [../reference/cheat-sheet.md](../reference/cheat-sheet.md) for quick commands
- **Tuning & performance?** → See [../performance/profiles.md](../performance/profiles.md) for profile switching
- **Service health check?** → Use `./scripts/ops-health-check.sh` or [../reference/cheat-sheet.md](../reference/cheat-sheet.md)

---

## Quick Diagnostics

Before diving into specific issues, gather baseline information:

```bash
# Connector status — forward cluster (port 8083)
curl -s http://localhost:8083/connectors | jq -r '.[]' | while read c; do
  echo "=== $c ==="
  curl -s http://localhost:8083/connectors/$c/status | jq '.connector.state, .tasks[].state'
done

# Connector status — reverse cluster (port 8084)
curl -s http://localhost:8084/connectors | jq -r '.[]' | while read c; do
  echo "=== $c ==="
  curl -s http://localhost:8084/connectors/$c/status | jq '.connector.state, .tasks[].state'
done

# Consumer group lag
kafka-consumer-groups --bootstrap-server ${BROKER_1_IP}:9092 --describe --all-groups

# Broker cluster health
kafka-metadata --snapshot /data/kafka/kraft-combined-logs/__cluster_metadata-0/00000000000000000000.log --cluster-id

# Docker container status (use the overlay file for the node you're on)
docker compose -f docker-compose.yml -f docker-compose.broker1.yml ps          # Node 1
docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml ps  # Node 4

# Connect worker logs (last 100 lines)
docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml logs --tail 100 connect-1 connect-2
```

## Common Issues

### Connector Won't Start / Fails Immediately

**Symptoms:** Task state is `FAILED` immediately after deployment.

**Diagnose:**
```bash
# Get the error trace
curl -s http://localhost:8083/connectors/<name>/status | jq '.tasks[].trace'
```

**Common causes and fixes:**

| Error | Cause | Fix |
|-------|-------|-----|
| `Connection refused` | Database unreachable | Check security groups, DB hostname/port, VPC routing |
| `Login failed` | Wrong credentials | Verify `${SQLSERVER_USER}/${SQLSERVER_PASSWORD}` or `${AURORA_USER}/${AURORA_PASSWORD}` in `.env` |
| `CDC is not enabled` | SQL Server CDC not configured | Run `EXEC sys.sp_cdc_enable_db` and `sys.sp_cdc_enable_table` |
| `replication slot does not exist` | PostgreSQL replication not configured | Create replication slot: `SELECT pg_create_logical_replication_slot('debezium', 'pgoutput');` |
| `NoSuchMethodError: KafkaConsumer.poll(long)` | Debezium version too old for CP 8.0.0 | Upgrade to Debezium 3.2.6+ in `connect/Dockerfile` and rebuild image |
| `Unable to determine Dialect without JDBC metadata` | JDBC sink can't connect to target DB (credentials or driver) | Check credentials in connector config; for RDS SQL Server use admin user (cdc_reader has orphaned SID) |
| `No suitable driver` | JDBC driver missing from Connect classpath | Verify `connect/jars/mssql-jdbc-12.4.2.jre11.jar` exists and is mounted into the container |
| `Schema Registry not available` | Schema Registry not running or unreachable | Check Schema Registry on Node 4: `curl http://${CONNECT_1_IP}:8081/subjects` |
| `org.apache.kafka.connect.errors.ConnectException: Invalid value` | Bad connector config | Review the full trace; usually a typo in config property names |
| `message.key.columns value is invalid` | `${VAR}` literal not substituted in connector JSON | Variable missing from `.env` — add `SQLSERVER_MESSAGE_KEY_COLUMNS` or `AURORA_MESSAGE_KEY_COLUMNS` |
| `Cannot construct message key` / null-key records | Table has no PK and `message.key.columns` is not set | See [No-PK Table Fix](#no-pk-table--messagekey-columns-errors) below |

**Restart a failed connector:**
```bash
# Restart the connector (restarts all tasks)
curl -X POST http://localhost:8083/connectors/<name>/restart

# Restart a specific task
curl -X POST http://localhost:8083/connectors/<name>/tasks/0/restart
```

### No-PK Table / message.key.columns Errors

**Symptoms:**
- Connector deployment fails with: `message.key.columns value is invalid: ${SQLSERVER_MESSAGE_KEY_COLUMNS}`
- Or connector is RUNNING but JDBC sink crashes with null-key errors
- Or connector is RUNNING but no rows appear in the target database

**Root causes:**

| Symptom | Cause | Fix |
|---------|-------|-----|
| `${VAR}` literal in error | Variable missing from `.env` | Add `SQLSERVER_MESSAGE_KEY_COLUMNS` to `.env` |
| Null-key / empty key records | Table has no PK and `message.key.columns` is not configured | Set value in `.env` (see format below) |
| Connector RUNNING, no rows in target | Empty `message.key.columns` passed to connector | Delete and redeploy connector after fixing `.env` |

**Find tables without primary keys:**

```sql
-- SQL Server
SELECT t.name FROM sys.tables t
WHERE t.type_desc = 'USER_TABLE'
AND t.object_id NOT IN (
  SELECT parent_object_id FROM sys.key_constraints WHERE type = 'PK'
);

-- Aurora PostgreSQL
SELECT tablename FROM pg_tables
WHERE schemaname = 'public'
AND tablename NOT IN (
  SELECT tc.table_name FROM information_schema.table_constraints tc
  WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = 'public'
);
```

**Fix:** Add the variable to `.env` with the composite key columns:

```bash
# Format: <fully-qualified-table>:<col1>,<col2>
# SQL Server: include database name
SQLSERVER_MESSAGE_KEY_COLUMNS=yourdb.dbo.audit_log:event_timestamp,source_type

# Aurora PostgreSQL: schema-qualified
AURORA_MESSAGE_KEY_COLUMNS=public.audit_log:event_timestamp,source_type
```

Then redeploy connectors: `./scripts/6-deploy-connectors.sh`

> **Note:** If all your tables have primary keys, leave both variables empty — the deploy script automatically strips empty properties from connector JSON.

---

### Consumer Lag Growing Unbounded

**Symptoms:** Consumer lag steadily increases on Grafana Consumer Lag dashboard. The sink is falling behind the source.

**Diagnose:**
```bash
# Check lag per partition
kafka-consumer-groups --bootstrap-server ${BROKER_1_IP}:9092 \
  --describe --group connect-jdbc-sink-aurora

# Check sink task throughput
curl -s http://localhost:8083/connectors/jdbc-sink-aurora/status | jq '.tasks'
```

**Fixes:**

1. **Increase sink tasks:** Set `"tasks.max"` higher (up to the number of source topic partitions).
   ```bash
   curl -X PUT http://localhost:8083/connectors/jdbc-sink-aurora/config \
     -H 'Content-Type: application/json' \
     -d '{ ... "tasks.max": "4" ... }'
   ```

2. **Increase batch size:** Larger `batch.size` on the sink reduces per-record overhead.

3. **Target DB bottleneck:** Check the target database for lock contention, slow queries, or resource exhaustion. Add indexes if upsert queries are slow.

4. **Switch to snapshot profile** temporarily for catch-up:
   ```bash
   ./scripts/on-demand-switch-profile.sh snapshot
   ```

### Replication Slot Growing (Aurora WAL Bloat)

**Symptoms:** Aurora PostgreSQL storage growing unexpectedly. `pg_replication_slots` shows high `restart_lsn` lag.

**Diagnose:**
```sql
-- Check replication slot status
SELECT slot_name, active, restart_lsn, confirmed_flush_lsn,
       pg_current_wal_lsn() - confirmed_flush_lsn AS lag_bytes
FROM pg_replication_slots;

-- Check WAL size
SELECT pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS wal_lag
FROM pg_replication_slots
WHERE slot_name = 'debezium';
```

**Causes and fixes:**

| Cause | Fix |
|-------|-----|
| Debezium connector is stopped | Restart the connector; WAL will be consumed |
| Debezium connector is slow | Tune connector throughput (increase tasks, batch size) |
| Slot is orphaned (connector deleted without dropping slot) | Drop the slot: `SELECT pg_drop_replication_slot('debezium');` |
| Long-running transaction holding WAL | Find and terminate: `SELECT pid, query FROM pg_stat_activity WHERE state = 'idle in transaction';` |

**Prevention:** Monitor WAL lag in Grafana. Alert if lag exceeds a threshold (e.g., 1 GB).

### Schema Evolution Issues

**Symptoms:** Connector fails after a DDL change on the source database. Schema Registry reports compatibility errors.

**Diagnose:**
```bash
# Check latest schema version
curl -s http://${CONNECT_1_IP}:8081/subjects/${SQLSERVER_TOPIC_PREFIX}.${SQLSERVER_DB}.${SQLSERVER_SCHEMA}.${TABLE}-value/versions/latest | jq '.schema' | jq -r '.' | jq .

# Check compatibility
curl -s http://${CONNECT_1_IP}:8081/config/${SQLSERVER_TOPIC_PREFIX}.${SQLSERVER_DB}.${SQLSERVER_SCHEMA}.${TABLE}-value
```

**Fixes:**

| Scenario | Fix |
|----------|-----|
| New column added (backward-compatible) | Works automatically with `auto.evolve=true` on the sink |
| Column removed | May break backward compatibility. Set subject compatibility to `NONE` temporarily, then restore |
| Column type changed | Usually requires recreating the connector. Flush the topic, delete old schemas, restart |
| Incompatible schema version | Delete the incompatible version: `curl -X DELETE http://${CONNECT_1_IP}:8081/subjects/<subject>/versions/<version>` |

```bash
# Temporarily set compatibility to NONE
curl -X PUT http://${CONNECT_1_IP}:8081/config/${SQLSERVER_TOPIC_PREFIX}.${SQLSERVER_DB}.${SQLSERVER_SCHEMA}.${TABLE}-value \
  -H 'Content-Type: application/json' \
  -d '{"compatibility": "NONE"}'

# After the schema change propagates, restore to BACKWARD
curl -X PUT http://${CONNECT_1_IP}:8081/config/${SQLSERVER_TOPIC_PREFIX}.${SQLSERVER_DB}.${SQLSERVER_SCHEMA}.${TABLE}-value \
  -H 'Content-Type: application/json' \
  -d '{"compatibility": "BACKWARD"}'
```

### Snapshot Taking Too Long / Stuck

**Symptoms:** Debezium has been in snapshot mode for hours with no progress.

**Diagnose:**
```bash
# Check connector task state
curl -s http://localhost:8083/connectors/debezium-sqlserver-source/status | jq

# Look for snapshot progress in logs
docker compose logs connect 2>&1 | grep -i "snapshot" | tail -20

# Check source DB: is the snapshot query running?
# SQL Server:
# SELECT session_id, status, command, percent_complete FROM sys.dm_exec_requests WHERE command LIKE '%SELECT%';
```

**Fixes:**

1. **Switch to snapshot profile** for maximum throughput:
   ```bash
   ./scripts/on-demand-switch-profile.sh snapshot
   ```

2. **Increase snapshot.fetch.size** in the connector config:
   ```json
   { "snapshot.fetch.size": "20000" }
   ```

3. **Snapshot one table at a time:** Use `table.include.list` to limit which tables are snapshotted.

4. **Check source DB load:** Snapshot is a full table scan. If the source DB is under heavy load, the scan is slow. Consider snapshotting during off-peak hours.

5. **Lock contention (SQL Server):** Debezium's initial snapshot may conflict with ongoing transactions. Check for blocking sessions.

### Connect Worker OOM

**Symptoms:** Connect container restarts unexpectedly. `docker inspect` shows OOMKilled.

**Diagnose:**
```bash
# Check if OOM killed
docker inspect <connect-container-id> | jq '.[0].State.OOMKilled'

# Check memory usage
docker stats --no-stream
```

**Fixes:**

1. **Increase JVM heap:**
   ```properties
   KAFKA_CONNECT_HEAP_OPTS=-Xms4g -Xmx8g
   ```

2. **Reduce in-flight data:**
   - Lower `max.queue.size` on Debezium source connectors.
   - Lower `consumer.max.poll.records` on sink connectors.
   - Reduce number of concurrent tasks.

3. **Check for large messages:** If individual CDC events are very large (wide tables, LOB columns), they consume more memory per record.

4. **Container memory limit:** If Docker memory limits are set, ensure they are at least 2x the JVM heap (for off-heap, stack, and native memory).

### Broker Disk Full

**Symptoms:** Broker logs show "No space left on device." Producers start failing.

**Diagnose:**
```bash
# Check disk usage
df -h /data/kafka

# Find largest topics
du -sh /data/kafka/kraft-combined-logs/* | sort -rh | head -20
```

**Fixes:**

1. **Reduce retention:**
   ```bash
   # Per topic
   kafka-configs --bootstrap-server ${BROKER_1_IP}:9092 \
     --alter --entity-type topics --entity-name sqlserver.yourdb.dbo.large_table \
     --add-config retention.ms=3600000  # 1 hour

   # Wait for log cleanup
   ```

2. **Delete old consumer offsets topics** (if unused connectors left them behind):
   ```bash
   kafka-topics --bootstrap-server ${BROKER_1_IP}:9092 --list | grep offset
   ```

3. **Purge DLQ topics** if they have grown large (see [dlq.md](dlq.md)).

4. **Long term:** Add brokers, increase NVMe capacity, or reduce the number of partitions.

### Network Partition Between Nodes

**Symptoms:** Under-replicated partitions spike. Some brokers show as offline. Connect workers cannot reach all brokers.

**Diagnose:**
```bash
# Ping between nodes
ping -c 3 ${BROKER_2_IP}

# Check broker metadata
kafka-metadata --snapshot /data/kafka/kraft-combined-logs/__cluster_metadata-0/00000000000000000000.log

# Check security groups for port accessibility
# Ensure 9092, 9093 are open between broker nodes
```

**Fixes:**

1. **Security group rules:** Verify all required ports are open between the 5 EC2 nodes. Required ports: 9092 and 9093 between all brokers; 8083, 8084, 8081 from brokers to Node 4; see [README.md](../README.md) for the full port list.

2. **Host networking:** With `network_mode: host`, containers bind to the host IP. Ensure `KAFKA_ADVERTISED_LISTENERS` matches the actual EC2 private IP.

3. **DNS resolution:** If using hostnames instead of IPs, ensure DNS resolves correctly on all nodes.

4. **After partition heals:** Kafka will automatically re-replicate under-replicated partitions. Monitor the Broker Health dashboard until under-replicated partitions returns to 0.

## Connector Management

### Restart a Connector

```bash
# Restart connector and all tasks
curl -X POST http://localhost:8083/connectors/<name>/restart

# Restart with options (Confluent Platform extension)
curl -X POST "http://localhost:8083/connectors/<name>/restart?includeTasks=true&onlyFailed=true"
```

### Reset Consumer Offsets (Sink Connector)

To re-read from a specific point:

```bash
# 1. Stop the connector
curl -X PUT http://localhost:8083/connectors/<name>/pause

# 2. Delete the connector (preserves the consumer group offsets by default)
curl -X DELETE http://localhost:8083/connectors/<name>

# 3. Reset offsets for the consumer group
kafka-consumer-groups --bootstrap-server ${BROKER_1_IP}:9092 \
  --group connect-<name> \
  --reset-offsets --to-earliest --all-topics --execute

# 4. Recreate the connector
curl -X POST http://localhost:8083/connectors \
  -H 'Content-Type: application/json' \
  -d @connectors/<name>.json
```

### Recreate a Connector from Scratch

```bash
# 1. Delete the connector
curl -X DELETE http://localhost:8083/connectors/<name>

# 2. (Optional) Delete the connector's offset topic entries
#    For source connectors, offsets are stored in the Connect offset topic.
#    Deleting and recreating the connector with snapshot.mode=initial
#    will re-snapshot from the beginning.

# 3. Recreate
curl -X POST http://localhost:8083/connectors \
  -H 'Content-Type: application/json' \
  -d @connectors/<name>.json
```

### Update Connector Configuration

```bash
# PUT replaces the entire config
curl -X PUT http://localhost:8083/connectors/<name>/config \
  -H 'Content-Type: application/json' \
  -d '{
    "connector.class": "...",
    "tasks.max": "2",
    ... (all config properties, not just the changed ones)
  }'
```

## Useful Debug Commands

### Connect REST API

```bash
# List all connectors
curl -s http://localhost:8083/connectors | jq

# Connector config
curl -s http://localhost:8083/connectors/<name>/config | jq

# Connector status with task details
curl -s http://localhost:8083/connectors/<name>/status | jq

# List connector plugins
curl -s http://localhost:8083/connector-plugins | jq '.[].class'

# Validate a config before deploying
curl -X PUT http://localhost:8083/connector-plugins/io.debezium.connector.sqlserver.SqlServerConnector/config/validate \
  -H 'Content-Type: application/json' \
  -d '{ ... config ... }' | jq '.configs[].value.errors | select(length > 0)'
```

### kcat (Kafka Swiss Army Knife)

```bash
# List topics
kcat -L -b ${BROKER_1_IP}:9092

# Consume from a topic (latest 5 messages)
kcat -C -b ${BROKER_1_IP}:9092 -t ${SQLSERVER_TOPIC_PREFIX}.${SQLSERVER_DB}.${SQLSERVER_SCHEMA}.${TABLE} -o -5 -e

# Consume with metadata
kcat -C -b ${BROKER_1_IP}:9092 -t ${SQLSERVER_TOPIC_PREFIX}.${SQLSERVER_DB}.${SQLSERVER_SCHEMA}.${TABLE} -o beginning -e \
  -f 'Topic: %t Partition: %p Offset: %o Key: %k\nValue: %s\n---\n'

# Produce a test message
echo '{"id":1,"name":"test"}' | kcat -P -b ${BROKER_1_IP}:9092 -t test-topic

# Consumer group lag
kcat -L -b ${BROKER_1_IP}:9092 -G test-group ${SQLSERVER_TOPIC_PREFIX}.${SQLSERVER_DB}.${SQLSERVER_SCHEMA}.${TABLE}
```

### kafka-consumer-groups

```bash
# Describe all consumer groups
kafka-consumer-groups --bootstrap-server ${BROKER_1_IP}:9092 --describe --all-groups

# Describe a specific group
kafka-consumer-groups --bootstrap-server ${BROKER_1_IP}:9092 \
  --describe --group connect-jdbc-sink-aurora

# List all groups
kafka-consumer-groups --bootstrap-server ${BROKER_1_IP}:9092 --list
```

### Schema Registry

```bash
# List subjects
curl -s http://${CONNECT_1_IP}:8081/subjects | jq

# Get latest schema for a subject
curl -s http://${CONNECT_1_IP}:8081/subjects/${SQLSERVER_TOPIC_PREFIX}.${SQLSERVER_DB}.${SQLSERVER_SCHEMA}.${TABLE}-value/versions/latest | jq

# Check compatibility mode
curl -s http://${CONNECT_1_IP}:8081/config | jq

# Delete a subject (use with caution)
curl -X DELETE http://${CONNECT_1_IP}:8081/subjects/${SQLSERVER_TOPIC_PREFIX}.${SQLSERVER_DB}.${SQLSERVER_SCHEMA}.${TABLE}-value
```

### ksqlDB

```bash
# Connect to ksqlDB CLI
docker exec -it ksqldb-cli ksql http://${MONITOR_1_IP}:8088

# Or use the REST API
curl -X POST http://${MONITOR_1_IP}:8088/ksql \
  -H 'Content-Type: application/vnd.ksql.v1+json' \
  -d '{"ksql": "SHOW STREAMS;", "streamsProperties": {}}'
```

Useful ksqlDB queries for debugging:

```sql
-- Show all streams and tables
SHOW STREAMS;
SHOW TABLES;

-- Inspect CDC events in real time
CREATE STREAM your_table_debug AS
  SELECT * FROM sqlserver_yourdb_dbo_your_table EMIT CHANGES;

-- Check for loop prevention header (headers visible via HEADERKEYS function)
SELECT HEADERKEYS() AS headers FROM your_table_debug EMIT CHANGES LIMIT 10;

-- To inspect header values, use kcat instead:
-- kcat -C -t sqlserver.dbo.your_table -o end -c 5 -f 'Headers: %h\n'
```

## Log Locations

| Service | Log Access |
|---------|-----------|
| Kafka Broker 1 | `docker compose -f docker-compose.yml -f docker-compose.broker1.yml logs broker` |
| Kafka Broker 2 | `docker compose -f docker-compose.yml -f docker-compose.broker2.yml logs broker` |
| Connect Worker 1 (forward) | `docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml logs connect-1` |
| Connect Worker 2 (reverse) | `docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml logs connect-2` |
| Schema Registry | `docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml logs schema-registry` |
| ksqlDB | `docker compose -f docker-compose.yml -f docker-compose.ksqldb-monitoring.yml logs ksqldb-server` |
| Control Center | `docker compose -f docker-compose.yml -f docker-compose.ksqldb-monitoring.yml logs control-center` |

### Reading Connect Logs

Connect logs are verbose. Filter for useful information:

```bash
# Connector-specific errors (forward worker)
docker compose logs connect-1 2>&1 | grep -i "ERROR" | tail -20

# Connector-specific errors (reverse worker)
docker compose logs connect-2 2>&1 | grep -i "ERROR" | tail -20

# Snapshot progress
docker compose logs connect-1 connect-2 2>&1 | grep -i "snapshot" | tail -20

# Task lifecycle events
docker compose logs connect-1 connect-2 2>&1 | grep -E "(Starting|Stopping|Rebalancing)" | tail -20

# Follow logs in real time (forward worker)
docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml logs -f connect-1
```

### Setting Log Levels

Increase logging for a specific connector:

```bash
# Set Debezium to DEBUG
curl -X PUT http://localhost:8083/admin/loggers/io.debezium \
  -H 'Content-Type: application/json' \
  -d '{"level": "DEBUG"}'

# Set JDBC Sink to TRACE
curl -X PUT http://localhost:8083/admin/loggers/io.debezium.connector.jdbc \
  -H 'Content-Type: application/json' \
  -d '{"level": "TRACE"}'

# Reset to default
curl -X PUT http://localhost:8083/admin/loggers/io.debezium \
  -H 'Content-Type: application/json' \
  -d '{"level": "INFO"}'
```

## Emergency Procedures

### Stop All CDC (Kill Switch)

```bash
# Pause all connectors (preserves state)
curl -s http://localhost:8083/connectors | jq -r '.[]' | while read c; do
  curl -X PUT http://localhost:8083/connectors/$c/pause
  echo "Paused: $c"
done

# Resume all connectors
curl -s http://localhost:8083/connectors | jq -r '.[]' | while read c; do
  curl -X PUT http://localhost:8083/connectors/$c/resume
  echo "Resumed: $c"
done
```

### Full Restart of a Node

```bash
# On the affected node (use the overlay file for that node)
# Example for Node 2 (Broker 2):
docker compose -f docker-compose.yml -f docker-compose.broker2.yml down
docker compose -f docker-compose.yml -f docker-compose.broker2.yml up -d

# Example for Node 4 (Connect + Schema Registry):
docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml down
docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml up -d

# Verify services are healthy
docker compose ps
```

### Nuclear Option: Delete and Recreate All Connectors

```bash
# Delete all connectors
curl -s http://localhost:8083/connectors | jq -r '.[]' | while read c; do
  curl -X DELETE http://localhost:8083/connectors/$c
  echo "Deleted: $c"
done

# Redeploy all connectors
./connectors/deploy-all-connectors.sh
```

This does not reset offsets. Source connectors resume from their last committed offset. To force a fresh snapshot, also delete the connector's offset entries or set `snapshot.mode=initial`.

---

## Service Initialization Delays

### Brokers Not Ready at T+60 seconds

**Symptoms:** Port 9093 not responding, logs show "Starting Kafka"

**Expected behavior:** ✅ This is normal during KRaft leader election
- T+30-60s: Container running, initializing
- T+120-300s: KRaft election in progress (NOT an error)
- T+300s: Leader elected, broker ready

**What to do:**
```bash
# Wait and check again
sleep 60
nc -z -v localhost 9093
# Expected: Connection succeeded

# Check logs for KRaft progress
docker logs broker-1 | grep -i "quorum" | tail -10
```

**DO NOT:** Restart the broker or increase timeout. KRaft election timing varies based on quorum negotiation.

See [../operations/startup.md](../operations/startup.md) for detailed service startup timelines.

### Docker Build Takes 10+ Minutes

**Symptoms:** Build logs show "Downloading from Maven Central" for 5+ minutes

**Expected behavior:** ✅ Normal — Maven Central can be intermittent
- Maven dependency resolution: 1-5 minutes
- JDBC driver download (1.35 MB): 30 seconds - 3 minutes
- Compile: 1-2 minutes

**What to do:**
```bash
# Monitor build progress
docker build -t cdc-poc-connect:latest -f connect/Dockerfile connect/

# If timeout, retry (Maven will use cache next time)
docker build --build-arg HTTP_TIMEOUT=600 \
  -t cdc-poc-connect:latest -f connect/Dockerfile connect/
```

**Note:** Subsequent builds are faster (Maven cache reused).

### Connect Worker REST API Slow at T+60 seconds

**Symptoms:** `curl http://localhost:8083/connectors` hangs or times out

**Expected behavior:** ✅ JVM startup in progress
- T+30-60s: Container running, JVM starting
- T+60-120s: Plugins loading, memory allocation
- T+120s: REST API responding

**What to do:**
```bash
# Wait and retry
sleep 30
curl -s http://localhost:8083/connectors

# Check logs for JVM startup
docker logs connect-1 | grep -i "started"
```

See `docs/operations/startup.md` for expected timelines per service.

### Validation Script Hangs on Port Checks

**Symptoms:** `./scripts/ops-health-check.sh` hangs when checking ports

**Diagnosis:**
```bash
# Check if containers are running
docker ps | grep broker
docker ps | grep connect

# Check if service is listening
nc -z -v -w 5 localhost 9093
```

**Fixes:**
- If container not running: `docker compose up -d`
- If container crashed: Check logs with `docker logs <service>`
- If service unresponsive: Wait longer (see timelines above) or restart

---

## Phase 4: Connect Image Build Issues

### Docker BuildKit Context Error (Phase 4 Failure)

**Symptoms:**
```
ERROR: failed to calculate checksum of ref ...: 
failed to walk /var/lib/docker/tmp/buildkit-mount.../jars: 
  no such file or directory
```

Even though `connect/jars/mssql-jdbc-12.4.2.jre11.jar` exists locally on the node.

**Root Cause:**
Docker BuildKit (v2) has a known issue on certain configurations where it cannot access multi-level directories in the build context, even when files exist on the filesystem. This manifests as:
- BuildKit daemon's context mounting fails silently
- Affects both `docker compose build` and `docker build` commands
- Not a permissions issue (file is readable)

**Solution (Applied):**
1. `.dockerignore` created to exclude large directories but preserve `connect/jars/`
2. `scripts/4-build-connect.sh` updated to use `DOCKER_BUILDKIT=0` environment variable
3. Direct `docker build` command used instead of `docker compose build`

**If you encounter this issue:**
```bash
# Rebuild with BuildKit disabled:
cd /home/ec2-user/cdc-on-ec2-docker
DOCKER_BUILDKIT=0 docker build -t cdc-poc-connect:8.0.0 -f connect/Dockerfile .

# Verify the image was created:
docker images | grep cdc-poc-connect
```

**Expected output:**
```
REPOSITORY              TAG      IMAGE ID       SIZE
cdc-poc-connect         8.0.0    f94c4716db6f   2.9GB
```

**Note:** Phase 4 script automatically handles this; no manual intervention needed unless build fails.


---

## Phase 2a: .env Distribution Issues

### .env Not Found on EC2 Nodes After Phase 2a

**Symptoms:**
- Phase 5 or later fails with ".env file not found" errors
- `docker compose` commands fail with "variable not set" warnings
- SSM send-command seems to succeed but .env doesn't actually get created

**Root Cause:**
Shell variable expansion issue in SSM parameters. The original script used single-quoted JSON where `$env_b64` (base64-encoded .env content) wasn't being expanded before sending to SSM.

**Solution (Applied):**
- `scripts/2b-distribute-env.sh` updated to use double-quoted JSON parameters
- Ensures `$env_b64` variable is properly expanded on the jumpbox before sending to SSM
- Version with proper quoting handles special characters in .env file

**If you encounter this issue:**
```bash
# Manually verify .env on a node via SSM:
aws ssm start-session --target <instance-id>
ls -lh ~/cdc-on-ec2-docker/.env

# If missing, re-run Phase 2b:
./scripts/2b-distribute-env.sh

# Or manually copy .env to a specific node:
COPY_CONTENT=$(base64 -w 0 < /home/ec2-user/cdc-on-ec2-docker/.env)
aws ssm send-command --instance-ids <id> --document-name "AWS-RunShellScript" \
  --parameters "commands=[\"echo $COPY_CONTENT | base64 -d > /home/ec2-user/cdc-on-ec2-docker/.env\",\"chmod 600 /home/ec2-user/cdc-on-ec2-docker/.env\"]"
```

**Note:** Phase 2b script automatically handles this; the fix ensures proper .env distribution.

---

## Control Center Crash-Loop (MetricsAggregateStore Partition Mismatch)

### Symptoms

- Control Center container shows `Up 2 seconds` (constantly restarting) while other services are stable
- Port 9021 never starts listening
- Logs show:
  ```
  ERROR Existing internal topic _confluent-controlcenter-2-2-0-1-MetricsAggregateStore-changelog
  has invalid partitions: expected: 12; actual: 3.
  Use 'org.apache.kafka.tools.StreamsResetter' tool to clean up invalid topics before processing.
  ```
- Repeated `waiting for streams to be in running state. Current state is REBALANCING`

### Root Cause

The Confluent Metrics Reporter (on brokers) creates `_confluent-metrics` with **12 partitions** by default. Control Center's Kafka Streams topology requires its `MetricsAggregateStore-changelog` to have the same partition count as `_confluent-metrics`. If `CONTROL_CENTER_INTERNAL_TOPICS_PARTITIONS` is set lower (e.g., 3), the changelog topic gets created with the wrong partition count, and Kafka Streams refuses to start.

### Fix

**Step 1:** Stop Control Center on the monitor node:
```bash
cd ~/cdc-on-ec2-docker
docker compose -f docker-compose.yml -f docker-compose.ksqldb-monitoring.yml stop control-center
```

**Step 2:** Delete all CC internal topics from any broker node:
```bash
TOPICS=$(docker exec <broker-container> kafka-topics --bootstrap-server localhost:9092 --list | grep _confluent-controlcenter-2-2-0-1)
for topic in $TOPICS; do
  docker exec <broker-container> kafka-topics --bootstrap-server localhost:9092 --delete --topic "$topic"
done
```

**Step 3:** Ensure `CONTROL_CENTER_INTERNAL_TOPICS_PARTITIONS` is set to `12` in `docker-compose.yml` (must match `_confluent-metrics` partition count):
```yaml
CONTROL_CENTER_INTERNAL_TOPICS_PARTITIONS: 12
CONTROL_CENTER_MONITORING_INTERCEPTOR_TOPIC_PARTITIONS: 12
```

**Step 4:** Restart Control Center:
```bash
docker compose -f docker-compose.yml -f docker-compose.ksqldb-monitoring.yml up -d control-center
```

**Step 5:** Wait 3-5 minutes for Kafka Streams to recreate ~48 internal topics with correct partitions, then verify:
```bash
# Check container is stable (uptime > 3 min)
docker ps --filter name=control-center

# Check port 9021 is listening
ss -tlnp | grep 9021

# Access UI
curl -s http://localhost:9021/api/version | jq .
```

### Prevention

The `docker-compose.yml` in this repo already sets the correct values (12). If you override these settings or change `confluent.metrics.reporter.topic.partitions` on brokers, ensure the CC internal topics partition count matches.

---

*Apache, Apache Kafka, Kafka, and the Kafka logo are trademarks of The Apache Software Foundation.*


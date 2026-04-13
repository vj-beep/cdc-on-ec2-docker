# Tuning Best Practices

Two-phase tuning strategy for the Apache Kafka® Connect-based CDC deployment: **snapshot** (initial bulk load) and **streaming** (steady-state CDC).

## Two-Phase Tuning Strategy

### Profiles

The `.env.template` ships with **streaming** profile pre-configured. For the initial bulk data load, temporarily switch to **snapshot** profile:

```bash
./scripts/on-demand-switch-profile.sh snapshot    # Before initial bulk load
./scripts/on-demand-switch-profile.sh streaming   # Back to default after snapshot completes
```

The script updates `.env`, distributes it to all nodes, and restarts services.

### When to Switch

| Phase | Duration | Data Volume | Goal | Profile | Trigger |
|-------|----------|-------------|------|---------|---------|
| **Streaming** | Days/weeks | ~300 GB/day | Low latency, stability | `profiles/.env.streaming` | Default — active from deployment |
| **Snapshot** | Hours | ~1 TB initial | Max throughput, consume full history | `profiles/.env.snapshot` | Switch before initial bulk load |

**Check snapshot progress:**
```bash
curl -s http://localhost:8083/connectors/debezium-sqlserver-source/status | jq '.tasks[].state'
# "RUNNING" after initial scan = streaming phase has begun
```

### Snapshot Profile Tuning

During initial bulk load, maximize throughput with large batch sizes and longer linger times:

**Connect Worker:**
```properties
CONNECT_OFFSET_FLUSH_INTERVAL_MS=60000       # 60s — reduce offset commit frequency
CONNECT_CONSUMER_MAX_POLL_RECORDS=2000       # 2K — larger batches
CONNECT_PRODUCER_BATCH_SIZE=131072           # 128 KB — batch producers
CONNECT_PRODUCER_LINGER_MS=50                # 50ms — wait for batch fill
CONNECT_CONSUMER_FETCH_MAX_BYTES=104857600   # 100 MB
KAFKA_CONNECT_HEAP_OPTS=-Xms4g -Xmx8g       # 8 GB heap
```

**Debezium Source:**
```json
"snapshot.mode": "initial",
"snapshot.fetch.size": 10240,
"max.batch.size": 4096,
"max.queue.size": 16384,
"producer.override.batch.size": "131072",
"producer.override.compression.type": "lz4"
```

**JDBC Sink:**
```json
"batch.size": 3000
```

### Streaming Profile Tuning

After snapshot, switch to low-latency settings with smaller batches and shorter polling:

**Connect Worker:**
```properties
CONNECT_OFFSET_FLUSH_INTERVAL_MS=10000       # 10s — more frequent commits
CONNECT_CONSUMER_MAX_POLL_RECORDS=500        # 500 — smaller batches for lower latency
CONNECT_PRODUCER_BATCH_SIZE=16384            # 16 KB
CONNECT_PRODUCER_LINGER_MS=5                 # 5ms — faster flush
KAFKA_CONNECT_HEAP_OPTS=-Xms2g -Xmx4g       # 4 GB heap
```

**Debezium Source:**
```json
"snapshot.mode": "no_data",
"max.batch.size": 2048,
"max.queue.size": 8192,
"poll.interval.ms": 500,
"producer.override.batch.size": "16384",
"producer.override.linger.ms": "5"
```

**JDBC Sink:**
```json
"batch.size": 500
```

**Achievable E2E latency (streaming mode):**
- Aurora → SQL Server: **~50–100ms** (WAL read + Kafka round-trip + DB write)
- SQL Server → Aurora: **~5.1s** on RDS (CDC agent default 5s scan; reducible to ~150ms on self-managed SQL Server)

---

## Sub-Second Latency Tuning

To achieve sub-second end-to-end CDC latency, address each segment of the pipeline independently.

### End-to-End Latency Chain

```
Source DB ──► Debezium ──► Kafka producer ──► Kafka broker ──► sink consumer ──► JDBC write ──► Target DB
```

| Path | Bottleneck | Default | Optimized |
|------|-----------|---------|-----------|
| SQL Server → Kafka | CDC agent scan interval | ~5s | ~150ms ✅ applied |
| Aurora → Kafka | WAL read (pgoutput) | ~5ms | ~5ms |
| Kafka producer (source) | `linger.ms` | 5ms | 0ms ✅ applied |
| Kafka → Aurora | `fetch.max.wait.ms` | 100ms | 10ms ✅ applied |
| Kafka → SQL Server | `fetch.max.wait.ms` | 100ms | 10ms ✅ applied |

**Achievable E2E latency:**
- Aurora → SQL Server: **~50–100ms** (WAL read + Kafka round-trip + DB write)
- SQL Server → Aurora: **~300–500ms** (continuous CDC agent + 100ms Debezium poll + Kafka + write)

### 1. SQL Server CDC Agent Scan Interval

The SQL Server CDC capture job scans the transaction log on a fixed schedule. Debezium's `poll.interval.ms` only controls how often it reads the change tables — those tables are only populated when the agent runs.

**Default interval: 5 seconds.** Use `sys.sp_cdc_change_job` to change it — this procedure works on **RDS SQL Server** without sysadmin (unlike `msdb.dbo.sp_update_jobstep`, which requires sysadmin and fails on RDS):

```sql
-- Works on RDS SQL Server — no sysadmin required
EXEC sys.sp_cdc_change_job
    @job_type = 'capture',
    @pollinginterval = 0;  -- 0 = continuous scanning (~50-150ms latency)
```

Apply immediately on a live system (takes effect within seconds, no connector restart needed):

```bash
source .env
SQLCMDPASSWORD="$SQLSERVER_PASSWORD" sqlcmd \
  -S "$SQLSERVER_HOST,$SQLSERVER_PORT" -U "$SQLSERVER_USER" -d pocdb -C -Q "
  EXEC sys.sp_cdc_change_job @job_type = 'capture', @pollinginterval = 0;
"
```

> Use `@pollinginterval = 1` for dev/cost savings. `@pollinginterval = 0` means continuous — SQL Server scans as fast as possible with ~50–150ms between passes.

> **Note on `sp_update_jobstep`:** An alternative approach of directly modifying the SQL Agent job step (`msdb.dbo.sp_update_jobstep`) requires `sysadmin`, which RDS does not grant. Use `sys.sp_cdc_change_job` instead.

### 2. Source Connector: `producer.override.linger.ms=0`

The Connect worker's `CONNECT_PRODUCER_LINGER_MS=5` adds up to 5ms of batching delay to every event. Source connectors override this per-connector:

```json
"producer.override.linger.ms": "0"
```

This setting is already included in `debezium-sqlserver-source.json` and `debezium-postgres-source.json`. It sends each event to Kafka immediately when produced — no batching wait. Minor throughput tradeoff acceptable at streaming-phase volumes.

### 3. Sink Connectors: `consumer.override.fetch.max.wait.ms=10`

Without this override, the sink connector consumer waits up to `CONNECT_CONSUMER_FETCH_MAX_WAIT_MS` (10ms) before each poll even when data is available. Add to both JDBC sink connectors:

```json
"consumer.override.fetch.max.wait.ms": "10",
"consumer.override.fetch.min.bytes": "1"
```

These settings are already included in `jdbc-sink-aurora.json` and `jdbc-sink-sqlserver.json`.

- `fetch.max.wait.ms=10`: Return immediately when any data is available (up to 10ms wait max).
- `fetch.min.bytes=1`: Don't hold the response waiting for a minimum payload size.

**Apply live without restart** (changes take effect within seconds):

```bash
# Aurora sink (Connect Worker 1, port 8083)
curl -s http://<CONNECT_1_IP>:8083/connectors/jdbc-sink-aurora/config \
  | jq '. + {"consumer.override.fetch.max.wait.ms":"10","consumer.override.fetch.min.bytes":"1"}' \
  | curl -X PUT http://<CONNECT_1_IP>:8083/connectors/jdbc-sink-aurora/config \
       -H "Content-Type: application/json" -d @-

# SQL Server sink (Connect Worker 2, port 8084)
curl -s http://<CONNECT_1_IP>:8084/connectors/jdbc-sink-sqlserver/config \
  | jq '. + {"consumer.override.fetch.max.wait.ms":"10","consumer.override.fetch.min.bytes":"1"}' \
  | curl -X PUT http://<CONNECT_1_IP>:8084/connectors/jdbc-sink-sqlserver/config \
       -H "Content-Type: application/json" -d @-
```

### Latency Budget Summary (streaming profile, optimized)

```
Aurora → SQL Server path (~75ms total):
  WAL read (pgoutput)         ~5ms
  Kafka producer (linger=0)   ~1ms
  Kafka replication (RF=3)    ~10ms
  Sink consumer poll          ~10ms   ← was 100ms
  JDBC write (SQL Server)     ~15ms
  Loop-prevention header check ~1ms
  ────────────────────────────────
  Total                       ~42ms   (practical: ~50–100ms)

SQL Server → Aurora path — RDS SQL Server (POC):
  CDC agent scan interval     ~700-1200ms ← RDS SQL Agent scheduling floor (observed avg ~1000ms)
  Debezium poll               ~50ms      ← poll.interval.ms=50
  Kafka producer (linger=0)   ~1ms
  Kafka replication (RF=3)    ~30ms
  Sink consumer poll          ~10ms
  JDBC write (Aurora)         ~50ms
  ────────────────────────────────
  Total                       ~441-841ms (practical: ~500ms–900ms)

SQL Server → Aurora path — on-premises or self-managed EC2 SQL Server:
  CDC agent scan interval     ~50-150ms  ← sp_update_jobstep /pollinginterval 0
  Debezium poll               ~50ms
  Network (on-prem → EC2)     ~2-5ms     ← Direct Connect; ~5-20ms VPN
  Kafka producer (linger=0)   ~1ms
  Kafka replication (RF=3)    ~30ms
  Sink consumer poll          ~10ms
  JDBC write (Aurora)         ~50ms
  ────────────────────────────────
  Total                       ~193-306ms (practical: ~250–350ms)
```

> **POC vs production latency:** The POC uses RDS SQL Server, which has a CDC agent scheduling floor of ~300–700ms that cannot be bypassed without `sysadmin`. If the production SQL Server is on-premises or self-managed on EC2, latency will be significantly lower — closer to the Aurora → SQL Server path. See [On-Premises SQL Server](#on-premises-sql-server) below.

### On-Premises SQL Server

On-premises and self-managed EC2 SQL Server deployments differ from RDS in three important ways:

**1. Sub-second CDC agent tuning is available**

With `sysadmin` access you can modify the SQL Agent job step directly, which controls the capture loop at the OS thread level — bypassing the RDS scheduling overhead:

```sql
-- Run once at setup as sa — not needed during normal operation
EXEC msdb.dbo.sp_update_jobstep
  @job_name = N'cdc.<dbname>_capture',
  @step_id  = 1,
  @command  = N'/async 1 /maxscans 100 /pollinginterval 0 /maxtrans 5000';

EXEC msdb.dbo.sp_stop_job  N'cdc.<dbname>_capture';
EXEC msdb.dbo.sp_start_job N'cdc.<dbname>_capture';
```

This is a one-time infrastructure setup step run as `sa`. The CDC application user (`cdc_reader`) does not need `sysadmin` for ongoing operation.

**2. CDC enable procedure is different**

RDS uses an AWS-specific wrapper. On-premises uses the standard system procedure:

```sql
-- RDS only — do NOT use on-premises:
-- EXEC msdb.dbo.rds_cdc_enable_db 'pocdb';

-- On-premises / self-managed EC2:
USE pocdb;
EXEC sys.sp_cdc_enable_db;
```

**3. Orphaned SID issue does not apply**

On RDS, the `cdc_reader` login SID can become mismatched with the database user SID, forcing source and sink connectors to use admin credentials. On-premises SQL Server does not have this constraint — `cdc_reader` can be used for both source and sink connectors with a least-privilege grant:

```sql
CREATE LOGIN cdc_reader WITH PASSWORD = '<password>';
CREATE USER  cdc_reader FOR LOGIN cdc_reader;
EXEC sp_addrolemember 'db_datareader', 'cdc_reader';
EXEC sp_addrolemember 'db_owner',      'cdc_reader';  -- required for CDC change table access
-- For sink write access:
GRANT INSERT, UPDATE, DELETE ON SCHEMA::dbo TO cdc_reader;
```

Update `.env` to use `cdc_reader` for both `SQLSERVER_USER` / `SQLSERVER_PASSWORD` and add a separate `CDC_READER_USER` / `CDC_READER_PASSWORD` for the sink connector.

**4. Network connectivity — Debezium on EC2 to on-premises SQL Server**

Debezium runs on EC2 and must reach port 1433 on the on-premises host. Recommended options:

| Option | Added latency | Notes |
|---|---|---|
| AWS Direct Connect | ~1–5ms | Recommended for production CDC volumes |
| Site-to-Site VPN | ~5–20ms | Acceptable; higher variance |
| Internet + TLS | ~20–50ms+ | Not recommended at 300 GB/day |

Update `database.encrypt` in `connectors/debezium-sqlserver-source.json` to match your network path:

```json
"database.encrypt": "true",
"database.trustServerCertificate": "false"
```

## Phase Overview

| Phase | Data Volume | Goal | Profile |
|-------|------------|------|---------|
| Snapshot | ~1 TB initial load | Maximum throughput | `profiles/.env.snapshot` |
| Streaming | ~300 GB/day ongoing | Low latency, stability | `profiles/.env.streaming` |

Switch between phases using:

```bash
./scripts/on-demand-switch-profile.sh snapshot   # Apply snapshot tuning
./scripts/on-demand-switch-profile.sh streaming  # Apply streaming tuning
```

This script updates `.env` with the selected profile values and restarts affected containers.

## Snapshot Phase Tuning

During initial snapshot, Debezium reads entire tables. The goal is maximum throughput with acceptable latency.

### Connect Worker Settings

```properties
# .env.snapshot
CONNECT_OFFSET_FLUSH_INTERVAL_MS=60000
CONNECT_CONSUMER_MAX_POLL_RECORDS=2000
CONNECT_PRODUCER_BATCH_SIZE=131072
CONNECT_PRODUCER_LINGER_MS=50
CONNECT_CONSUMER_FETCH_MAX_BYTES=104857600
```

| Setting | Snapshot Value | Why |
|---------|---------------|-----|
| `offset.flush.interval.ms` | 60000 (60s) | Reduces offset commit frequency during bulk load |
| `consumer.max.poll.records` | 2000 | Larger batches per poll for throughput |
| `producer.batch.size` | 131072 (128 KB) | Larger producer batches reduce request overhead |
| `producer.linger.ms` | 50 | Wait longer to fill batches |
| `consumer.fetch.max.bytes` | 104857600 (100 MB) | Fetch more data per request |

### Debezium Source Connector Settings

```json
{
  "snapshot.mode": "initial",
  "snapshot.fetch.size": 10240,
  "max.batch.size": 4096,
  "max.queue.size": 16384,
  "poll.interval.ms": 100,
  "producer.override.compression.type": "lz4",
  "producer.override.batch.size": "131072",
  "producer.override.linger.ms": "50"
}
```

- `snapshot.fetch.size=10240`: Number of rows fetched per JDBC query during snapshot. Higher = fewer round trips to the source DB.
- `max.batch.size=4096`: Max events Debezium batches before handing to Kafka producer.
- `max.queue.size=16384`: Internal queue between snapshot reader and producer. Must be >= 2x `max.batch.size`.
- `producer.override.compression.type=lz4`: LZ4 compression reduces network and disk I/O with minimal CPU cost.

### JDBC Sink Connector Settings

```json
{
  "batch.size": 3000,
  "consumer.override.max.poll.records": "2000",
  "consumer.override.fetch.max.bytes": "104857600"
}
```

- `batch.size=3000`: Number of records batched into a single JDBC transaction. Larger batches = fewer commits = higher throughput.

### Connect Worker JVM

During snapshot, Connect workers need more heap:

```properties
KAFKA_CONNECT_HEAP_OPTS=-Xms4g -Xmx8g
```

Monitor GC pauses. If frequent, increase heap or switch to G1GC with `-XX:+UseG1GC -XX:MaxGCPauseMillis=200`.

## Streaming Phase Tuning

After snapshot completes, switch to streaming for low-latency change capture.

### Connect Worker Settings

```properties
# .env.streaming
CONNECT_OFFSET_FLUSH_INTERVAL_MS=10000
CONNECT_CONSUMER_MAX_POLL_RECORDS=500
CONNECT_PRODUCER_BATCH_SIZE=16384
CONNECT_PRODUCER_LINGER_MS=5
CONNECT_CONSUMER_FETCH_MAX_BYTES=52428800
```

| Setting | Streaming Value | Why |
|---------|----------------|-----|
| `offset.flush.interval.ms` | 10000 (10s) | More frequent offset commits for exactly-once-ish delivery |
| `consumer.max.poll.records` | 500 | Smaller batches for lower per-record latency |
| `producer.batch.size` | 16384 (16 KB) | Smaller batches flush faster |
| `producer.linger.ms` | 5 | Short wait keeps latency sub-second |
| `consumer.fetch.max.bytes` | 52428800 (50 MB) | Sufficient for streaming volume |

### Debezium Source Connector Settings

```json
{
  "snapshot.mode": "no_data",
  "max.batch.size": 2048,
  "max.queue.size": 8192,
  "poll.interval.ms": 50,
  "producer.override.compression.type": "lz4",
  "producer.override.batch.size": "16384",
  "producer.override.linger.ms": "5"
}
```

- `snapshot.mode=no_data`: Skip data snapshot on restart; capture schema only, then stream changes. (`schema_only` was renamed to `no_data` in Debezium 2.x — use `no_data` for Debezium 3.x.)
- `poll.interval.ms=500`: How often Debezium polls the transaction log. Lower = less latency, more CPU.

### JDBC Sink Connector Settings

```json
{
  "batch.size": 500,
  "consumer.override.max.poll.records": "500"
}
```

Smaller sink batch sizes reduce end-to-end latency at the cost of more frequent DB commits.

## Kafka Broker Tuning

These settings apply to all three brokers. Set in the Docker Compose environment or `.env`.

### I/O and Network Threads

```properties
KAFKA_NUM_IO_THREADS=16
KAFKA_NUM_NETWORK_THREADS=8
KAFKA_NUM_REPLICA_FETCHERS=4
```

- `num.io.threads`: Set to the number of vCPUs (equal to the number of vCPU on your broker instance). Handles disk I/O.
- `num.network.threads`: Handles network requests. 8 is a good starting point for 3-broker clusters.
- `num.replica.fetchers`: Parallel threads for inter-broker replication. 4 keeps replicas caught up during heavy writes.

### Socket Buffers

```properties
KAFKA_SOCKET_SEND_BUFFER_BYTES=1048576
KAFKA_SOCKET_RECEIVE_BUFFER_BYTES=1048576
KAFKA_SOCKET_REQUEST_MAX_BYTES=104857600
```

1 MB send/receive buffers and 100 MB max request size accommodate large snapshot batches.

### Log Settings

```properties
KAFKA_LOG_SEGMENT_BYTES=536870912
KAFKA_LOG_RETENTION_HOURS=72
KAFKA_LOG_RETENTION_BYTES=5368709120
KAFKA_LOG_CLEANUP_POLICY=delete
```

- 512 MB segments balance compaction overhead with recovery time.
- 72-hour retention provides replay buffer for connector issues.
- 5 GB per-partition cap prevents runaway growth on high-volume topics.

### Replication

```properties
KAFKA_DEFAULT_REPLICATION_FACTOR=3
KAFKA_MIN_INSYNC_REPLICAS=2
KAFKA_UNCLEAN_LEADER_ELECTION_ENABLE=false
```

RF=3 with `min.insync.replicas=2` ensures no data loss if one broker fails. Never enable unclean leader election for CDC workloads.

## NVMe-Specific Tuning

### Filesystem

Kafka data directory is configured via `KAFKA_DATA_DIR` in `.env` (default: `/data/kafka`).

The `3-setup-ec2.sh` script automatically detects NVMe drives and mounts them at the configured directory with `xfs` + `noatime`:

```bash
# If configuring manually (replace /dev/nvme1n1 and $KAFKA_DATA_DIR with your values):
mkfs.xfs /dev/nvme1n1
mount -o noatime /dev/nvme1n1 ${KAFKA_DATA_DIR}
```

- **xfs**: Best performance for Kafka's sequential write pattern.
- **noatime**: Eliminates access-time metadata writes, reducing I/O overhead by ~10-15%.

### No RAID Needed

With RF=3 across 3 NVMe-backed brokers, data redundancy is handled at the Kafka level. RAID on individual nodes adds write amplification and complexity without benefit.

If an instance has 2 NVMe drives, mount them separately and stripe partitions:

```bash
# Mount first drive
mount -o noatime /dev/nvme1n1 ${KAFKA_DATA_DIR}/disk1

# Mount second drive  
mount -o noatime /dev/nvme2n1 ${KAFKA_DATA_DIR}/disk2

# Configure Kafka to stripe partitions across both:
KAFKA_LOG_DIRS=${KAFKA_DATA_DIR}/disk1,${KAFKA_DATA_DIR}/disk2
```

Kafka stripes partitions across directories automatically.

### I/O Scheduler

For NVMe drives, the `none` (noop) scheduler is optimal:

```bash
echo none > /sys/block/nvme1n1/queue/scheduler
```

NVMe drives have their own internal queue management; OS-level schedulers add overhead.

## When to Switch Profiles

| Trigger | Action |
|---------|--------|
| Fresh deployment | Streaming by default — no action needed |
| Before initial bulk load | `./scripts/on-demand-switch-profile.sh snapshot` |
| Snapshot completes (connector status shows `STREAMING`) | `./scripts/on-demand-switch-profile.sh streaming` |
| Need to re-snapshot a table | `./scripts/on-demand-switch-profile.sh snapshot`, reconfigure connector with `snapshot.mode=initial` |
| Performance degradation during streaming | Check metrics, consider temporary snapshot profile |

To check if snapshot is complete:

```bash
curl -s http://localhost:8083/connectors/debezium-sqlserver-source/status | jq '.tasks[].state'
# "RUNNING" after snapshot = streaming phase has begun

# Also check the connector's task trace for "Snapshot completed"
docker compose logs connect | grep -i "snapshot completed"
```

## Memory Allocation Guidelines

| Service | Snapshot Heap | Streaming Heap |
|---------|--------------|----------------|
| Kafka Broker | `-Xmx6g` | `-Xmx6g` |
| Connect Worker | `-Xmx8g` | `-Xmx4g` |
| Schema Registry | `-Xmx512m` | `-Xmx512m` |
| ksqlDB | `-Xmx4g` | `-Xmx4g` |

Leave remaining RAM for OS page cache — Kafka relies heavily on it for read performance.

---

*Apache, Apache Kafka, Kafka, and the Kafka logo are trademarks of The Apache Software Foundation.*

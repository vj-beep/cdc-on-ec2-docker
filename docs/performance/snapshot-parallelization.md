# Snapshot Parallelization for Large Tables

Debezium's initial snapshot phase is **single-threaded per connector instance**. Tables are processed sequentially — one large table blocks all others behind it. This document covers strategies to parallelize snapshot workloads using Confluent Platform, Apache Kafka, and Debezium best practices.

## The Problem

```
Single connector with 5 tables (one is 500 GB):

  ┌─────────────────────────────────────────────────────────────┐
  │ big_table (500 GB, 8 hours) │ t2 │ t3 │ t4 │ t5 │ stream  │
  └─────────────────────────────────────────────────────────────┘
  0h                            8h   8.1h              8.2h

  Total time to start streaming: ~8.2 hours
```

**Root cause:** Debezium's `SnapshotReader` iterates `table.include.list` sequentially. Each table is `SELECT *`'d to completion before the next begins. CDC streaming starts only after **all** tables finish snapshot.

## Strategy Overview

| # | Strategy | Parallelizes | Best When | Complexity |
|---|----------|-------------|-----------|-----------|
| 1 | Multiple connector instances | Across tables | Several large tables that should snapshot concurrently | Low |
| 2 | `snapshot.max.threads` | Across tables (single connector) | Many medium tables, none dominant | Low |
| 3 | Incremental snapshot | Within one table (chunked, non-blocking) | One huge table, need streaming ASAP | Medium |
| 4 | PK-range partitioned connectors | Within one table (parallel readers) | One huge table, need fastest possible snapshot | High |
| 5 | Combined approach | Both across and within tables | Large deployment with mixed table sizes | High |

---

## Strategy 1: Multiple Connector Instances

Split tables across separate source connectors so each snapshots independently on its own Connect task thread.

### When to Use

- Multiple large tables that should all snapshot in parallel
- Tables with independent schemas or different CDC requirements
- Simplest approach when you have 2-5 large tables

### Architecture

```
┌──────────────────┐     ┌─────────────────┐
│  Connector A     │────▶│ big_table        │  Topic: prefix-a.dbo.big_table
│  (own task)      │     │ (500 GB)         │
└──────────────────┘     └─────────────────┘

┌──────────────────┐     ┌─────────────────┐
│  Connector B     │────▶│ medium_table     │  Topic: prefix-b.dbo.medium_table
│  (own task)      │     │ (50 GB)          │
└──────────────────┘     └─────────────────┘

┌──────────────────┐     ┌─────────────────┐
│  Connector C     │────▶│ small_1, small_2 │  Topics: prefix-c.dbo.small_*
│  (own task)      │     │ (1 GB each)      │
└──────────────────┘     └─────────────────┘
```

### SQL Server Source Example

**Connector A — large table only:**

```json
{
  "name": "debezium-sqlserver-source-bigtable",
  "config": {
    "connector.class": "io.debezium.connector.sqlserver.SqlServerConnector",
    "database.hostname": "${SQLSERVER_HOST}",
    "database.port": "${SQLSERVER_PORT}",
    "database.user": "${SQLSERVER_USER}",
    "database.password": "${SQLSERVER_PASSWORD}",
    "database.names": "${SQLSERVER_DATABASE}",
    "topic.prefix": "sqlserver-bigtable",
    "table.include.list": "dbo.bigTable",
    "snapshot.mode": "initial",
    "snapshot.fetch.size": "20000",
    "max.batch.size": "8192",
    "max.queue.size": "32768",
    "producer.override.compression.type": "lz4",
    "producer.override.batch.size": "262144",
    "producer.override.linger.ms": "100",
    "schema.history.internal.kafka.bootstrap.servers": "${KAFKA_BOOTSTRAP_SERVERS}",
    "schema.history.internal.kafka.topic": "schema-history-bigtable"
  }
}
```

**Connector B — remaining tables:**

```json
{
  "name": "debezium-sqlserver-source-other",
  "config": {
    "connector.class": "io.debezium.connector.sqlserver.SqlServerConnector",
    "database.hostname": "${SQLSERVER_HOST}",
    "database.port": "${SQLSERVER_PORT}",
    "database.user": "${SQLSERVER_USER}",
    "database.password": "${SQLSERVER_PASSWORD}",
    "database.names": "${SQLSERVER_DATABASE}",
    "topic.prefix": "sqlserver-other",
    "table.include.list": "dbo.workItem,dbo.workItemData,dbo.eventsLog",
    "snapshot.mode": "initial",
    "snapshot.fetch.size": "10240",
    "max.batch.size": "4096",
    "max.queue.size": "16384",
    "producer.override.compression.type": "lz4",
    "schema.history.internal.kafka.bootstrap.servers": "${KAFKA_BOOTSTRAP_SERVERS}",
    "schema.history.internal.kafka.topic": "schema-history-other"
  }
}
```

### PostgreSQL Source Example

Each PostgreSQL source connector requires its own **replication slot** and **publication**:

```sql
-- Create dedicated replication slots
SELECT pg_create_logical_replication_slot('debezium_bigtable', 'pgoutput');
SELECT pg_create_logical_replication_slot('debezium_other', 'pgoutput');

-- Create dedicated publications
CREATE PUBLICATION pub_bigtable FOR TABLE products;
CREATE PUBLICATION pub_other FOR TABLE inventory_log;
```

```json
{
  "name": "debezium-postgres-source-bigtable",
  "config": {
    "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
    "database.hostname": "${AURORA_HOST}",
    "database.port": "${AURORA_PORT}",
    "database.user": "${AURORA_USER}",
    "database.password": "${AURORA_PASSWORD}",
    "database.dbname": "${AURORA_DATABASE}",
    "topic.prefix": "aurora-bigtable",
    "table.include.list": "public.products",
    "slot.name": "debezium_bigtable",
    "publication.name": "pub_bigtable",
    "plugin.name": "pgoutput",
    "snapshot.mode": "initial"
  }
}
```

### Key Constraints

| Constraint | SQL Server | PostgreSQL |
|-----------|-----------|-----------|
| Unique `topic.prefix` per connector | Required | Required |
| Separate schema history topic | Required | Required |
| Separate replication slot | N/A | Required |
| Separate publication | N/A | Required |
| Max concurrent connectors | Limited by Connect worker heap | Limited by `max_replication_slots` |

### Sink Configuration

Sinks must consume from all topic prefixes. Use `topics.regex`:

```json
{
  "name": "jdbc-sink-aurora-all",
  "config": {
    "topics.regex": "(sqlserver-bigtable|sqlserver-other)\\..*\\.dbo\\..*",
    "connection.url": "jdbc:postgresql://${AURORA_HOST}:${AURORA_PORT}/${AURORA_DATABASE}",
    "insert.mode": "upsert",
    "pk.mode": "record_key"
  }
}
```

### Resource Impact

Each additional source connector consumes:
- ~1 Connect task thread
- ~256 MB - 1 GB heap (depending on queue sizes)
- 1 JDBC connection to the source database
- 1 replication slot (PostgreSQL only)

**Guideline:** A Connect worker with 8 GB heap can comfortably run 4-6 source connectors with snapshot profile settings.

---

## Strategy 2: `snapshot.max.threads` (Debezium 3.x)

Debezium 3.x introduced `snapshot.max.threads` to parallelize snapshot across tables within a single connector instance.

### When to Use

- Many medium-sized tables (no single dominant table)
- Want parallelism without the operational overhead of multiple connectors
- Acceptable to snapshot multiple tables concurrently from a single JDBC connection pool

### Configuration

```json
{
  "name": "debezium-sqlserver-source",
  "config": {
    "connector.class": "io.debezium.connector.sqlserver.SqlServerConnector",
    "topic.prefix": "sqlserver",
    "table.include.list": "dbo.table1,dbo.table2,dbo.table3,dbo.table4,dbo.table5",
    "snapshot.mode": "initial",
    "snapshot.max.threads": "4",
    "snapshot.fetch.size": "10240",
    "max.batch.size": "4096",
    "max.queue.size": "32768"
  }
}
```

### How It Works

```
Without snapshot.max.threads (default = 1):
  Thread 1: [table1] → [table2] → [table3] → [table4] → [table5] → streaming

With snapshot.max.threads = 4:
  Thread 1: [table1] ─────────────────────────────────┐
  Thread 2: [table2] ──────────┐                      │
  Thread 3: [table3] ──────────┤ → all complete → streaming
  Thread 4: [table4] ──────────┘                      │
  (queued)  [table5] → picked up when a thread frees ─┘
```

### Limitations

- Parallelizes **across tables**, not **within a single table**
- If one table is 90% of data, this helps minimally (the large table still blocks streaming until done)
- Each thread opens its own JDBC cursor — monitor source DB connection count
- Internal queue (`max.queue.size`) is shared across all threads — size it accordingly: `max.queue.size >= snapshot.max.threads * max.batch.size * 2`

### Source DB Impact

| Threads | Concurrent Queries | Approx. IOPS Increase |
|---------|-------------------|----------------------|
| 1 | 1 | Baseline |
| 2 | 2 | ~1.8x |
| 4 | 4 | ~3.5x |
| 8 | 8 | ~6x (diminishing returns) |

Monitor source database CPU and I/O. Set `snapshot.max.threads` no higher than 50% of available source DB CPU cores.

---

## Strategy 3: Incremental Snapshot (Non-Blocking)

Incremental snapshot lets Debezium start streaming CDC immediately, then backfill the large table in chunks interleaved with live CDC events.

### When to Use

- One huge table blocks everything but streaming must start ASAP
- Cannot afford downtime or stalled CDC during snapshot
- Acceptable that the large table snapshot takes longer (but doesn't block others)

### How It Works

```
Traditional snapshot:
  [──── big_table snapshot (8h) ────][streaming begins]

Incremental snapshot:
  [streaming begins immediately]
  ├─ chunk 1 (10K rows) ─ CDC events ─ chunk 2 ─ CDC events ─ ... ─ chunk N ─┤
  └──────────── big_table completed over time (non-blocking) ─────────────────┘
```

1. Connector starts with `snapshot.mode=no_data` — no traditional blocking snapshot
2. Streaming begins immediately for all tables
3. A signal triggers incremental snapshot of the large table
4. Debezium reads chunks (configurable size) with watermark-based consistency
5. Between chunks, CDC events are processed normally — no blocking

### Setup

**Step 1: Create the signal table**

SQL Server:
```sql
CREATE TABLE dbo.debezium_signal (
    id VARCHAR(64) NOT NULL PRIMARY KEY,
    type VARCHAR(32) NOT NULL,
    data VARCHAR(2048) NULL
);

-- Enable CDC on the signal table
EXEC sys.sp_cdc_enable_table
    @source_schema = N'dbo',
    @source_name = N'debezium_signal',
    @role_name = NULL,
    @supports_net_changes = 0;
```

PostgreSQL:
```sql
CREATE TABLE public.debezium_signal (
    id VARCHAR(64) NOT NULL PRIMARY KEY,
    type VARCHAR(32) NOT NULL,
    data VARCHAR(2048) NULL
);

-- Add to publication
ALTER PUBLICATION dbz_publication ADD TABLE public.debezium_signal;
```

**Step 2: Configure the connector**

```json
{
  "name": "debezium-sqlserver-source",
  "config": {
    "connector.class": "io.debezium.connector.sqlserver.SqlServerConnector",
    "topic.prefix": "sqlserver",
    "table.include.list": "dbo.bigTable,dbo.workItem,dbo.workItemData,dbo.debezium_signal",
    "snapshot.mode": "no_data",
    "signal.enabled.channels": "source",
    "signal.data.collection": "dbo.debezium_signal",
    "incremental.snapshot.chunk.size": "10000",
    "incremental.snapshot.allow.schema.changes": "true"
  }
}
```

**Step 3: Trigger the incremental snapshot**

After the connector is running and streaming:

```sql
-- Trigger incremental snapshot of the large table
INSERT INTO dbo.debezium_signal (id, type, data)
VALUES (
    CONVERT(VARCHAR(64), NEWID()),
    'execute-snapshot',
    '{"data-collections": ["dbo.bigTable"], "type": "incremental"}'
);
```

For PostgreSQL:
```sql
INSERT INTO public.debezium_signal (id, type, data)
VALUES (
    gen_random_uuid()::varchar,
    'execute-snapshot',
    '{"data-collections": ["public.big_table"], "type": "incremental"}'
);
```

### Chunk Size Tuning

| `incremental.snapshot.chunk.size` | Behavior | Use When |
|----------------------------------|----------|----------|
| 1,000 | Small chunks, minimal CDC latency impact | High-throughput streaming, latency-sensitive |
| 10,000 (default) | Balanced throughput and latency | General purpose |
| 50,000 | Large chunks, faster snapshot completion | Low CDC volume, snapshot speed priority |
| 100,000 | Very large chunks | Off-hours backfill, minimal concurrent CDC |

### Watermark-Based Consistency

Debezium uses a **watermark mechanism** to ensure consistency between snapshot chunks and CDC events:

1. Before reading a chunk, Debezium writes an "open" watermark to the signal table
2. Reads the chunk via `SELECT ... WHERE pk > ? AND pk <= ? ORDER BY pk`
3. Writes a "close" watermark
4. Any CDC events that arrive between open and close watermarks for the same rows are deduplicated

This guarantees exactly-once semantics even with concurrent writes to the table being snapshotted.

### Monitoring Progress

```bash
# Check connector metrics for snapshot progress
curl -s http://localhost:8083/connectors/debezium-sqlserver-source/status | \
  jq '.tasks[0].trace' | grep -i "snapshot"

# JMX metrics (if JMX exporter configured)
# debezium_snapshot_remaining_table_count
# debezium_snapshot_rows_scanned{table="dbo.bigTable"}
```

### Stopping and Resuming

Incremental snapshot survives connector restarts:

```sql
-- Stop an in-progress incremental snapshot
INSERT INTO dbo.debezium_signal (id, type, data)
VALUES (CONVERT(VARCHAR(64), NEWID()), 'stop-snapshot', '{"data-collections": ["dbo.bigTable"], "type": "incremental"}');

-- Resume later
INSERT INTO dbo.debezium_signal (id, type, data)
VALUES (CONVERT(VARCHAR(64), NEWID()), 'execute-snapshot', '{"data-collections": ["dbo.bigTable"], "type": "incremental"}');
```

---

## Strategy 4: PK-Range Partitioned Connectors (Intra-Table Parallelism)

Deploy N connectors each reading a non-overlapping primary key range of the **same table** using `snapshot.select.statement.overrides`.

### When to Use

- One table is overwhelmingly large (>80% of total data)
- Need the fastest possible snapshot completion time
- Source database can handle N concurrent full-table scans
- Table has a numeric, uniformly distributed primary key

### Architecture

```
┌──────────────────┐     ┌─────────────────────────────────┐
│ Connector Chunk1 │────▶│ SELECT * FROM big WHERE id 1-25M │ → topic: chunk1.dbo.big
└──────────────────┘     └─────────────────────────────────┘

┌──────────────────┐     ┌──────────────────────────────────┐
│ Connector Chunk2 │────▶│ SELECT * FROM big WHERE id 25M-50M│ → topic: chunk2.dbo.big
└──────────────────┘     └──────────────────────────────────┘

┌──────────────────┐     ┌──────────────────────────────────┐
│ Connector Chunk3 │────▶│ SELECT * FROM big WHERE id 50M-75M│ → topic: chunk3.dbo.big
└──────────────────┘     └──────────────────────────────────┘

┌──────────────────┐     ┌───────────────────────────────────┐
│ Connector Chunk4 │────▶│ SELECT * FROM big WHERE id 75M-100M│ → topic: chunk4.dbo.big
└──────────────────┘     └───────────────────────────────────┘

┌──────────────────┐     ┌─────────────────────────────────┐
│ Connector Stream │────▶│ snapshot.mode=no_data (CDC only) │ → topic: main.dbo.big
└──────────────────┘     └─────────────────────────────────┘
```

### Step 1: Determine PK Ranges

```sql
-- SQL Server: Get min, max, and count for range calculation
SELECT
    MIN(id) AS min_id,
    MAX(id) AS max_id,
    COUNT(*) AS total_rows
FROM dbo.bigTable;

-- For non-uniform distribution, use percentile boundaries:
SELECT DISTINCT
    PERCENTILE_DISC(0.25) WITHIN GROUP (ORDER BY id) OVER() AS p25,
    PERCENTILE_DISC(0.50) WITHIN GROUP (ORDER BY id) OVER() AS p50,
    PERCENTILE_DISC(0.75) WITHIN GROUP (ORDER BY id) OVER() AS p75
FROM dbo.bigTable;
```

```sql
-- PostgreSQL equivalent:
SELECT
    MIN(id) AS min_id,
    MAX(id) AS max_id,
    COUNT(*) AS total_rows
FROM public.big_table;

SELECT
    percentile_disc(0.25) WITHIN GROUP (ORDER BY id) AS p25,
    percentile_disc(0.50) WITHIN GROUP (ORDER BY id) AS p50,
    percentile_disc(0.75) WITHIN GROUP (ORDER BY id) AS p75
FROM public.big_table;
```

### Step 2: Deploy Chunk Connectors

**Chunk connector 1 of 4:**

```json
{
  "name": "sqlserver-source-bigtable-chunk1",
  "config": {
    "connector.class": "io.debezium.connector.sqlserver.SqlServerConnector",
    "database.hostname": "${SQLSERVER_HOST}",
    "database.port": "${SQLSERVER_PORT}",
    "database.user": "${SQLSERVER_USER}",
    "database.password": "${SQLSERVER_PASSWORD}",
    "database.names": "${SQLSERVER_DATABASE}",
    "topic.prefix": "sqlserver-chunk1",
    "table.include.list": "dbo.bigTable",
    "snapshot.mode": "initial_only",
    "snapshot.select.statement.overrides": "dbo.bigTable",
    "snapshot.select.statement.overrides.dbo.bigTable": "SELECT * FROM dbo.bigTable WHERE id BETWEEN 1 AND 25000000 ORDER BY id",
    "snapshot.fetch.size": "20000",
    "max.batch.size": "8192",
    "max.queue.size": "32768",
    "producer.override.compression.type": "lz4",
    "producer.override.batch.size": "262144",
    "producer.override.linger.ms": "100",
    "schema.history.internal.kafka.bootstrap.servers": "${KAFKA_BOOTSTRAP_SERVERS}",
    "schema.history.internal.kafka.topic": "schema-history-chunk1"
  }
}
```

**Chunk connector 2 of 4:**

```json
{
  "name": "sqlserver-source-bigtable-chunk2",
  "config": {
    "connector.class": "io.debezium.connector.sqlserver.SqlServerConnector",
    "database.hostname": "${SQLSERVER_HOST}",
    "database.port": "${SQLSERVER_PORT}",
    "database.user": "${SQLSERVER_USER}",
    "database.password": "${SQLSERVER_PASSWORD}",
    "database.names": "${SQLSERVER_DATABASE}",
    "topic.prefix": "sqlserver-chunk2",
    "table.include.list": "dbo.bigTable",
    "snapshot.mode": "initial_only",
    "snapshot.select.statement.overrides": "dbo.bigTable",
    "snapshot.select.statement.overrides.dbo.bigTable": "SELECT * FROM dbo.bigTable WHERE id BETWEEN 25000001 AND 50000000 ORDER BY id",
    "snapshot.fetch.size": "20000",
    "max.batch.size": "8192",
    "max.queue.size": "32768",
    "producer.override.compression.type": "lz4",
    "producer.override.batch.size": "262144",
    "producer.override.linger.ms": "100",
    "schema.history.internal.kafka.bootstrap.servers": "${KAFKA_BOOTSTRAP_SERVERS}",
    "schema.history.internal.kafka.topic": "schema-history-chunk2"
  }
}
```

**Repeat for chunks 3 and 4** with ranges `50000001-75000000` and `75000001-100000000`.

### Step 3: Deploy Streaming Connector (Parallel)

Deploy alongside chunk connectors — starts capturing CDC immediately:

```json
{
  "name": "sqlserver-source-bigtable-stream",
  "config": {
    "connector.class": "io.debezium.connector.sqlserver.SqlServerConnector",
    "database.hostname": "${SQLSERVER_HOST}",
    "database.port": "${SQLSERVER_PORT}",
    "database.user": "${SQLSERVER_USER}",
    "database.password": "${SQLSERVER_PASSWORD}",
    "database.names": "${SQLSERVER_DATABASE}",
    "topic.prefix": "sqlserver",
    "table.include.list": "dbo.bigTable",
    "snapshot.mode": "no_data",
    "schema.history.internal.kafka.bootstrap.servers": "${KAFKA_BOOTSTRAP_SERVERS}",
    "schema.history.internal.kafka.topic": "schema-history-stream"
  }
}
```

### Step 4: Configure Sink to Consume All Topics

```json
{
  "name": "jdbc-sink-aurora-bigtable",
  "config": {
    "connector.class": "io.confluent.connect.jdbc.JdbcSinkConnector",
    "topics.regex": "(sqlserver-chunk[1-4]|sqlserver)\\..*\\.dbo\\.bigTable",
    "connection.url": "jdbc:postgresql://${AURORA_HOST}:${AURORA_PORT}/${AURORA_DATABASE}",
    "connection.user": "${AURORA_USER}",
    "connection.password": "${AURORA_PASSWORD}",
    "insert.mode": "upsert",
    "pk.mode": "record_key",
    "pk.fields": "id",
    "auto.create": "true",
    "auto.evolve": "true",
    "batch.size": "5000",
    "tasks.max": "4"
  }
}
```

**Important:** Set `tasks.max=4` on the sink to parallelize writes across the 4 chunk topics.

### Step 5: Post-Snapshot Cleanup

Monitor chunk connector status:

```bash
# Check if chunk connectors completed (status = COMPLETED or no tasks running)
for i in 1 2 3 4; do
  echo "Chunk $i:"
  curl -s http://localhost:8083/connectors/sqlserver-source-bigtable-chunk$i/status | \
    jq '{state: .connector.state, tasks: [.tasks[].state]}'
done
```

Once all chunks report completed:

```bash
# Delete chunk connectors
for i in 1 2 3 4; do
  curl -X DELETE http://localhost:8083/connectors/sqlserver-source-bigtable-chunk$i
done

# Update sink topics.regex to only consume from the streaming connector
curl -X PUT http://localhost:8083/connectors/jdbc-sink-aurora-bigtable/config \
  -H "Content-Type: application/json" \
  -d '{
    "topics.regex": "sqlserver\\..*\\.dbo\\.bigTable",
    "insert.mode": "upsert",
    "pk.mode": "record_key",
    "pk.fields": "id",
    "batch.size": "500",
    "tasks.max": "1"
  }'
```

### Handling Non-Uniform PK Distribution

If the PK is not uniformly distributed (e.g., UUIDs, timestamps, or gaps from deletes):

```sql
-- Generate N equal-sized ranges based on actual row distribution
-- This query returns boundary values for 4 chunks
WITH numbered AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY id) AS rn, COUNT(*) OVER() AS total
    FROM dbo.bigTable
)
SELECT id AS boundary
FROM numbered
WHERE rn IN (total/4, total*2/4, total*3/4)
ORDER BY id;
```

For non-numeric PKs (VARCHAR, UUID), use a hash-based approach:

```sql
-- SQL Server: partition by hash of PK
"snapshot.select.statement.overrides.dbo.bigTable":
  "SELECT * FROM dbo.bigTable WHERE ABS(CHECKSUM(id)) % 4 = 0 ORDER BY id"
-- Chunk 2: ... % 4 = 1, Chunk 3: ... % 4 = 2, Chunk 4: ... % 4 = 3
```

### Throughput Estimates

Based on observed POC performance (850K rows/min single connector):

| Parallel Connectors | Theoretical Throughput | Practical Throughput | Limiting Factor |
|--------------------|----------------------|---------------------|----------------|
| 1 | 850K rows/min | 850K rows/min | Debezium single-thread |
| 2 | 1.7M rows/min | ~1.5M rows/min | Source DB I/O |
| 4 | 3.4M rows/min | ~2.8M rows/min | Source DB I/O + network |
| 8 | 6.8M rows/min | ~4M rows/min | Diminishing returns, DB contention |

**Practical ceiling:** Source database read I/O becomes the bottleneck at 4+ parallel readers. Monitor `sys.dm_io_virtual_file_stats` (SQL Server) or `pg_stat_io` (PostgreSQL).

### Key Constraints and Risks

| Risk | Mitigation |
|------|-----------|
| Source DB overload from N concurrent scans | Monitor CPU/IOPS; start with 2-4 connectors |
| Duplicate records during overlap | Sink uses `upsert` mode — idempotent writes |
| CDC events during snapshot window | Streaming connector captures independently |
| Missing rows at chunk boundaries | Use `BETWEEN` with inclusive bounds; verify ranges are contiguous |
| Connect worker OOM | Each connector uses ~512 MB-1 GB; size heap accordingly |

---

## Strategy 5: Combined Approach (Recommended for Production)

For production deployments with mixed table sizes, combine strategies for optimal results.

### Deployment Pattern

```
Phase 1: Deploy streaming infrastructure
  ├── Streaming connector (snapshot.mode=no_data) — CDC events flow immediately
  └── Sink connector (topics.regex covers all prefixes)

Phase 2: Snapshot small/medium tables (Strategy 1 or 2)
  ├── Connector for small tables (snapshot.max.threads=4)
  └── Completes in minutes

Phase 3: Snapshot large table (Strategy 3 or 4)
  ├── Option A: Incremental snapshot (non-blocking, slower)
  └── Option B: PK-range connectors (blocking per-chunk, faster)

Phase 4: Cleanup
  ├── Delete snapshot-only connectors
  └── Verify row counts match source
```

### Example: Mixed Workload (5 tables, 1 dominant)

| Table | Size | Strategy |
|-------|------|----------|
| `orders` | 500 GB | PK-range (4 chunks) |
| `customers` | 50 GB | Separate connector |
| `products` | 10 GB | Grouped with line_items |
| `line_items` | 20 GB | Grouped with products |
| `audit_log` | 5 GB | Grouped with products |

```json
// Connector 1: orders chunk 1 (snapshot.mode=initial_only)
// Connector 2: orders chunk 2 (snapshot.mode=initial_only)
// Connector 3: orders chunk 3 (snapshot.mode=initial_only)
// Connector 4: orders chunk 4 (snapshot.mode=initial_only)
// Connector 5: customers (snapshot.mode=initial)
// Connector 6: products + line_items + audit_log (snapshot.max.threads=3)
// Connector 7: orders streaming (snapshot.mode=no_data) — runs permanently
```

After chunks 1-4 and connector 5 complete, delete them. Reconfigure connector 6 to `snapshot.mode=no_data`. Connector 7 continues streaming.

---

## Source Database Considerations

### SQL Server

| Concern | Recommendation |
|---------|---------------|
| CDC agent contention | Multiple snapshot readers don't contend with CDC agent (different tables) |
| `tempdb` pressure | Large `ORDER BY` queries spill to tempdb; monitor `tempdb` size |
| Lock escalation | Snapshot uses `WITH (NOLOCK)` by default (Debezium); no blocking |
| Connection limit | Each connector = 1 connection; verify `max connections` server setting |
| Transaction log growth | Snapshot doesn't generate log; CDC cleanup may lag during heavy reads |

### PostgreSQL (Aurora)

| Concern | Recommendation |
|---------|---------------|
| Replication slot count | One slot per connector; check `max_replication_slots` (default 10 on Aurora) |
| WAL retention | Multiple slots = WAL retained until slowest slot advances; monitor disk |
| `work_mem` | Large `ORDER BY` queries may use sort memory; set per-session if needed |
| Connection limit | Aurora default is `LEAST(DBInstanceClassMemory/9531392, 5000)` |
| MVCC bloat | Long-running snapshot queries hold old row versions; monitor `pg_stat_user_tables.n_dead_tup` |

### Monitoring During Parallel Snapshot

```bash
# SQL Server: Monitor active queries from Debezium
SELECT session_id, status, command, wait_type, cpu_time, reads, writes
FROM sys.dm_exec_requests
WHERE program_name LIKE '%Debezium%' OR login_name = 'cdcadmin';

# PostgreSQL: Monitor replication slots
SELECT slot_name, active, restart_lsn, confirmed_flush_lsn,
       pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS lag_bytes
FROM pg_replication_slots;

# Connect worker: Monitor task status
curl -s http://localhost:8083/connectors | jq -r '.[]' | while read c; do
  echo "$c: $(curl -s http://localhost:8083/connectors/$c/status | jq -r '.tasks[0].state')"
done
```

---

## Connect Worker Sizing for Parallel Snapshots

### Heap Calculation

```
Base worker overhead:         ~512 MB
Per source connector:         ~512 MB (queue buffers + JDBC result sets)
Per sink connector:           ~256 MB (smaller queues)
Safety margin (GC overhead):  ~20%

Example: 4 chunk connectors + 1 streaming + 1 sink
  = 512 + (5 × 512) + (1 × 256) + 20% overhead
  = 512 + 2560 + 256 + 665
  = ~4 GB minimum, recommend 8 GB
```

```properties
KAFKA_CONNECT_HEAP_OPTS=-Xms4g -Xmx8g -XX:+UseG1GC -XX:MaxGCPauseMillis=200
```

### Worker Thread Pool

Connect's internal thread pool must accommodate all concurrent tasks:

```properties
# In connect-distributed.properties or docker env
CONNECT_TASK_SHUTDOWN_GRACEFUL_TIMEOUT_MS=30000
```

Each connector task runs on its own thread. With 6 concurrent connectors (4 chunks + 1 streaming + 1 other), ensure the JVM has sufficient OS threads available (default is usually fine up to ~50 connectors).

### Horizontal Scaling (Multiple Connect Workers)

For very large parallel snapshots (8+ concurrent connectors), distribute across multiple Connect workers:

```
Connect Worker 1 (Node 4a): Chunk connectors 1-2 + streaming connector
Connect Worker 2 (Node 4b): Chunk connectors 3-4 + sink connector
```

Configure both workers with the same `group.id` to form a Connect cluster. Tasks are automatically distributed.

---

## Validation and Verification

### Row Count Verification

After snapshot completes, verify source and target row counts match:

```bash
# SQL Server source count
SQLCMDPASSWORD="$SQLSERVER_PASSWORD" sqlcmd \
  -S "$SQLSERVER_HOST,$SQLSERVER_PORT" -U "$SQLSERVER_USER" -d "$SQLSERVER_DATABASE" -C \
  -Q "SELECT COUNT(*) AS source_count FROM dbo.bigTable"

# Aurora target count
PGPASSWORD="$AURORA_PASSWORD" psql \
  -h "$AURORA_HOST" -p "$AURORA_PORT" -U "$AURORA_USER" -d "$AURORA_DATABASE" \
  -c "SELECT COUNT(*) AS target_count FROM public.big_table"
```

### Detecting Missing Ranges

```sql
-- SQL Server: Find gaps in PK coverage
WITH ranges AS (
    SELECT 1 AS chunk_start, 25000000 AS chunk_end
    UNION ALL SELECT 25000001, 50000000
    UNION ALL SELECT 50000001, 75000000
    UNION ALL SELECT 75000001, 100000000
)
SELECT r.chunk_start, r.chunk_end,
       (SELECT COUNT(*) FROM dbo.bigTable WHERE id BETWEEN r.chunk_start AND r.chunk_end) AS rows_in_range
FROM ranges r;
```

### Consumer Lag Monitoring

```bash
# Check all consumer groups for snapshot connectors
kafka-consumer-groups --bootstrap-server ${KAFKA_BOOTSTRAP_SERVERS} \
  --describe --all-groups | grep -E "chunk|bigtable"
```

---

## Decision Matrix

Use this matrix to select the right strategy:

| Scenario | Recommended Strategy | Expected Speedup |
|----------|---------------------|-----------------|
| 5 tables, all ~equal size | `snapshot.max.threads=5` | ~4-5x |
| 10 tables, 2 are 80% of data | Multiple connectors (2 large + 1 grouped) | ~3x |
| 1 table is 95% of data, need streaming ASAP | Incremental snapshot | 1x snapshot speed, but streaming starts immediately |
| 1 table is 95% of data, need fastest snapshot | PK-range (4 chunks) | ~3-4x |
| Mixed: 1 huge + several medium + many small | Combined (PK-range for huge + `max.threads` for rest) | ~4-6x |
| Table has no usable PK for range splitting | Incremental snapshot | 1x (no parallelism, but non-blocking) |

---

## Operational Runbook

### Before Starting Parallel Snapshot

1. **Verify source DB capacity:** Check CPU headroom (target <70% during snapshot)
2. **Size Connect worker heap:** Calculate based on number of connectors (see formula above)
3. **Pre-create Kafka topics:** Parallel connectors create topics concurrently; avoid race conditions:
   ```bash
   kafka-topics --bootstrap-server ${KAFKA_BOOTSTRAP_SERVERS} \
     --create --topic sqlserver-chunk1.${SQLSERVER_DATABASE}.dbo.bigTable \
     --partitions 6 --replication-factor 3
   ```
4. **Set retention for chunk topics:** Short retention since chunk data is temporary:
   ```bash
   kafka-configs --bootstrap-server ${KAFKA_BOOTSTRAP_SERVERS} \
     --alter --entity-type topics --entity-name sqlserver-chunk1.${SQLSERVER_DATABASE}.dbo.bigTable \
     --add-config retention.ms=86400000  # 24h retention for chunk topics
   ```

### During Parallel Snapshot

Monitor:
- Source DB CPU and IOPS
- Connect worker heap usage and GC pauses
- Kafka broker disk I/O (NVMe should handle easily)
- Consumer lag on sink connector

### After Parallel Snapshot

1. Verify row counts match
2. Delete chunk connectors
3. Delete chunk topics (or let retention expire)
4. Switch to streaming profile: `./scripts/on-demand-switch-profile.sh streaming`
5. Redeploy remaining connectors: `./scripts/6-deploy-connectors.sh`

---

*Apache, Apache Kafka, Kafka, and the Kafka logo are trademarks of The Apache Software Foundation.*

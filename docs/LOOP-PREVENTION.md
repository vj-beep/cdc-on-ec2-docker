# Loop Prevention

Bi-directional CDC creates an infinite loop if not handled. This document explains the problem, the solution, and how to validate it.

## The Problem

In a bi-directional setup, every write triggers a cascade:

```
SQL Server (original INSERT)
  -> SQL Server CDC captures change
    -> Debezium SQL Server Source -> Kafka topic
      -> JDBC Sink writes to Aurora PostgreSQL
        -> Aurora CDC captures that write
          -> Debezium PostgreSQL Source -> Kafka topic
            -> JDBC Sink writes to SQL Server
              -> SQL Server CDC captures that write
                -> Debezium SQL Server Source -> Kafka topic
                  -> ... infinite loop
```

A single INSERT produces an endless cycle of CDC events bouncing between the two databases. Without loop prevention, this saturates Kafka, the databases, and the network.

## Solution: Kafka Headers with HasHeaderKey

Use Apache Kafka® record headers to carry a source-origin marker. Each source connector stamps every record with a **source-specific header key** identifying the origin system. Each sink connector uses a `HasHeaderKey` predicate to drop records that carry the header key matching its own target system.

**No database schema changes required.** Headers are Kafka metadata, not application data.

### Why HasHeaderKey (Not HeaderStringMatches)

Apache Kafka 4.0 / Confluent Platform 8.0 ships only three built-in predicates:
- `HasHeaderKey` — checks if a header with a given key name exists
- `RecordIsTombstone` — checks if the record value is null
- `TopicNameMatches` — regex match on topic name

`HeaderStringMatches` does **not** exist in these versions. Using it results in a `Class not found` error at connector deployment time.

The `HasHeaderKey` approach uses **distinct header key names per source** (e.g., `__cdc_from_sqlserver`, `__cdc_from_aurora`) rather than a shared key with different values. The sink drops any record that carries the header key matching its own target system, regardless of the header value.

### How It Works

1. **Source connectors** use the `InsertHeader` SMT to add a source-specific header key:
   - SQL Server source adds header key `__cdc_from_sqlserver` (value: `true`)
   - PostgreSQL source adds header key `__cdc_from_aurora` (value: `true`)

2. **Sink connectors** use the `HasHeaderKey` predicate with the `Filter` SMT:
   - Aurora sink drops records that have the `__cdc_from_aurora` header key (originated from Aurora)
   - SQL Server sink drops records that have the `__cdc_from_sqlserver` header key (originated from SQL Server)

**Example flow:**

1. Application writes a row to SQL Server
2. Debezium SQL Server Source captures the change and adds header `__cdc_from_sqlserver: true`
3. JDBC Sink to Aurora checks for header key `__cdc_from_aurora` — not present, so it **writes the row**
4. Aurora CDC captures that write
5. Debezium PostgreSQL Source captures it and adds header `__cdc_from_aurora: true`
6. JDBC Sink to SQL Server checks for header key `__cdc_from_sqlserver` — not present, so it **writes the row**
7. SQL Server CDC captures that write
8. Debezium SQL Server Source captures it and adds header `__cdc_from_sqlserver: true`
9. JDBC Sink to Aurora checks for header key `__cdc_from_aurora` — not present, so it writes again...

**Key insight:** At step 9, the record does NOT have `__cdc_from_aurora` — it has `__cdc_from_sqlserver`. This means headers alone allow **one extra hop** before the data converges.

**The actual loop-breaking mechanism:**

The loop converges because of `insert.mode=upsert`. After the first round-trip, both databases have identical data. The upsert writes identical values, and while CDC may fire, the data does not change. Combined with the header filter dropping one direction's records, the loop damps out within 2 hops:

1. **Hop 1:** Original write → reaches target → data is new → CDC fires
2. **Hop 2:** Return trip → reaches original → upsert with identical data → CDC may fire but data unchanged
3. **Hop 3:** If CDC fires, the header filter on the intermediate system drops it → loop ends

In practice with upsert mode, offset monitoring shows the loop converges within seconds.

## SMT Configuration

### Source Connectors

**Debezium SQL Server Source** — stamps all records with `__cdc_from_sqlserver` header:

```json
{
  "transforms": "addSource",
  "transforms.addSource.type": "org.apache.kafka.connect.transforms.InsertHeader",
  "transforms.addSource.header": "__cdc_from_sqlserver",
  "transforms.addSource.value.literal": "true"
}
```

**Debezium PostgreSQL Source** — stamps all records with `__cdc_from_aurora` header:

```json
{
  "transforms": "addSource",
  "transforms.addSource.type": "org.apache.kafka.connect.transforms.InsertHeader",
  "transforms.addSource.header": "__cdc_from_aurora",
  "transforms.addSource.value.literal": "true"
}
```

### Sink Connectors

**JDBC Sink to Aurora PostgreSQL** — drops records originating from Aurora:

```json
{
  "predicates": "isLoopback",
  "predicates.isLoopback.type": "org.apache.kafka.connect.transforms.predicates.HasHeaderKey",
  "predicates.isLoopback.name": "__cdc_from_aurora",

  "transforms": "unwrap,filterLoopback,routeTopics",
  "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "transforms.unwrap.drop.tombstones": "true",
  "transforms.unwrap.delete.handling.mode": "drop",
  "transforms.filterLoopback.type": "org.apache.kafka.connect.transforms.Filter",
  "transforms.filterLoopback.predicate": "isLoopback"
}
```

**JDBC Sink to SQL Server** — drops records originating from SQL Server:

```json
{
  "predicates": "isLoopback",
  "predicates.isLoopback.type": "org.apache.kafka.connect.transforms.predicates.HasHeaderKey",
  "predicates.isLoopback.name": "__cdc_from_sqlserver",

  "transforms": "unwrap,filterLoopback,routeTopics",
  "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "transforms.unwrap.drop.tombstones": "true",
  "transforms.unwrap.delete.handling.mode": "drop",
  "transforms.filterLoopback.type": "org.apache.kafka.connect.transforms.Filter",
  "transforms.filterLoopback.predicate": "isLoopback"
}
```

### How the Predicate Works

The `HasHeaderKey` predicate:
- Inspects the Kafka record's headers for a header with the specified `name`
- Returns `true` if any header with that key name exists (value is ignored)
- When the predicate matches, the `Filter` SMT drops the record

This is a standard Apache Kafka Connect predicate — no Confluent-specific plugins required.

## Testing Loop Prevention

### Step 1: Insert a Record on SQL Server

```sql
-- Explicit PK required (no IDENTITY — see bi-directional CDC note)
INSERT INTO dbo.your_table (id, name, status)
VALUES (5001, 'Test Record', 'active');
```

### Step 2: Verify It Arrives at Aurora

```sql
-- On Aurora PostgreSQL
SELECT id, name, status
FROM public.your_table
WHERE id = 5001;
```

### Step 3: Verify No Infinite Loop

Monitor Kafka topic message counts. After the initial replication, message counts should stabilize within seconds:

```bash
# Check topic message counts (should not keep growing)
kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list ${BROKER_1_IP}:9092 \
  --topic sqlserver.dbo.your_table

# Check the DLQ for any dropped records
kcat -C -t dlq-jdbc-sink-aurora -o beginning -e
```

### Step 4: Test the Reverse Direction

```sql
-- On Aurora PostgreSQL
INSERT INTO public.your_table (id, name, status)
VALUES (6001, 'Reverse Test', 'active');
```

Verify it arrives at SQL Server and the loop does not continue indefinitely.

### Step 5: Inspect Headers

Use `kcat` to inspect Kafka headers on records:

```bash
# Show headers on SQL Server source topic
kcat -C -t sqlserver.dbo.your_table -o end -c 1 -f 'Headers: %h\nKey: %k\nValue: %s\n'

# Expected: Headers: __cdc_from_sqlserver=true
```

## Alternative Approaches

### Marker Column (Requires Schema Changes)

Instead of Kafka headers, add a `__cdc_source VARCHAR(50)` column to every replicated table. Source connectors use `InsertField$Value` to stamp the column, and sink connectors filter on the column value.

**Pros:** The marker persists in the database, so it survives across CDC hops.
**Cons:** Requires schema changes on every replicated table in both databases — impractical when replicating hundreds or thousands of existing tables.

### Topic Naming Convention

Use separate topic prefixes (`sqlserver.*` and `aurora.*`) and configure each sink to only consume from the opposite prefix:

- Aurora sink subscribes to `sqlserver.*` topics only
- SQL Server sink subscribes to `aurora.*` topics only

This inherently prevents loops because each sink never reads topics produced by its own source connector.

**Pros:** Simple, no SMTs needed.
**Cons:** Does not work if you need a single canonical topic per table (e.g., for ksqlDB joins across both sources).

## Important Notes

### SQL Server IDENTITY Columns and Bi-Directional CDC

Tables participating in bi-directional CDC must **not** use `IDENTITY` on PK columns. The JDBC sink connector inserts explicit PK values from the source system, and SQL Server rejects explicit inserts into IDENTITY columns unless `IDENTITY_INSERT` is set to `ON` (which the JDBC sink cannot do). Use plain `BIGINT NOT NULL PRIMARY KEY` instead. `BIGINT` is preferred over `INT` — at high CDC throughput, `INT` range exhausts in hours.

### Tombstone Records (Deletes)

Debezium emits tombstone records (null value) for deletes. The `InsertHeader` SMT can still add headers to tombstone records (unlike `InsertField$Value` which cannot add fields to null values). This is an advantage of the headers approach. However, the sink connectors are configured with `delete.handling.mode=drop` to skip deletes.

### Header Preservation

Kafka headers persist across topic-to-topic copies and most SMT chains. However, ksqlDB and Kafka Streams may not preserve headers when creating derived topics. If you route records through ksqlDB before the sink, verify headers are preserved.

### Initial Snapshot

During initial snapshot, Debezium reads existing rows. The `InsertHeader` SMT stamps all of them with the source marker. If both databases already have the same data (pre-seeded), the initial snapshot will try to replicate everything. Use `snapshot.mode=no_data` on the reverse-direction connector or ensure the target tables are empty before starting.

### Upsert Convergence

With `insert.mode=upsert`, writing identical data to a row produces a CDC event (the database sees an UPDATE even if values are unchanged). In practice, the loop converges after 2 hops because the data is identical and the header-based filter helps damp the round-trip. Monitor topic offsets during initial testing to confirm convergence.

### Multi-Hop Replication

If you add a third database to the topology, extend the header strategy: each source stamps its own header key name (e.g., `__cdc_from_db3`), and each sink filters out records carrying its own system's header key.

---

*Apache, Apache Kafka, Kafka, and the Kafka logo are trademarks of The Apache Software Foundation.*

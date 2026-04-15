# CDC Connector Configurations

Four connector configurations for bi-directional Change Data Capture (CDC).

## Connector Map

| File | Direction | Connect Worker |
|------|-----------|---------------|
| `debezium-sqlserver-source.json` | SQL Server → Apache Kafka® | forward (port 8083) |
| `jdbc-sink-aurora.json` | Kafka → Aurora PostgreSQL | forward (port 8083) |
| `debezium-postgres-source.json` | Aurora PostgreSQL → Kafka | reverse (port 8084) |
| `jdbc-sink-sqlserver.json` | Kafka → SQL Server | reverse (port 8084) |

## Deploying

```bash
# Deploy all 4 connectors (preferred — handles env substitution and status checks)
./scripts/6-deploy-connectors.sh

# Or deploy individually using the shell helper in this directory
./connectors/deploy-all-connectors.sh
```

## Customizing Before Deployment

### 1. Set table lists in `.env`

```bash
SQLSERVER_TABLE_INCLUDE_LIST=dbo.table1,dbo.table2
AURORA_TABLE_INCLUDE_LIST=public.table1,public.table2
```

### 2. Set sink topic lists in `.env`

These must match the topics produced by the source connectors:

```bash
# SQL Server source produces: <SQLSERVER_TOPIC_PREFIX>.<DB>.<schema>.<table>
JDBC_SINK_AURORA_TOPICS=sqlserver.yourdb.dbo.table1,sqlserver.yourdb.dbo.table2
JDBC_SINK_AURORA_TOPIC_REGEX='sqlserver.yourdb.dbo.(.+)'

# Aurora source produces: <AURORA_TOPIC_PREFIX>.<schema>.<table>
JDBC_SINK_SQLSERVER_TOPICS=aurora.public.table1,aurora.public.table2
JDBC_SINK_SQLSERVER_TOPIC_REGEX='aurora.public.(.+)'
```

> **Important:** The `TOPIC_REGEX` value must contain a capture group `(.+)` — the `RegexRouter` SMT uses `$1` to extract the target table name. Without the capture group, `$1` resolves to empty string and all records are silently routed to a topic named `""`. Single-quote the value in `.env` to prevent bash from interpreting the parentheses.

### 3. No-PK tables

For tables without a primary key, add `message.key.columns` to the source connector config to construct a composite key from value fields:

```json
"message.key.columns": "yourdb.dbo.audit_log:event_timestamp,source_type"
```

The column list must uniquely identify each row. Without this, Debezium cannot construct a record key and the connector will fail.

On the sink side, ensure `primary.key.mode` is set to `record_key` and that the target table has a matching unique constraint.

### 4. PII masking

To mask sensitive columns before writing to the target database, add a `MaskField` SMT to the source connector. Example for PII columns:

```json
"transforms": "addSource,maskPii",
"transforms.maskPii.type": "org.apache.kafka.connect.transforms.MaskField$Value",
"transforms.maskPii.fields": "pii_field1,pii_field2",
"transforms.maskPii.replacement": ""
```

Add `maskPii` to the `transforms` list after `addSource` (the loop-prevention header must be added first).

## Loop Prevention

Each source connector stamps records with a source-specific Kafka header key:
- SQL Server source adds: `__cdc_from_sqlserver`
- PostgreSQL source adds: `__cdc_from_aurora`

Each sink connector drops records carrying the header key matching its own target system, preventing infinite replication cycles.

## Dead Letter Queues

Both sink connectors write failed records to dedicated DLQ topics:
- `dlq-jdbc-sink-aurora`
- `dlq-jdbc-sink-sqlserver`

See [../docs/operations/dlq.md](../docs/operations/dlq.md) for inspection and replay procedures.

---

*Apache, Apache Kafka, Kafka, and the Kafka logo are trademarks of The Apache Software Foundation.*

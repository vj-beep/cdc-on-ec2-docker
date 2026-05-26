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
# Deploy all 4 connectors (handles env substitution and status checks)
./scripts/6-deploy-connectors.sh
```

## Customizing Before Deployment

### 1. Source connectors — automatic table discovery

No table lists needed. Source connectors automatically capture:
- **SQL Server:** all tables with CDC enabled (`sys.sp_cdc_enable_table`)
- **Aurora PostgreSQL:** all tables in the publication and `AURORA_SCHEMA_INCLUDE_LIST`

### 2. Sink topic subscription (regex-based)

Sink connectors use `topics.regex` to auto-subscribe to all CDC topics:

```bash
# Sink writing to Aurora subscribes to all SQL Server CDC topics
JDBC_SINK_AURORA_TOPICS_REGEX=sqlserver\\..*\\.dbo\\..*
JDBC_SINK_AURORA_TOPIC_REGEX='sqlserver\.[^.]+\.dbo\.(.+)'

# Sink writing to SQL Server subscribes to all Aurora CDC topics
JDBC_SINK_SQLSERVER_TOPICS_REGEX=aurora\\.public\\..*
JDBC_SINK_SQLSERVER_TOPIC_REGEX='aurora\.public\.(.+)'
```

> **Important:** The `TOPIC_REGEX` value must contain a capture group `(.+)` — the `RegexRouter` SMT uses `$1` to extract the target table name. Without the capture group, `$1` resolves to empty string and all records are silently routed to a topic named `""`. Single-quote the value in `.env` to prevent bash from interpreting the parentheses.
>
> **Adding new tables:** Just enable CDC on the source database — no connector config or `.env` changes required.

### 3. No-PK tables

For tables without a primary key, add `message.key.columns` to the source connector config to construct a composite key from value fields:

```json
"message.key.columns": "yourdb.dbo.audit_log:event_timestamp,source_type"
```

The column list must uniquely identify each row. Without this, Debezium cannot construct a record key and the connector will fail.

On the sink side, ensure `primary.key.mode` is set to `record_key` and that the target table has a matching unique constraint.

### 4. PII masking

To mask sensitive columns before writing to the target database, add a `MaskField` SMT to the source connector. Example for PII columns:

Add a `MaskField` SMT to the source connector. Example for PII columns:

```json
"transforms": "maskPii",
"transforms.maskPii.type": "org.apache.kafka.connect.transforms.MaskField$Value",
"transforms.maskPii.fields": "pii_field1,pii_field2",
"transforms.maskPii.replacement": ""
```

## Transforms

All four connectors use **Kafka Connect Single Message Transforms (SMTs)** for envelope extraction and topic routing:

| Connector | Transforms | Purpose |
|---|---|---|
| `debezium-sqlserver-source` | `unwrap` | Extract row payload from Debezium envelope |
| `jdbc-sink-aurora` | `routeTopics` | Route records to target table by name (RegexRouter) |
| `debezium-postgres-source` | `unwrap` | Extract row payload from Debezium envelope |
| `jdbc-sink-sqlserver` | `routeTopics` | Route records to target table by name (RegexRouter) |

**Note on `unwrap`:** The `unwrap` transform (Debezium built-in) must be on source connectors. Debezium publishes wrapped envelopes with `op`, `ts_ms`, `before`, `after` fields. The JDBC sink uses the Avro schema from Schema Registry to auto-generate DDL — unwrapping at the source ensures the flat row payload reaches Schema Registry, so the generated table schema and columns are correct.

**Field names across systems:** Source and sink field names must match exactly. The POC uses matching schemas on both databases; for systems with different naming conventions (e.g., camelCase ↔ snake_case), implement custom SMTs or normalize at the application level.

## Loop Prevention

Loop prevention is handled at the **database level**: only CDC-enable (SQL Server) or add to the publication (Aurora) the tables that should replicate in each direction. Tables that are CDC-enabled on both databases will replicate in both directions — ensure this is intentional.

Use `ops-audit-cdc-enabled.sh` to verify which tables have CDC enabled:

```bash
./scripts/ops-audit-cdc-enabled.sh --sqlserver   # Show CDC-enabled tables in SQL Server
./scripts/ops-audit-cdc-enabled.sh --aurora       # Show tables in Aurora publication
```

## Dead Letter Queues

Both sink connectors write failed records to dedicated DLQ topics:
- `dlq-jdbc-sink-aurora`
- `dlq-jdbc-sink-sqlserver`

See [../docs/operations/dlq.md](../docs/operations/dlq.md) for inspection and replay procedures.

---

*Apache, Apache Kafka, Kafka, and the Kafka logo are trademarks of The Apache Software Foundation.*

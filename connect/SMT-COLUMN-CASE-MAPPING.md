# Column Case Mapping for Bi-Directional CDC

## What's the Problem?

When you replicate data from Aurora PostgreSQL back to SQL Server, there's a column naming mismatch:

- **Aurora** uses lowercase column names: `workitemid`, `dataxml` (PostgreSQL default)
- **SQL Server** has camelCase column names: `workItemId`, `dataXml` (original source columns)

Without fixing this, the reverse CDC path fails because SQL Server can't find columns with lowercase names that don't exist in the target table.

## How It Works

We use two custom components to automatically rename columns during replication:

### 1. SqlServerCaseRestorer (SMT — Simple Message Transform)
Runs on each Kafka record before it reaches the SQL Server sink. It:
- Queries SQL Server to discover the actual column names in your tables
- Renames Kafka record fields from lowercase (`workitemid`) → camelCase (`workItemId`)
- Renames the topic name to match the SQL Server table name

### 2. SqlServerColumnNamingStrategy (Naming Strategy)
Operates inside Debezium's schema validation. When Debezium checks if a column exists, it:
- Receives the lowercase column name from Aurora (`workitemid`)
- Looks up the actual camelCase name from SQL Server (`workItemId`)
- Returns the correct name so the column is found in the target table

### 3. Required Setting: `quote.identifiers=true`
This tells SQL Server to accept and preserve camelCase names in brackets (e.g., `[workItemId]`). Without it, SQL Server lowercases all identifiers and the column names still won't match.

## Example Data Flow

```
1. INSERT into Aurora
   workitemdata: { workitemid=99001, title="Test", dataxml="<x/>" }

2. Debezium publishes to Kafka with lowercase fields
   Topic: aurora.public.workitemdata
   Fields: workitemid, title, dataxml

3. SqlServerCaseRestorer renames everything
   Topic: aurora.public.workItemData  ← renamed to match SQL Server table
   Fields: workItemId, title, dataXml ← renamed to match SQL Server columns

4. Debezium JDBC Sink writes to SQL Server
   Table: dbo.workItemData
   Columns: workItemId, title, dataXml ← camelCase preserved ✓

5. Result in SQL Server
   dbo.workItemData: { workItemId=99001, title="Test", dataXml="<x/>" }
```

## How to Enable It

The components are automatically included in the connector deployment. The critical settings in your `.env` are:

```bash
# Enable PostgreSQL logical replication (one-time setup)
rds.logical_replication=1  # Set in Aurora parameter group

# Create replication publication (done automatically during Phase 1)
CREATE PUBLICATION cdc_publication FOR ALL TABLES;

# Connector configuration automatically includes:
# - quote.identifiers=true
# - SqlServerCaseRestorer SMT
# - SqlServerColumnNamingStrategy
```

**No additional setup is needed.** The deployment scripts handle everything automatically.

## Testing It Works

Run the automated test from the private repo:
```bash
cd infra-private
./scripts/test-workitemdata-reverse-path.sh
```

This test:
1. Inserts a row into Aurora (`workitemdata`)
2. Waits 5 seconds for CDC propagation
3. Verifies the row appears in SQL Server (`dbo.workItemData`) with camelCase columns

Expected output:
```
✅ Row found in SQL Server dbo.workItemData
   Column names: workItemId, title, dataXml, createdAt, updatedAt
```

## Troubleshooting

**"Cannot ALTER table because field is not optional but has no default value"**
- → `quote.identifiers` needs to be `true` in the connector
- → Check: `curl http://localhost:8084/connectors/jdbc-sink-sqlserver | jq '.config["quote.identifiers"]'`

**Data not propagating from Aurora to SQL Server**
- → Check replication slot is active: `SELECT slot_name, active FROM pg_replication_slots;`
- → Should show: `debezium_cdc | t` (active = true)
- → If not active, restart the connector: `curl -X POST http://localhost:8084/connectors/debezium-postgres-source/restart`

**Column names still lowercase in SQL Server**
- → Check the smit JAR was loaded: `curl http://localhost:8083/connectors/jdbc-sink-sqlserver | jq '.config["transforms"]'`
- → Should include `caseRestorer`

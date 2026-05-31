# Column Case Mapping for Bi-Directional CDC

## What's the Problem?

When you replicate data from Aurora PostgreSQL back to SQL Server, there's a column naming mismatch:

- **Aurora** uses lowercase column names: `workitemid`, `dataxml` (PostgreSQL default)
- **SQL Server** has camelCase column names: `workItemId`, `dataXml` (original source columns)

Without fixing this, the reverse CDC path fails because SQL Server can't find columns with lowercase names that don't exist in the target table.

⚠️ **Production Best Practice**

The connector has `auto.create=true` and `auto.evolve=true` for POC convenience. However, **production deployments should:**
- ✓ Pre-create all target tables on SQL Server with correct camelCase column names
- ✓ Disable `auto.create` and `auto.evolve` for safety
- ✗ Never rely on auto-schema generation in production

⚠️ **Why?** Auto-creation can silently create unwanted indexes, constraints, or data types that don't match your schema governance requirements.

## How It Works

We use two custom components to automatically rename columns during replication:

### 1. SqlServerCaseRestorer (SMT — Simple Message Transform)
Runs on each Kafka record before it reaches the SQL Server sink. It:
- Queries SQL Server to discover the actual column names in your tables
- Renames Kafka record fields from lowercase (`workitemid`) → camelCase (`workItemId`)
- Renames the **record's topic field** (used for routing) to match the SQL Server table name (the actual Kafka topic `aurora.public.workitemdata` in Control Center remains unchanged)

### 2. SqlServerColumnNamingStrategy (Naming Strategy)
Operates inside Debezium's schema validation. When Debezium checks if a column exists, it:
- Receives the lowercase column name from Aurora (`workitemid`)
- Looks up the actual camelCase name from SQL Server (`workItemId`)
- Returns the correct name so the column is found in the target table

### Why Both Components Are Needed

The SMT renames fields in the Kafka record payload — the sink sees `workItemId` in the data. But the JDBC sink has a **second independent code path**: `resolveMissingFields()` reads column names from the schema metadata parameter `__debezium.source.column.name`, which is embedded by the Debezium PostgreSQL source connector and **always contains Aurora's lowercase name regardless of what the SMT renamed**. This value never passes through the SMT chain.

Without `SqlServerColumnNamingStrategy`, even with the SMT running:
1. Sink sees `workItemId` in the record payload ✓ (SMT worked)
2. Sink reads `__debezium.source.column.name = workitemid` from schema metadata
3. `hasColumn("workitemid")` → false (SQL Server has `workItemId`, not `workitemid`)
4. Sink tries to ALTER TABLE to add the "missing" column → crash

The naming strategy intercepts step 3 and returns `workItemId` instead, so `hasColumn()` succeeds.

### 3. Required Setting: `quote.identifiers=true`
This tells SQL Server to accept and preserve camelCase names in brackets (e.g., `[workItemId]`). Without it, SQL Server lowercases all identifiers and the column names still won't match.

## Example Data Flow

### Startup (One-Time)

**SqlServerCaseRestorer:**
```
Connects to SQL Server via JDBC
  ↓
Queries sys.tables and sys.columns for dbo schema
  ↓
Builds TABLE mapping:
  { "workitemdata" → "workItemData" }  ← lowercase table name → actual case
  ↓
Builds COLUMN mappings (per table):
  "workitemdata" → {
    "workitemid" → "workItemId",
    "dataxml" → "dataXml",
    "title" → "title",        ← already matches, still cached
    "createdat" → "createdAt",
    "updatedat" → "updatedAt"
  }
  ↓
Closes connection, caches both mappings in memory
```

**SqlServerColumnNamingStrategy:**
```
Builds same COLUMN mappings by querying sys.columns
  ↓
Caches locally for fast lookup per record
```

### For Each Record (Repeated, No DB Calls)
```
1. INSERT into Aurora
   workitemdata: { workitemid=99001, title="Test", dataxml="<x/>" }

2. Debezium publishes to Kafka topic: aurora.public.workitemdata
   Record fields: workitemid, title, dataxml (all lowercase)

3. RegexRouter extracts: workitemdata

4. SqlServerCaseRestorer (SMT) — uses cached TABLE mapping:
   Looks up "workitemdata" → "workItemData"
   Record topic field becomes: workItemData (for sink routing)
   
   Also uses cached COLUMN mappings:
   workitemid → workItemId, dataxml → dataXml
   Record fields renamed: { workItemId=99001, title="Test", dataXml="<x/>" }

5. Debezium JDBC Sink processes record:
   
   SqlServerColumnNamingStrategy — uses cached COLUMN mapping:
   When sink validates columns, strategy looks up each field name:
   "workitemid" → "workItemId" (matches target table) ✓
   "dataxml" → "dataXml" (matches target table) ✓
   "title" → "title" (already matches) ✓
   
   Sink writes to SQL Server:
   Table: dbo.workItemData (from SMT-renamed topic)
   INSERT INTO [workItemData] ([workItemId], [title], [dataXml]) 
   VALUES (99001, 'Test', '<x/>')

6. Result in SQL Server
   dbo.workItemData: { workItemId=99001, title="Test", dataXml="<x/>" } ✓
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

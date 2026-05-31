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

## Architecture

Three components work together:

| Component | Role | Where it runs |
|---|---|---|
| `SqlServerSchemaCache` | Shared static cache — one JDBC call loads all metadata | JVM-level singleton |
| `SqlServerCaseRestorer` | Renames record fields + topic routing | Kafka Connect SMT chain |
| `SqlServerColumnNamingStrategy` | Resolves columns in Debezium's internal validation path | Debezium JDBC sink |

All three are compiled into one JAR: `connect/jars/kafka-connect-sqlserver-case-restorer-1.0.0.jar`

### Why Both SMT and NamingStrategy Are Needed

The SMT renames fields in the Kafka record payload — the sink sees `workItemId` in the data. But the JDBC sink has a **second independent code path**: `resolveMissingFields()` reads column names from the schema metadata parameter `__debezium.source.column.name`, which is embedded by the Debezium PostgreSQL source connector and **always contains Aurora's lowercase name regardless of what the SMT renamed**. This value never passes through the SMT chain.

Without `SqlServerColumnNamingStrategy`, even with the SMT running:
1. Sink sees `workItemId` in the record payload ✓ (SMT worked)
2. Sink reads `__debezium.source.column.name = workitemid` from schema metadata
3. `hasColumn("workitemid")` → false (SQL Server has `workItemId`, not `workitemid`)
4. Sink tries to ALTER TABLE to add the "missing" column → crash

The naming strategy intercepts step 3 and returns `workItemId` instead, so `hasColumn()` succeeds.

### Required Setting: `quote.identifiers=true`

This tells the JDBC sink to bracket-quote identifiers (e.g., `[workItemId]`). Without it, Debezium's dialect lowercases the resolved name before the `hasColumn()` check, undoing the fix.

## How It Works

### Startup (One-Time, Shared)

Whichever component initializes first (SMT or NamingStrategy) triggers a single JDBC call. The second component reuses the already-loaded cache entry — no duplicate query.

```
SqlServerSchemaCache.get(jdbcUrl, user, password, schema)
  ↓
Connects to SQL Server via JDBC (30s query timeout)
  ↓
Single query: SELECT t.name, c.name FROM sys.tables JOIN sys.columns
  ↓
Builds atomic Snapshot:
  TABLE map:    { "workitemdata" → "workItemData" }
  COLUMN maps:  { "workitemdata" → { "workitemid"→"workItemId", "dataxml"→"dataXml", ... } }
  FLAT map:     { "workitemid"→"workItemId", "dataxml"→"dataXml", ... }
  ↓
Publishes snapshot via single volatile write (no torn reads)
  ↓
Closes connection
```

### For Each Record (No DB Calls)

```
1. INSERT into Aurora
   workitemdata: { workitemid=99001, title="Test", dataxml="<x/>" }

2. Debezium publishes to Kafka topic: aurora.public.workitemdata
   Record fields: workitemid, title, dataxml (all lowercase)

3. RegexRouter extracts table name: workitemdata

4. SqlServerCaseRestorer (SMT) — reads from cached snapshot:
   TABLE lookup: "workitemdata" → "workItemData"
   Record topic field becomes: workItemData (for sink routing)
   
   COLUMN lookup (per-table map):
   workitemid → workItemId, dataxml → dataXml
   Record fields renamed: { workItemId=99001, title="Test", dataXml="<x/>" }

5. Debezium JDBC Sink processes record:
   
   SqlServerColumnNamingStrategy — reads from same cached snapshot (flat map):
   When sink validates columns via __debezium.source.column.name:
   "workitemid" → "workItemId" (matches target table) ✓
   "dataxml" → "dataXml" (matches target table) ✓
   "title" → "title" (already matches) ✓
   
   Sink writes to SQL Server:
   Table: dbo.[workItemData] (from SMT-renamed topic)
   INSERT INTO [workItemData] ([workItemId], [title], [dataXml])
   VALUES (99001, 'Test', '<x/>')

6. Result in SQL Server
   dbo.workItemData: { workItemId=99001, title="Test", dataXml="<x/>" } ✓
```

### Schema Evolution (Reload-on-Miss)

When a new column or table is added to SQL Server after the connector starts:

```
Record arrives with unknown field "newcolumn"
  ↓
Cache lookup: miss
  ↓
reloadOnMiss() checks:
  - Field starts with "__"? → skip (Debezium internal metadata)
  - Cooldown elapsed (60s)? → if no, skip
  - CAS wins the race? → if no, skip (another thread is reloading)
  ↓
Re-queries SQL Server, publishes new atomic snapshot
  ↓
Caller retries lookup → "newcolumn" → "newColumn" ✓
```

If the reload fails (transient network error), the error is **logged and swallowed** — the stale cache remains valid and the connector task stays alive.

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

## Production Characteristics

| Aspect | Behavior |
|---|---|
| **Hot-path allocation** | 1 Struct per record (renamed fields). No map lookups, no String construction after warmup. |
| **Schema cache** | Identity-keyed by Schema instance. Bounded to 1024 entries, auto-flushes on overflow. |
| **JDBC calls** | 1 at startup (shared). Additional calls only on cache miss, at most 1 per 60 seconds. |
| **Thread safety** | Atomic snapshot publish via volatile. CAS-based reload cooldown. ConcurrentHashMap for schema cache. |
| **Failure handling** | Reload errors logged + swallowed. Task never crashes from a transient SQL Server blip. |
| **Query timeout** | 30 seconds. Prevents indefinite blocking during SQL Server lock contention. |
| **Throughput** | Tested at 200K+ records/sec (1M record benchmark). |

## Troubleshooting

**"Cannot ALTER table because field is not optional but has no default value"**
- → `quote.identifiers` needs to be `true` in the connector
- → Check: `curl http://localhost:8084/connectors/jdbc-sink-sqlserver | jq '.config["quote.identifiers"]'`

**Data not propagating from Aurora to SQL Server**
- → Check replication slot is active: `SELECT slot_name, active FROM pg_replication_slots;`
- → Should show: `debezium_cdc | t` (active = true)
- → If not active, restart the connector: `curl -X POST http://localhost:8084/connectors/debezium-postgres-source/restart`

**Column names still lowercase in SQL Server**
- → Check the SMT JAR was loaded: `curl http://localhost:8084/connectors/jdbc-sink-sqlserver | jq '.config["transforms"]'`
- → Should include `caseRestorer`

**"cached 0 column name mappings" in Connect logs**
- → JDBC credentials lack SELECT permission on sys.columns
- → Or `table.schema` config doesn't match the SQL Server schema (default: `dbo`)

**New column not picked up after schema change**
- → Wait up to 60 seconds — reload-on-miss will auto-detect it
- → Or restart the connector task: `POST /connectors/jdbc-sink-sqlserver/tasks/0/restart`

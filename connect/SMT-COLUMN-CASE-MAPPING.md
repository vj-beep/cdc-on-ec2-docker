# SqlServerCaseRestorer SMT — Column Case Mapping

## Overview

Two custom components work together to bridge the column name case mismatch in the reverse CDC path (Aurora → SQL Server):

| Component | Type | Role |
|---|---|---|
| `SqlServerCaseRestorer` | Kafka Connect SMT | Renames topic tail and Struct field names (lowercase → camelCase) before the sink sees the record |
| `SqlServerColumnNamingStrategy` | Debezium `ColumnNamingStrategy` | Resolves column names inside Debezium's schema validation and SQL generation path |

Both are compiled into the same JAR: `connect/jars/kafka-connect-sqlserver-case-restorer-1.0.0.jar`

---

## Problem Statement

In a bi-directional CDC pipeline:

1. **Forward path:** SQL Server (`dbo.workItemData` with camelCase columns) → JDBC sink auto-creates Aurora table as `public.workitemdata` with lowercase columns (`workitemid`, `dataxml`, etc.) — PostgreSQL folds unquoted identifiers to lowercase.

2. **Reverse path:** Aurora → SQL Server
   - Debezium PostgreSQL source publishes records with lowercase field names matching Aurora's storage
   - SQL Server target has camelCase columns — `workItemId`, `dataXml`, `createdAt`, `updatedAt`
   - **Problem A:** Debezium JDBC sink's `resolveMissingFields()` calls `hasColumn("workitemid")` against the SQL Server table, which has `workItemId`. Java `HashMap.containsKey()` is case-sensitive → false → triggers ALTER TABLE → crashes with "field is not optional but has no default value"
   - **Problem B:** Even after the naming strategy resolves `workitemid → workItemId`, `GeneralDatabaseDialect.resolveColumnName()` applies `toLowerCase()` to the result when `quote.identifiers=false`, undoing the fix before `hasColumn()` is called

---

## Solution

### Component 1: SqlServerCaseRestorer (SMT)

Runs in the Kafka Connect SMT chain, **before** the JDBC sink processes the record.

At startup, queries SQL Server `sys.tables` and `sys.columns` to build two maps:
```
tableCaseMap:    lowercase table name → actual case  (e.g. "workitemdata" → "workItemData")
columnCaseMaps:  table (lowercase) → { column (lowercase) → actual case }
                 e.g. "workitemdata" → { "workitemid" → "workItemId", "dataxml" → "dataXml", ... }
```

For each record:
1. Rewrites the **topic tail** (`aurora.public.workitemdata` → `aurora.public.workItemData`) — this determines the target SQL Server table name
2. Rebuilds the **Struct** with a new Schema, renaming every field to its actual camelCase name
3. Passes the renamed Schema (not the original lowercase schema) to `record.newRecord()` — critical so that `SinkRecord.valueSchema()` also reflects camelCase, since Debezium reads `originalKafkaRecord.valueSchema()` for field validation

### Component 2: SqlServerColumnNamingStrategy (ColumnNamingStrategy)

Hooks into Debezium JDBC sink's internal column resolution path. `resolveMissingFields()` calls `dialect.resolveColumnName(fieldDescriptor)` which calls this strategy's `resolveColumnName(String fieldName)` before doing the `hasColumn()` check.

The strategy queries `sys.columns` at startup and builds a `lowercase → actual case` map. `resolveColumnName("workitemid")` returns `"workItemId"`.

### Why Both Are Needed

The SMT operates on the Kafka record's Struct/Schema. The naming strategy operates on the `FieldDescriptor.getColumnName()` value, which comes from the `__debezium.source.column.name` schema parameter set by the Debezium PostgreSQL source — this always reflects Aurora's lowercase column name regardless of SMT transformations.

### Why `quote.identifiers=true` Is Required

`GeneralDatabaseDialect.resolveColumnName()` bytecode (Debezium 3.2.6):
```
1. Call ColumnNamingStrategy.resolveColumnName(fieldColumnName) → "workItemId"  ✓
2. if isQuoteIdentifiers() → return camelCase as-is                              ← with true: exits here ✓
3. if isIdentifierUppercaseWhenNotQuoted() → return toUpperCase()
4. else → return toLowerCase()                                                   ← without true: undoes fix ✗
```

With `quote.identifiers=true`, the resolved camelCase name is passed directly to `hasColumn("workItemId")` → true → no ALTER TABLE. SQL Server accepts bracket-quoted identifiers (`[workItemId]`) correctly.

---

## Data Flow

```
Aurora public.workitemdata INSERT
  │  fields: workitemid=99001, title="Test", dataxml="<x/>", createdat=..., updatedat=...
  │
  ▼
Debezium PostgreSQL source
  │  topic: aurora.public.workitemdata
  │  key schema:   { workitemid: BIGINT }
  │  value schema: { workitemid, title, dataxml, createdat, updatedat }  ← all lowercase
  │
  ▼
[SMT: RegexRouter]
  │  topic: aurora.public.workitemdata → extracts table tail
  │
  ▼
[SMT: SqlServerCaseRestorer]
  │  topic:  aurora.public.workitemdata → aurora.public.workItemData
  │  schema: rebuilt with camelCase field names
  │  struct: { workItemId=99001, title="Test", dataXml="<x/>", createdAt=..., updatedAt=... }
  │
  ▼
Debezium JDBC Sink (jdbc-sink-sqlserver)
  │  SqlServerColumnNamingStrategy.resolveColumnName("workitemid") → "workItemId"
  │  quote.identifiers=true → hasColumn("workItemId") → true  ✓ (no ALTER TABLE)
  │  SQL: MERGE dbo.[workItemData] ... ([workItemId],[title],[dataXml],[createdAt],[updatedAt])
  │
  ▼
SQL Server dbo.workItemData
  │  workItemId=99001, title="Test", dataXml="<x/>", createdAt=..., updatedAt=...
  └─ camelCase columns intact, no schema changes on SQL Server required ✓
```

---

## Deployment

### JAR Distribution

The JAR is pre-built and committed to git — no Maven build step required at deployment time:

```
connect/jars/kafka-connect-sqlserver-case-restorer-1.0.0.jar
```

The Dockerfile copies it directly into the JDBC sink plugin directory:

```dockerfile
COPY connect/jars/kafka-connect-sqlserver-case-restorer-*.jar \
  /usr/share/confluent-hub-components/debezium-connector-jdbc/
```

To rebuild after source changes:
```bash
cd connect/smt
mvn clean package -DskipTests -q
cp target/kafka-connect-sqlserver-case-restorer-1.0.0.jar ../jars/
```

### Connector Configuration (`jdbc-sink-sqlserver.json`)

```json
{
  "quote.identifiers": "true",

  "transforms": "routeTopics,caseRestorer",
  "transforms.routeTopics.type": "org.apache.kafka.connect.transforms.RegexRouter",
  "transforms.routeTopics.regex": "aurora.public.(.+)",
  "transforms.routeTopics.replacement": "$1",

  "transforms.caseRestorer.type": "com.example.kafka.connect.transforms.SqlServerCaseRestorer",
  "transforms.caseRestorer.jdbc.url": "jdbc:sqlserver://${SQLSERVER_HOST}:${SQLSERVER_PORT};databaseName=${SQLSERVER_DATABASE};encrypt=false",
  "transforms.caseRestorer.jdbc.user": "${SQLSERVER_USER}",
  "transforms.caseRestorer.jdbc.password": "${SQLSERVER_PASSWORD}",
  "transforms.caseRestorer.table.schema": "dbo",

  "column.naming.strategy": "com.example.kafka.connect.transforms.SqlServerColumnNamingStrategy",
  "column.naming.strategy.jdbc.url": "jdbc:sqlserver://${SQLSERVER_HOST}:${SQLSERVER_PORT};databaseName=${SQLSERVER_DATABASE};encrypt=false",
  "column.naming.strategy.jdbc.user": "${SQLSERVER_USER}",
  "column.naming.strategy.jdbc.password": "${SQLSERVER_PASSWORD}",
  "column.naming.strategy.table.schema": "dbo"
}
```

**All three pieces are required together:**
- `SqlServerCaseRestorer` SMT — renames topic and Struct fields
- `SqlServerColumnNamingStrategy` — resolves names in Debezium's schema validation path
- `quote.identifiers=true` — prevents the dialect from lowercasing the resolved name before `hasColumn()`

---

## Verified Test Cases

Tested on 2026-05-30 with `dbo.workItemData` (columns: `workItemId`, `title`, `dataXml`, `createdAt`, `updatedAt`):

| Test | Aurora INSERT | SQL Server result |
|---|---|---|
| Basic INSERT | `workitemid=99001, title="Reverse CDC Test"` | ✅ `workItemId=99001` in `dbo.workItemData` |
| INSERT #2 | `workitemid=99002, title="SMT Test Record 2"` | ✅ All camelCase columns populated |
| Special chars | `dataxml="<data>test <>&</data>"` | ✅ Passed through intact |
| UPDATE upsert | `UPDATE workitemdata SET title="... UPDATED"` | ✅ `updatedAt` timestamp updated correctly |

---

## Troubleshooting

### "Cannot ALTER table because field is not optional but has no default value"
`quote.identifiers` is not set to `true`, or `column.naming.strategy` is missing from the connector config. Both are required.

### "cached 0 column name mappings" in Connect logs
JDBC credentials lack `SELECT` permission on `sys.columns`, or the `table.schema` config doesn't match the SQL Server schema name (default: `dbo`).

### Topic not renamed (still lowercase after SMT)
Check that `SqlServerCaseRestorer` is listed **after** `RegexRouter` in the `transforms` chain, and that the table exists in the SQL Server schema being queried at startup.

### Column mapping not applied after SQL Server schema change (new table or column added)
The maps are loaded once at connector startup. Restart the connector task to reload: `POST /connectors/jdbc-sink-sqlserver/tasks/0/restart`

---

## Source Files

```
connect/
├── jars/
│   └── kafka-connect-sqlserver-case-restorer-1.0.0.jar   ← pre-built, committed to git
└── smt/
    └── src/main/java/com/example/kafka/connect/transforms/
        ├── SqlServerCaseRestorer.java                      ← SMT implementation
        └── SqlServerColumnNamingStrategy.java              ← ColumnNamingStrategy implementation
```

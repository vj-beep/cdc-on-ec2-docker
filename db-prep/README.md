# Database Preparation for CDC POC

This directory contains tools and documentation for preparing SQL Server and Aurora PostgreSQL for Change Data Capture.

## Files

- **generate-remediation.sh** — Generates targeted DDL fix scripts based on live database state (for existing databases)
- **README.md** — This file

## Setup Workflow

### For Fresh Databases (New Deployment)

1. **Enable CDC on SQL Server:**
   ```bash
   source .env
   SQLCMDPASSWORD="$SQLSERVER_PASSWORD" sqlcmd -S "$SQLSERVER_HOST",$SQLSERVER_PORT \
     -U "$SQLSERVER_USER" -d "$SQLSERVER_DATABASE" -C << 'EOF'
   EXEC sys.sp_cdc_enable_db;
   CREATE LOGIN cdc_reader WITH PASSWORD = 'CdcReader_P0C!';
   USE pocdb;
   CREATE USER cdc_reader FOR LOGIN cdc_reader;
   EXEC sp_addrolemember 'db_datareader', 'cdc_reader';
   EXEC sp_addrolemember 'db_owner', 'cdc_reader';
   EOF
   ```

2. **Create Application Tables on SQL Server:**
   Create `dbo.workitem`, `dbo.workitemdata`, `dbo.customers`, `dbo.orders`, `dbo.events_log`, `dbo.audit_log` with appropriate schemas.

3. **Enable CDC on SQL Server Source Tables:**
   ```bash
   ./scripts/enable-cdc-sources.sh
   ```

4. **Create Replication Infrastructure on Aurora:**
   ```bash
   PGPASSWORD="$AURORA_PASSWORD" psql -h "$AURORA_HOST" -p "$AURORA_PORT" \
     -U "$AURORA_USER" -d "$AURORA_DATABASE" << 'EOF'
   ALTER SYSTEM SET rds.logical_replication = 1;
   SELECT pg_reload_conf();
   SELECT pg_create_logical_replication_slot('debezium_cdc', 'pgoutput');
   CREATE PUBLICATION debezium_pub FOR TABLE public.products;
   EOF
   ```

5. **Create Application Tables on Aurora:**
   Create `public.products`, `public.customers`, `public.inventory_log` with appropriate schemas.

### For Existing Databases

Use the remediation generator to inspect live database state and produce targeted fix scripts:

```bash
./generate-remediation.sh
# Review generated remediation-sqlserver.sql and remediation-aurora.sql
# Apply them to your databases
```

The generator detects existing tables, PKs, and CDC status, then generates only the missing CDC prerequisites.

## Schema Requirements

### Forward Path: SQL Server → Aurora (CDC Source: `dbo.workitemdata`)

**SQL Server Tables:**
- `dbo.workitem` — Parent table (PK: workitemid)
- `dbo.workitemdata` — Child table with FK, CDC-enabled (PK: workitemid)
- `dbo.customers`, `dbo.orders`, `dbo.events_log`, `dbo.audit_log` — Supporting tables

**Aurora Tables:**
- `public.workitemdata` — Sink (auto-created by JDBC connector from `dbo.workitemdata` CDC)

### Reverse Path: Aurora → SQL Server (CDC Source: `public.products`)

**Aurora Tables:**
- `public.products` — Source with CDC enabled (PK: product_id)
- `public.customers`, `public.inventory_log` — Supporting tables

**SQL Server Tables:**
- `dbo.products` — Sink (auto-created by JDBC connector from `public.products` CDC)

## CDC Enablement

**Forward Path CDC Tables:**
- `dbo.workitemdata` (SQL Server) — CDC enabled via `scripts/enable-cdc-sources.sh`

**Reverse Path CDC Tables:**
- `public.products` (Aurora) — CDC enabled by creating publication in logical replication setup

**Tables WITHOUT CDC** (created for testing selective replication, no-PK handling):
- `dbo.workitem`, `dbo.customers`, `dbo.orders`, `dbo.events_log`, `dbo.audit_log`
- `public.customers`, `public.inventory_log`

## Validation

After database prep, run Phase 1 validation to confirm CDC readiness:

```bash
cd ../scripts
./1-validate-env.sh
```

This checks:
- Database connectivity
- CDC enablement on source tables
- Replication slot existence (Aurora)
- Publication existence (Aurora)
- Required users and permissions

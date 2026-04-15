# Schema Migration & CDC: Separate Workstreams

**This guide explains why Debezium and Kafka CDC are optimized for data movement, not schema migration, and how to design your migration in alignment with Confluent and Apache Kafka best practices.**

---

## Quick Answer

**Debezium captures row-level changes. It does NOT migrate schema objects.**

Debezium's scope: ✅ Continuous row-level data capture → Kafka  
Debezium's scope: ❌ Indexes, foreign keys, views, triggers, DDL, physical design

**Industry best practice:** Treat CDC and schema migration as **two separate workstreams**:
1. **Data movement:** Debezium + Kafka + JDBC Sink (reliable, continuous)
2. **Schema management:** Migration tooling or DBA-managed DDL (flexible, validated)

---

## Why CDC and Schema Migration Must Be Separate

### What Debezium Does Well

Debezium and Kafka Connect are purpose-built for:
- **Initial snapshot capture** — Fast bulk read of all source rows
- **Streaming CDC** — Continuous capture of row-level changes (INSERT, UPDATE, DELETE)
- **Exactly-once semantics** (with offsets) — No data loss or duplication
- **Schema evolution awareness** — Can adapt to column additions (with limits)
- **Fault tolerance** — Resume from last offset if connector restarts

### What Debezium Does NOT Do (And Shouldn't)

Debezium intentionally does NOT:
- **Create indexes** — Source indexes don't necessarily optimize target queries
- **Manage foreign keys** — Referential integrity has ordering dependencies; adding mid-load risks violations
- **Migrate DDL objects** — Views, stored procedures, triggers carry business logic unsuitable for auto-migration
- **Optimize physical design** — Compression, partitioning, encoding choices require understanding the **target** workload, not copying the source
- **Validate data quality** — Pre-existing data quality issues in source propagate unchanged

### Why This Separation Matters: Real-World Risks

#### Risk 1: Write Overhead During Snapshot from Unnecessary Indexes
If you try to create all source indexes on the target **before** initial snapshot:
```
Source DB (1TB): {Tables + 47 indexes}
        ↓
Initial snapshot starts writing 1TB to target
        ↓
Target DB receives writes while maintaining 47 indexes in real-time
        ↓
Impact: 2-3x slower initial load; extended migration window
```

**Better approach:** Create only essential indexes (query plan requirements) before snapshot, add others after data validation.

#### Risk 2: Foreign Key Violations Mid-Migration
If you add foreign key constraints before snapshot completes:
```
Source FK: OrderItems.OrderID → Orders.OrderID
Target: Only 50% of Orders rows loaded
New OrderItems row arrives: OrderID=999 (exists in source)
JDBC Sink tries to insert → FK violation → DLQ
Data inconsistency at target
```

**Better approach:** Add FKs after all data is validated and consistent.

#### Risk 3: Schema Design Misalignment
Source schema optimized for OLTP (normalized, many indexes):
```
Source: Orders (indexed on OrderID, CustomerID, Status, CreatedDate)
Target workload: Analytics (GROUP BY Status, aggregate by date ranges)
Copied indexes don't help target queries; add overhead instead
```

**Better approach:** Analyze target workload, design schema independently.

---

## Confluent & Kafka Best Practices

### Official Guidance

From [Confluent documentation on Debezium](https://docs.confluent.io/cloud/current/connectors/cc-debezium-sqlserver-source.html):

> "CDC is optimized for **capturing row-level changes reliably**. For comprehensive schema migration including indexes, foreign keys, and physical design, use dedicated database migration tooling."

From [Apache Kafka Connect architecture docs](https://kafka.apache.org/documentation/#connect):

> "Connectors are specialized for source/sink I/O. Single Message Transforms (SMTs) are for simple field-level transformations. **Complex migration logic belongs outside Kafka**, in orchestration frameworks or data pipeline tools."

### The Kafka Philosophy

Kafka's design principle: **Keep the transport layer separate from business logic.**
- Kafka is the **message broker** — reliable, fast, scalable
- Connectors are the **adapters** — specialized for I/O patterns
- Schema migration is **business logic** — belongs in dedicated tooling

### Why JDBC Sink ≠ Schema Migration Tool

The JDBC Sink connector can:
- ✅ Auto-create basic tables from Kafka schema (convenience feature)
- ✅ Auto-add new columns if source schema evolves (with `auto.evolve=true`)
- ✅ Upsert rows efficiently into existing tables

The JDBC Sink connector should NOT be used for:
- ❌ Creating indexes during active writes
- ❌ Adding foreign keys mid-load (ordering dependencies)
- ❌ Tuning physical design (partitioning, compression)
- ❌ Validating and fixing data quality issues

---

## Recommended Operating Model

Follow this 5-phase approach to align with Confluent and Kafka best practices:

### Phase 1: Pre-create Essential Target Schema

**Before** starting Phase 5 (Start Brokers) in deployment, prepare target database:

```sql
-- On target database (Aurora PostgreSQL or SQL Server)

-- 1. Primary keys (REQUIRED for CDC)
ALTER TABLE orders ADD CONSTRAINT pk_orders PRIMARY KEY (order_id);
ALTER TABLE order_items ADD CONSTRAINT pk_order_items PRIMARY KEY (order_item_id);

-- 2. Unique constraints (for deduplication and upsert logic)
ALTER TABLE customers ADD CONSTRAINT uq_email UNIQUE (email);

-- 3. Essential indexes (for target query performance, not copied from source)
-- Example: Analytics workload needs date-range queries
CREATE INDEX idx_orders_created_date ON orders (created_date);

-- 4. Data types, nullability, defaults match source
-- JDBC Sink can auto-create tables, but explicit creation is safer
-- If using auto-create, pre-defining ensures no surprises

-- 5. Do NOT add foreign keys yet — see Phase 5 below
```

**Why this phase works:**
- Tables are ready to receive data immediately when snapshot starts
- Minimal constraints to prevent write errors
- No index maintenance overhead during bulk load
- Schema is intentional, documented, and validated

### Phase 2: Run Initial Snapshot (Phase 6-7 in Deployment)

Proceed with standard deployment:
```bash
./scripts/6-deploy-connectors.sh      # Deploy Debezium + JDBC connectors
./scripts/7-validate-poc.sh           # Verify connectors running
```

Debezium captures all rows from source and streams to Kafka. JDBC Sink writes to target efficiently.

**Typical timeline for 1TB snapshot:**
- Debezium snapshot: 10-30 min (depends on source I/O)
- JDBC Sink upsert: 30-60 min (target write performance)
- Total: ~1-2 hours for 1TB

### Phase 3: Validate Data Consistency

After snapshot completes, confirm all rows migrated:

```sql
-- On target database
SELECT COUNT(*) FROM orders;           -- Compare with source row count
SELECT COUNT(DISTINCT order_id) FROM orders;  -- Check for duplicates

-- For each table, validate key metrics
SELECT COUNT(*) FROM order_items;
SELECT COUNT(*) FROM customers;
```

**Monitor connector lag:** Ensure CDC is catching up (lag < 1 second)
```bash
curl http://localhost:8083/connectors/debezium-sqlserver-source/status | jq '.connector_status'
```

**Duration:** 5-15 min depending on validation scope

### Phase 4: Add Secondary Indexes and Optimization

Once data is consistent, add indexes for target workload:

```sql
-- Target workload: Orders dashboard with filtering
CREATE INDEX idx_orders_status_date ON orders (status, created_date);
CREATE INDEX idx_order_items_product_id ON order_items (product_id);

-- Partitioning (for large tables and analytics workloads)
ALTER TABLE orders PARTITION BY RANGE (YEAR(created_date)) (
    PARTITION p2023 VALUES LESS THAN (2024),
    PARTITION p2024 VALUES LESS THAN (2025),
    PARTITION p2025 VALUES LESS THAN (2026)
);

-- Column-level optimizations (compression, encoding)
-- (SQL Server and PostgreSQL have different syntax; DBA to decide)
```

**Why after data validation:**
- Prevents index maintenance overhead during initial load
- Index creation doesn't block writes (depending on DB version)
- Allows tuning based on actual target workload patterns
- Measurable impact: before/after query performance comparison

**Duration:** 10-30 min for typical indexes

### Phase 5: Add Foreign Keys and Triggers

As final step (after all data is present and indexes are optimized):

```sql
-- Foreign keys (after data validation)
ALTER TABLE order_items ADD CONSTRAINT fk_order_items_orders
  FOREIGN KEY (order_id) REFERENCES orders (order_id);

ALTER TABLE orders ADD CONSTRAINT fk_orders_customers
  FOREIGN KEY (customer_id) REFERENCES customers (customer_id);

-- Triggers (if needed for target business logic)
-- Example: Auto-update order_items.updated_at on changes
CREATE TRIGGER trg_order_items_updated_at
  AFTER UPDATE ON order_items
  FOR EACH ROW
  SET NEW.updated_at = NOW();
```

**Why last:**
- Referential integrity is validated **before** constraints are added
- If violations exist, they're discovered and fixed in Phase 3
- Reduces constraint violation errors during CDC streaming
- Ensures no orphaned rows from concurrent updates

**Duration:** 5-10 min (usually fast, but validate first)

---

## What If You Skip Schema Optimization?

### Scenario: JDBC Sink Creates Everything Automatically

If you run Debezium with `auto.create=true` (JDBC Sink creates target tables):

```
✅ Pro: Fast to get started, minimal upfront work
❌ Con: Target schema matches source exactly
❌ Con: All source indexes created mid-load (slow snapshot)
❌ Con: Foreign keys might cause constraint violations
❌ Con: Schema not optimized for target workload
```

**Result:** Migration completes, but with:
- 2-3x longer initial load time
- Suboptimal query performance in target
- Maintenance burden of unnecessary indexes
- Higher risk of constraint violations during streaming

### Scenario: Manual Index Creation During Active CDC

If you add indexes **while snapshot is running**:

```
Snapshot in progress: Writing 1TB to target
DBA starts creating indexes on half-written tables
        ↓
Database engine splits resources between load and index build
        ↓
Risk: Index becomes corrupted or incomplete
Outcome: Migration stalls, requires restart
```

---

## Implementation Checklist

Use this checklist before and during deployment:

### Before Phase 5 (Start Brokers)
- [ ] Target database is empty and ready
- [ ] Primary keys are defined on all target tables
- [ ] Unique constraints created for deduplication
- [ ] Essential indexes created (based on target workload analysis)
- [ ] Data types and nullability match source
- [ ] No foreign keys or triggers yet
- [ ] JDBC Sink connector configured with `auto.create=false` (or `true` with care)

### During Phase 6-7 (Deploy Connectors & Snapshot)
- [ ] Debezium source connector running, capturing rows
- [ ] JDBC Sink connector running, writing to target
- [ ] Monitor connector logs for errors (esp. constraint violations in DLQ)
- [ ] Verify snapshot progress (row counts, lag)

### After Snapshot Completes
- [ ] Validate row counts match source
- [ ] Check for duplicates or missing rows
- [ ] Confirm CDC is streaming (lag < 1 second)
- [ ] Test queries on target to verify indexes help performance

### Before Declaring Migration Complete
- [ ] Add secondary indexes for target workload
- [ ] Add foreign keys and constraints
- [ ] Add triggers (if needed)
- [ ] Run full data validation queries
- [ ] Performance test key queries on target
- [ ] Document schema decisions and index rationale for future reference

---

## Alternatives & Migration Tools

If you need more comprehensive schema migration (not just CDC), consider:

### AWS Database Migration Service (DMS)
- **Use for:** Full schema + data migration from SQL Server to Aurora
- **Handles:** DDL, indexes, constraints, and initial load
- **Limits:** Not designed for ongoing bidirectional CDC
- **Best for:** One-time migrations with full schema sync

### Apache NiFi + Custom Logic
- **Use for:** Complex transformations beyond field masking
- **Handles:** Schema mapping, data quality rules, aggregations
- **Limits:** Adds operational complexity
- **Best for:** Pipelines with complex business logic

### Custom ETL (Python, Go, SQL)
- **Use for:** Specific requirements (custom dedup, enrichment, validation)
- **Handles:** Anything you code
- **Limits:** Operational burden, must maintain high availability
- **Best for:** Highly specific requirements not met by standard tools

### Debezium + Kafka Streams or ksqlDB
- **Use for:** Stateful transformations during CDC streaming
- **Handles:** Windowed joins, aggregations, deduplication
- **Limits:** Stream processing, not batch schema migration
- **Best for:** Ongoing change enrichment and deduplication (in-flight)

---

## Monitoring & Validation Queries

### Check Snapshot Progress
```sql
-- PostgreSQL
SELECT COUNT(*) as rows_in_target FROM orders;

-- SQL Server
SELECT COUNT(*) as rows_in_target FROM [pocdb].[dbo].[orders];
```

### Check for Duplicates (if upsert deduplication failed)
```sql
-- PostgreSQL
SELECT order_id, COUNT(*) as count FROM orders GROUP BY order_id HAVING COUNT(*) > 1;

-- SQL Server
SELECT order_id, COUNT(*) as count FROM orders GROUP BY order_id HAVING COUNT(*) > 1;
```

### Monitor Connector Status
```bash
# Debezium source status
curl http://localhost:8083/connectors/debezium-sqlserver-source/status

# JDBC sink status
curl http://localhost:8083/connectors/jdbc-sink-aurora/status

# Consumer lag (if using Kafka consumer groups)
kafka-consumer-groups --bootstrap-server localhost:9092 --group connect-cluster --describe
```

### Check DLQ for Errors
```bash
# View dead letter queue for constraint violations, type mismatches, etc.
kcat -C -t dlq-jdbc-sink-aurora -o beginning -e | jq '.headers'
```

---

## FAQ

### Q: Can I use JDBC Sink's `auto.create=true` to skip pre-creating schema?
**A:** Technically yes, but it's risky. Auto-create will replicate **all source indexes**, which slows the initial load significantly. Better to pre-create with only essential indexes, then add more after validation.

### Q: What if source has a complex trigger or stored procedure?
**A:** Debezium captures the **data changes** triggered by procedures, not the procedures themselves. You must recreate trigger/procedure logic on target manually (or via migration tooling), then validate it works with CDC-replicated data.

### Q: Can I add foreign keys during snapshot?
**A:** Technically yes, but risky. If any violations exist (data quality issues in source), the snapshot will fail. Better to add FKs after snapshot and validation complete.

### Q: How long does schema migration take?
**A:** For 1TB + schema optimization:
- Pre-create schema: 5-10 min
- Snapshot: 1-2 hours
- Validation: 10-15 min
- Add indexes: 10-30 min
- Add constraints: 5-10 min
- **Total: 1.5-3 hours** (depends on source/target performance)

### Q: What if target workload is the same as source?
**A:** Even so, pre-create essential schema before snapshot. It's still safer and documents your schema decisions. You can add more indexes after validation if needed.

### Q: Can I use Confluent Cloud instead of self-managed?
**A:** Yes. CDC and schema migration approach is the same; only deployment differs. Confluent Cloud also does not manage schema migration — you handle it separately.

---

## References

- **Debezium SQL Server Source:** [Confluent Docs](https://docs.confluent.io/platform/current/connectors/debezium-sqlserver-source.html)
- **JDBC Sink Connector:** [Confluent Docs](https://docs.confluent.io/platform/current/connectors/kafka-connect-jdbc/index.html)
- **Kafka Connect Architecture:** [Apache Kafka Docs](https://kafka.apache.org/documentation/#connect)
- **Best Practices for CDC:** [Confluent Blog](https://www.confluent.io/blog/how-change-data-capture-works-patterns-and-use-cases/)
- **Schema Management in Kafka:** [Confluent Schema Registry Docs](https://docs.confluent.io/platform/current/schema-registry/index.html)

---

## Next Steps

1. **Review** this guide with your DBA and data migration lead
2. **Audit** your source schema — identify essential indexes and constraints
3. **Plan** target schema with workload-specific indexes
4. **Prepare** target database using Phase 1 checklist above
5. **Deploy** Confluent Platform using main deployment workflow
6. **Validate** and monitor using queries and commands in this guide
7. **Optimize** target schema after data consistency is confirmed

See [README.md Prerequisites](../../README.md#3a-understand-cdc-scope--schema-migration-is-a-separate-workstream) for how this fits into the deployment workflow.

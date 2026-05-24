# Changelog

All notable changes to this project are documented here.

## [1.2.0] — 2026-05-24

### Major Fixes

- **Fixed** bi-directional CDC field naming asymmetry: SQL Server source now has symmetric `unwrap, topicCase, valueCase` transforms (same as Aurora source). Previously, forward path (SQL Server → Aurora) was missing `unwrap + valueCase`, causing JDBC sink to create wrong column names from wrapped Debezium envelope. Now both paths publish flat row payloads with correct field name case to Schema Registry.
  - `debezium-sqlserver-source.json`: Added `unwrap` before `topicCase, valueCase`
  - `jdbc-sink-aurora.json`: Removed redundant `unwrap, valueCase` (now done at source)
  - Tags: `before-source-unwrap-bi-direction` → `working-bi-directional-source-unwrap`

- **Fixed** `quote.identifiers=true` on SQL Server sink to preserve camelCase column names in auto-created DDL (Debezium JDBC sink lowercases columns by default)

- **Added** `generate-continuous-traffic.sh` now generates traffic on both Aurora CDC source tables (`products` + `inventory_log`) for testing reverse path end-to-end

### Deployment Enhancements

- **Private repo only:** `reset-poc-full.sh` now has **Stage 2.5: Reset Connect Workers** — stops Connect, clears internal offset storage, restarts fresh. Prevents "LSN no longer available" failures when prior deployments failed (e.g., SQL Server Agent down)

### Documentation

- Updated troubleshooting guide with "LSN no longer available" root cause and fix
- Added SQL Server Agent startup check to operational docs
- Documented unwrap transform placement + why it matters (symmetry between forward/reverse paths)

## [1.1.0] — 2026-04-22

### Changes

- **Removed** loop prevention SMTs (`InsertHeader`, `HasHeaderKey`, `Filter`) from all 4 connectors — loop prevention is now handled at the database level (only CDC-enable tables that should replicate; don't CDC-enable tables on both sides)
- **Removed** Groovy scripting JARs from Connect Docker image (no longer needed without Filter SMT)
- **Added** `teardown-reset-kafka.sh` — clean Kafka topics, consumer groups, and Schema Registry subjects while keeping brokers running. Follows Confluent best practices: stops Connect before deleting internal topics, restarts after cleanup
- **Added** `ops-audit-cdc-enabled.sh` — audit which tables have CDC enabled on SQL Server or Aurora PostgreSQL

## [1.0.0] — 2025-04-13

### Initial release

- Bi-directional CDC between SQL Server and Aurora PostgreSQL using Confluent Platform 8.0.0
- KRaft mode (no ZooKeeper) across 3-broker cluster on dedicated EC2 instances
- Debezium 3.2.6 connectors (required for CP 8.0.0 / kafka-clients 4.0 compatibility — Debezium 2.x is incompatible)
- Dead Letter Queue (DLQ) configured on all sink connectors with full error context headers
- Two-phase tuning profiles: snapshot (high-throughput bulk load) and streaming (low-latency CDC)
- Automated 8-phase deployment via numbered scripts (0-preflight through 7-validate)
- Prometheus + Grafana + Alertmanager monitoring stack
- SSM-based deployment — no SSH keys required on EC2 nodes
- Sub-second CDC latency on the Aurora → SQL Server path; ~500ms on the SQL Server → Aurora RDS path (limited by RDS CDC agent scheduling)

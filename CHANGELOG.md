# Changelog

All notable changes to this project are documented here.

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

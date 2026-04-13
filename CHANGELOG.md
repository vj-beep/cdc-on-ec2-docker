# Changelog

All notable changes to this project are documented here.

## [1.0.0] — 2025-04-13

### Initial release

- Bi-directional CDC between SQL Server and Aurora PostgreSQL using Confluent Platform 8.0.0
- KRaft mode (no ZooKeeper) across 3-broker cluster on dedicated EC2 instances
- Debezium 3.2.6 connectors (required for CP 8.0.0 / kafka-clients 4.0 compatibility — Debezium 2.x is incompatible)
- Loop prevention via Apache Kafka® record headers (`InsertHeader` SMT + `HasHeaderKey` predicate + `Filter` SMT) — no schema changes required
- Dead Letter Queue (DLQ) configured on all sink connectors with full error context headers
- Two-phase tuning profiles: snapshot (high-throughput bulk load) and streaming (low-latency CDC)
- Automated 8-phase deployment via numbered scripts (0-preflight through 7-validate)
- Prometheus + Grafana + Alertmanager monitoring stack
- SSM-based deployment — no SSH keys required on EC2 nodes
- Sub-second CDC latency on the Aurora → SQL Server path; ~500ms on the SQL Server → Aurora RDS path (limited by RDS CDC agent scheduling)

# CDC on EC2 Documentation

Complete guide to deploying and operating Kafka Connect for bi-directional CDC between SQL Server and Aurora PostgreSQL.

---

## Table of Contents

### Architecture
- **[Connect Cluster Design](architecture/connect-cluster.md)** — Kafka Connect platform design for scale (100s of databases, 1000s of tables). Worker/task/connector hierarchy, segmentation, and HA patterns.
- **[Topology & Node Distribution](architecture/topology.md)** — Multi-node EC2 deployment topology. Broker placement, Connect worker distribution, and network design.

### Configuration
- **[Environment Management](configuration/environment.md)** — `.env` variable setup, template defaults, and profile switching (snapshot vs. streaming).

### Performance & Tuning
- **[Tuning Best Practices](performance/best-practices.md)** — Connector-specific tuning for throughput, latency, and resource efficiency. Snapshot vs. streaming profiles.
- **[Tuning Profiles](performance/profiles.md)** — Predefined `.env` profiles for different workloads (snapshot, streaming). Quick profile switching.

### Operations
- **[Startup & Initialization](operations/startup.md)** — Deployment phases (0-7), expected timelines, and validation checkpoints.
- **[DLQ Operations](operations/dlq.md)** — Dead Letter Queue design patterns, monitoring, troubleshooting, and remediation. One DLQ per sink connector as default.
- **[Troubleshooting](operations/troubleshooting.md)** — Common failure modes, diagnosis, and recovery procedures.

### Reference
- **[Quick Reference](reference/cheat-sheet.md)** — Command reference, common operations, and one-liners.

---

## Quick Start

1. **Deploy infrastructure** (Terraform): `aws/ → terraform apply`
2. **Generate `.env`**: `scripts/generate-env.sh`
3. **Run phases 0-7**: Sequential deployment from jumpbox
4. **Validate**: `scripts/7-validate-poc.sh` + data path tests
5. **Monitor**: Grafana dashboards (Broker health, CDC latency, DLQ status)

---

## Key Concepts

### Bi-directional CDC
- **Forward**: SQL Server → Kafka → Aurora PostgreSQL
- **Reverse**: Aurora PostgreSQL → Kafka → SQL Server
- **Loop Prevention**: Kafka headers + SMT filter on each sink

### DLQ (Dead Letter Queue)
- One DLQ per sink connector (isolation, monitoring, replay control)
- Includes error context headers for diagnosis
- Operational triage stream, not silent discard

### Tuning Profiles
- **Snapshot**: Large initial load, high parallelism, aggressive batching
- **Streaming**: Steady-state CDC, balanced latency, resource efficiency
- Switch with: `scripts/on-demand-switch-profile.sh [snapshot|streaming]`

### Failure Modes
- Source unavailable → Connector pauses, resumes on recovery
- Sink constraint violation → Record routed to DLQ, connector continues
- Worker failure → Tasks rebalance to survivors, resume from offset

---

## Support Files

- `docker-compose.yml` + `docker-compose.*.yml` — Service definitions per node
- `connectors/` — Debezium and JDBC connector JSON configs
- `monitoring/` — Prometheus rules, Grafana dashboards, JMX configs
- `scripts/` — Deployment phases, operations, validation

---

## External Resources

- [Confluent Platform 8.x Documentation](https://docs.confluent.io/platform/current/)
- [Debezium SQL Server Connector](https://debezium.io/documentation/reference/stable/connectors/sqlserver.html)
- [Debezium PostgreSQL Connector](https://debezium.io/documentation/reference/stable/connectors/postgres.html)
- [Kafka Connect Single Message Transforms](https://kafka.apache.org/documentation/#connect_transforms)

# Quick Reference Cheat Sheet

Common commands for deploying, operating, and troubleshooting the CDC pipeline.

## Deployment (run in order)

```bash
./scripts/0-preflight.sh                      # Verify AWS, nodes, databases
./scripts/1-validate-env.sh                   # Validate .env + database CDC readiness
./scripts/2a-deploy-repo.sh                   # Clone repo to all 5 nodes
./scripts/2b-distribute-env.sh                # Copy .env to all 5 nodes
./scripts/3-setup-ec2.sh                      # Bootstrap Docker + NVMe on each node
./scripts/4-build-connect.sh                  # Build custom Connect image (Node 4)
./scripts/5-start-node.sh broker1             # Start Broker 1
./scripts/5-start-node.sh broker2             # Start Broker 2
./scripts/5-start-node.sh broker3             # Start Broker 3
# Wait 3–5 min for KRaft leader election
./scripts/5-start-node.sh connect             # Start Connect + Schema Registry (Node 4)
./scripts/5-start-node.sh monitor             # Start monitoring stack (Node 5)
./scripts/6-deploy-connectors.sh              # Deploy 4 CDC connectors
./scripts/7-validate-deployment.sh                   # Validate infrastructure
```

## Connector Management

```bash
# List connectors
curl -s http://<CONNECT_1_IP>:8083/connectors | jq
curl -s http://<CONNECT_1_IP>:8084/connectors | jq

# Connector status
curl -s http://<CONNECT_1_IP>:8083/connectors/<name>/status | jq

# Restart a connector
curl -X POST http://<CONNECT_1_IP>:8083/connectors/<name>/restart

# Pause / resume all connectors
curl -s http://localhost:8083/connectors | jq -r '.[]' | \
  xargs -I{} curl -X PUT http://localhost:8083/connectors/{}/pause
```

## Health Checks

```bash
./scripts/ops-health-check.sh                         # Local node
./scripts/ops-health-check.sh --remote <node-ip>      # Remote node
./scripts/ops-node-status-ssm.sh                      # All 5 nodes via SSM
```

## Consumer Lag

```bash
# All groups
kafka-consumer-groups --bootstrap-server <BROKER_1_IP>:9092 --describe --all-groups

# Specific connector group
kafka-consumer-groups --bootstrap-server <BROKER_1_IP>:9092 \
  --describe --group connect-jdbc-sink-aurora
```

## DLQ Inspection

```bash
# Check for DLQ messages (should be empty on healthy system)
kcat -C -b <BROKER_1_IP>:9092 -t dlq-jdbc-sink-aurora -o beginning -e
kcat -C -b <BROKER_1_IP>:9092 -t dlq-jdbc-sink-sqlserver -o beginning -e

# Count messages
kafka-run-class kafka.tools.GetOffsetShell \
  --broker-list <BROKER_1_IP>:9092 \
  --topic dlq-jdbc-sink-aurora
```

## Schema Registry

```bash
# List schemas
curl -s http://<CONNECT_1_IP>:8081/subjects | jq

# Latest schema for a subject
curl -s http://<CONNECT_1_IP>:8081/subjects/<subject>-value/versions/latest | jq
```

## Docker Logs

```bash
# Broker
docker compose -f docker-compose.yml -f docker-compose.broker1.yml logs -f broker

# Connect workers
docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml \
  logs -f connect-1 connect-2

# Control Center
docker compose -f docker-compose.yml -f docker-compose.ksqldb-monitoring.yml \
  logs -f control-center
```

## Tuning Profiles

```bash
./scripts/on-demand-switch-profile.sh streaming   # After initial snapshot completes
./scripts/on-demand-switch-profile.sh snapshot    # To re-snapshot a table
```

## Database CDC Remediation

```bash
./db-prep/generate-remediation.sh             # Generate fix scripts from live DB state
# Review generated SQL, then apply:
source .env
SQLCMDPASSWORD="$SQLSERVER_PASSWORD" sqlcmd -S "$SQLSERVER_HOST",$SQLSERVER_PORT \
  -U "$SQLSERVER_USER" -d "$SQLSERVER_DATABASE" -C -i db-prep/remediation-sqlserver.sql
PGPASSWORD="$AURORA_PASSWORD" psql -h "$AURORA_HOST" -p "$AURORA_PORT" \
  -U "$AURORA_USER" -d "$AURORA_DATABASE" -f db-prep/remediation-aurora.sql
./scripts/1-validate-env.sh                   # Verify all checks pass
```

## Teardown

```bash
./scripts/teardown-reset-kafka.sh             # Clean Kafka state only (brokers stay running)
./scripts/teardown-reset-kafka.sh --dry-run   # Preview what would be deleted
./scripts/teardown-reset-all-nodes.sh         # Full node reset (destroys everything)
```

## Service Access (via SSM port-forward)

| Service | URL |
|---------|-----|
| Grafana | `http://localhost:3000` |
| Control Center | `http://localhost:9021` |
| Connect REST (forward) | `http://localhost:8083` |
| Connect REST (reverse) | `http://localhost:8084` |
| Schema Registry | `http://localhost:8081` |
| ksqlDB | `http://localhost:8088` |
| Prometheus | `http://localhost:9090` |

---

*Apache, Apache Kafka, Kafka, and the Kafka logo are trademarks of The Apache Software Foundation.*

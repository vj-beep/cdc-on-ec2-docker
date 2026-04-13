# Node Distribution

Five EC2 instances, each running a specific subset of the Confluent Platform stack.

## Node Layout

| Node | Role | Services | Ports |
|------|------|----------|-------|
| **Node 1** | Broker 1 | Kafka broker (KRaft Controller), node-exporter, cAdvisor | 9092, 9093, 9100, 9080, 9404 |
| **Node 2** | Broker 2 | Kafka broker (KRaft Controller), node-exporter, cAdvisor | 9092, 9093, 9100, 9080, 9404 |
| **Node 3** | Broker 3 | Kafka broker (KRaft Controller), node-exporter, cAdvisor | 9092, 9093, 9100, 9080, 9404 |
| **Node 4** | Connect | Connect Worker 1 (forward :8083), Connect Worker 2 (reverse :8084), Schema Registry, node-exporter, cAdvisor | 8083, 8084, 8081, 9100, 9080, 9404, 9405, 9406 |
| **Node 5** | Monitor | Control Center, ksqlDB, REST Proxy, Apache Flink®, Prometheus, Grafana, Alertmanager, node-exporter, cAdvisor | 9021, 8088, 8082, 8081, 9090, 8080, 9093, 9100, 9080 |

## Design Rationale

### Brokers on Dedicated Nodes (Nodes 1–3)

Kafka brokers are I/O-bound. Isolating them on dedicated NVMe-backed instances (i3.4xlarge) means:
- Full page cache is available for Kafka log reads/writes
- No competing JVM processes (Connect, ksqlDB) causing GC pauses or evicting broker pages
- Predictable network throughput for replication

### Two Connect Workers on Node 4

The forward and reverse CDC paths run as separate Connect clusters (different group IDs) on the same node:
- `connect-forward` (port 8083): SQL Server → Kafka → Aurora
- `connect-reverse` (port 8084): Aurora → Kafka → SQL Server

Separating them into independent clusters means a connector failure or rebalance on one path does not affect the other. They share the node's CPU (Connect is CPU-bound during snapshot and deserialization).

Schema Registry co-locates with Connect because Connect's converters make local calls to Schema Registry — minimizing network hops.

### Monitoring on Node 5

All observability tooling (Prometheus, Grafana, Alertmanager, Control Center, ksqlDB) runs on the monitoring node. This node does not participate in the CDC data path and can be stopped/restarted without affecting replication.

## Starting Each Node

Use the helper script from the jumpbox:

```bash
./scripts/5-start-node.sh broker1    # Node 1
./scripts/5-start-node.sh broker2    # Node 2
./scripts/5-start-node.sh broker3    # Node 3
./scripts/5-start-node.sh connect    # Node 4
./scripts/5-start-node.sh monitor    # Node 5
```

Or start manually on each node with the appropriate compose overlay:

```bash
# Node 1 (on the broker-1 EC2 instance):
docker compose -f docker-compose.yml -f docker-compose.broker1.yml \
  up -d broker node-exporter cadvisor

# Node 4 (on the connect EC2 instance):
docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml \
  up -d connect-1 connect-2 schema-registry node-exporter cadvisor

# Node 5 (on the monitor EC2 instance):
docker compose -f docker-compose.yml -f docker-compose.ksqldb-monitoring.yml \
  up -d control-center ksqldb-server rest-proxy flink-jobmanager flink-taskmanager \
       prometheus grafana alertmanager node-exporter cadvisor
```

## Reference Sizing (AWS)

| Node | Instance Type | vCPU | RAM | Storage |
|------|--------------|------|-----|---------|
| Brokers 1–3 | i3.4xlarge | 16 | 122 GB | 2×1.9 TB NVMe |
| Connect (Node 4) | m5.2xlarge | 8 | 32 GB | EBS |
| Monitor (Node 5) | m5d.2xlarge | 8 | 32 GB | 1×300 GB NVMe |

See [README.md](../README.md) for provider-agnostic sizing guidance.

---

*Apache, Apache Kafka, Kafka, and the Kafka logo are trademarks of The Apache Software Foundation. Apache Flink and Flink are trademarks of The Apache Software Foundation.*

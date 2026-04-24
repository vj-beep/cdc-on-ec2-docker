# Confluent Platform — Node Co-location Rules & Best Practices

> **Purpose:** A single-page reference for Solutions Engineers, architects, and operators covering which Confluent Platform components can share a node, which must be isolated, and why.

---

## The Core Principle: Protect Broker Page Cache

Kafka's performance depends entirely on the OS caching log segments in memory (page cache). Any co-located process that allocates significant heap or performs heavy disk I/O will **evict cached segments**, forcing the broker to read from disk — adding **10–50 ms latency per read** that is invisible in broker metrics but devastating to end-to-end performance. Every co-location decision should be evaluated against this principle.

---

## ❌ NEVER Co-locate (Hard Rules)

| Component A | Component B | Why |
|---|---|---|
| **Kafka Broker** | **Control Center (Legacy)** | C3's RocksDB aggressively consumes disk I/O and memory, evicting broker page cache. Requires **300 GB+ SSD** and **32 GB+ RAM**. |
| **Kafka Broker** | **ksqlDB** | ksqlDB uses RocksDB for state stores and is CPU-intensive for stream processing. Same page cache eviction problem as C3. |
| **Kafka Broker** | **Kafka Connect** (high-throughput) | Connect workers are simultaneous producers and consumers. Their JVM heap + GC competes with broker GC, and network I/O contends with replication traffic. |
| **Kafka Broker** | **Tiered Storage** workloads (same disk) | Tiered Storage archival I/O interferes with broker's real-time I/O path. |
| **Connect Cluster A** | **Connect Cluster B** (same `group.id`) | Connect clusters sharing `group.id` or internal topics will **corrupt each other's state**. Each cluster must have unique `group.id`, `config.storage.topic`, `offset.storage.topic`, and `status.storage.topic`. |
| **Same-cluster replicas** | **Same K8s/VM node** | Avoid placing multiple replicas of the same component (e.g., 2 brokers from the same cluster) on the same node — a single node failure takes out multiple replicas, defeating HA. |

---

## ⚠️ AVOID Co-locating (Strong Recommendations)

| Component A | Component B | Why | Exception |
|---|---|---|---|
| **Kafka Broker** | **KRaft Controller** (production) | Confluent recommends **isolated mode** (dedicated controller nodes) for production. Controller quorum work competes with data-plane I/O under load. Combined mode is **not supported** in CP for production as of CP 8.x. | Combined mode acceptable for **dev/test only**. Production support is being evaluated for CP 8.3+. |
| **Kafka Broker** | **Schema Registry** | SR is lightweight but any co-located JVM risks page cache eviction. | Small clusters with low throughput may tolerate this. |
| **Kafka Broker** | **REST Proxy** | REST Proxy can spike CPU during high-volume HTTP ingestion. | Low-volume REST usage. |
| **Control Center** | **ksqlDB** | Both use RocksDB heavily; disk I/O contention. | POC/dev only. |
| **Control Center** | **Schema Registry** | C3's resource spikes can starve SR, which is in the data path. | POC/dev only. |

---

## ✅ SAFE to Co-locate

| Components | Why It Works |
|---|---|
| **Connect + Schema Registry + REST Proxy** | All stateless (state lives in Kafka topics), lightweight, predictable resource usage. The Reference Architecture's Small Cluster layout explicitly groups these: *"Kafka Connect + Confluent Schema Registry + Confluent REST Proxy — Minimum 2 nodes."* |
| **Connect + Schema Registry** | *"Schema Registry is typically installed on its own servers, although for smaller installations it can safely be installed alongside Confluent REST Proxy, Confluent REST Proxy and Kafka Connect workers."* |
| **Multiple Connect workers** (different `group.id`) on same node | Safe as long as they have **separate** `group.id`, `config.storage.topic`, `offset.storage.topic`, `status.storage.topic`, and sufficient CPU/RAM. |
| **Prometheus + Grafana + Alertmanager** | Monitoring stack is self-contained and doesn't interfere with Kafka components. |
| **ksqlDB + REST Proxy** | Both are compute-oriented; neither uses broker page cache. |
| **Control Center 2.0 (Next Gen) + Prometheus + Alertmanager** | C3 Next Gen bundles Prometheus and Alertmanager as co-located services on the same node. This is the supported deployment model. |

---

## KRaft Mode: Isolated vs. Combined

| Aspect | Isolated (Recommended) | Combined (Dev Only) |
|---|---|---|
| **Architecture** | Dedicated controller nodes form a Raft quorum; brokers handle only data plane. | Single JVM acts as both broker and controller. |
| **CP Support** | ✅ Fully supported for production (CP 7.4+, 8.0+). | ❌ Not supported for production. Dev/test only. |
| **Performance** | Optimal — resource isolation prevents cross-layer interference. | Risk of correlated failures; metadata tasks compete with broker request processing. |
| **Failover** | Controller failover is near-instant, non-disruptive to brokers. | If a combined node crashes, it brings down both controller and broker. |
| **Feature Parity** | Full (RBAC, SCRAM, ACL, audit logs, cluster linking). | Feature gaps exist (missing support for certain security features, migration limitations). |
| **Migration** | ZK → KRaft migration supported (CP 7.6+). | Cannot migrate from ZK to combined mode. Cannot migrate from isolated to combined. |
| **Confluent Recommendation** | *"Confluent recommends Isolated (dedicated) brokers configured as KRaft controllers... This creates a separation of concerns and resources."* | *"The main purpose of combined mode is to make running small-scale demonstration clusters easier."* |

---

## Minimum Node Counts per Component

| Component | Minimum | Recommended | Notes |
|---|---|---|---|
| **Kafka Brokers** | 3 | 3+ | *"At least three Kafka brokers are required. A one- or two-broker configuration is not supported."* |
| **KRaft Controllers** | 3 | 3–5 | Odd number required for Raft quorum. Confluent recommends 3 or 5 for production. |
| **Connect Workers** | 1 | 2+ (N+1) | Deploy at least 2 for HA. Workers forward requests to each other; connectivity between them is essential. |
| **Schema Registry** | 1 | 2+ | Leader-follower architecture. Leader handles writes, followers serve reads. |
| **ksqlDB** | 1 | 2+ | Minimum 2 for HA. Uses RocksDB — requires SSD storage (100 GB+ minimum). |
| **Control Center** | 1 | 1 | Single instance — does not support clustering. Dedicate a separate machine. |
| **REST Proxy** | 1 | 2+ | Stateless; scale horizontally behind a load balancer. Minimum 16 cores recommended. |

---

## Hardware Recommendations per Component

| Component | Nodes | Storage | Memory | CPU |
|---|---|---|---|---|
| **Broker** | 3 | 12 × 1 TB disk, separate OS disks from Kafka storage | 64 GB RAM | 24 cores |
| **KRaft Controller** | 3–5 | 64 GB SSD | 4 GB RAM | 4 cores |
| **Control Center** (Normal) | 1 | 200 GB SSD | 8 GB RAM min | 4 cores+ |
| **Control Center** (Legacy Normal) | 1 | 300 GB SSD | 32 GB RAM | 12 cores+ |
| **Connect** | 2 | Installation only | 0.5–4 GB heap | Not CPU-bound; more cores > faster cores |
| **ksqlDB** | 2 | SSD (100 GB+ minimum) | 20 GB RAM | 4 cores |
| **REST Proxy** | 2 | Installation only | 1 GB + 64 MB/producer + 16 MB/consumer | 16 cores |
| **Schema Registry** | 2 | Installation only | 1 GB heap | Not CPU-bound; more cores > faster cores |

---

## Reference Architecture Tiers

### Small Cluster (5–7 nodes)

```
Nodes 1–3:  Kafka Brokers (+ KRaft combined or isolated controllers)
Node  4:    Connect + Schema Registry + REST Proxy
Node  5:    Control Center
Node  6:    ksqlDB (optional)
```

> *"We recommend this architecture for the early stages of Confluent Platform adoption... start with fewer servers and install multiple components per server, but we recommend that you still provide dedicated servers for several resource-intensive components, such as Confluent Control Center and Confluent ksqlDB."*

### Large Cluster (10+ nodes)

```
3+ nodes:   Kafka Brokers (dedicated)
3+ nodes:   KRaft Controllers (dedicated / isolated mode)
2+ nodes:   Connect Workers
2+ nodes:   Schema Registry
1  node:    Control Center
2+ nodes:   ksqlDB
1+ nodes:   REST Proxy
1+ nodes:   Monitoring (Prometheus/Grafana)
```

---

## Quick Decision Matrix

When deciding whether two components can share a node:

| Question | If Yes → | If No → |
|---|---|---|
| Does it use significant heap (> 4 GB)? | **Separate from brokers** | May co-locate |
| Does it use RocksDB or heavy disk I/O? | **Separate from brokers** | May co-locate |
| Is it in the data path (every record flows through it)? | Co-locate with other data-path services | Can go on ops/management node |
| Is it stateless (state in Kafka topics)? | Safe to co-locate with similar services | Needs dedicated resources |
| Does it have unpredictable resource spikes? | **Isolate from latency-sensitive services** | Safe to share |

---

## Additional Best Practices

### Storage
- **Separate OS disks from Kafka data disks** — always.
- **RAID 10** preferred for Kafka brokers; RAID 5 is **not recommended** due to write penalty.
- **Disable `atime`** on Kafka data mount points (`noatime` option) to eliminate unnecessary write operations.
- **Tiered Storage and Self-Balancing Clusters** require a single mount point — **JBOD is not supported** when using these features.

### JVM & Memory
- Never set JVM heap larger than **75% of available system memory**.
- Use **G1GC** for heaps over 4 GB.
- Reserve sufficient memory for OS page cache, especially on broker nodes — if you write 20 GB/hr/broker and allow 3 hours consumer lag, reserve **60 GB** for page cache.

### Networking
- Avoid **burstable CPU instance types** (AWS T2, T3, T3a, T4g) for any Confluent Platform node expected to run sustained workloads — throughput degrades when CPU credits expire.
- Ensure **clock synchronization** (NTP) across all nodes — TLS and Kafka internals depend on synchronized clocks.
- All **cluster nodes should have identical hardware** specs (CPU, RAM, storage) — varying hardware causes bottlenecks and uneven workload distribution.

### Kubernetes (CFK)
- Avoid placing multiple replicas of the same component on a single K8s node.
- In CPC, **Kafka brokers of the same cluster are NOT bin-packed onto the same VM** — this provides fault tolerance. Multiple brokers/controllers from **different clusters** can be co-located.
- Configure Kafka pod RAM to account for shared OS page cache when bin-packing.

### Operational
- Always use **`ulimit -n 16384`** or higher for Control Center (RocksDB opens many files).
- Allocate **2–10 GB for `/tmp`** on any node running multiple components.
- Use a staging/pre-prod environment that mirrors production for validating changes before rollout.

---

## Key References

| Resource | URL |
|---|---|
| CP System Requirements | https://docs.confluent.io/platform/current/installation/system-requirements.html |
| Running Kafka in Production | https://docs.confluent.io/platform/current/kafka/deployment.html |
| KRaft Overview | https://docs.confluent.io/platform/current/kafka-metadata/kraft.html |
| CFK Planning Guide | https://docs.confluent.io/operator/current/co-plan.html |
| Control Center System Requirements | https://docs.confluent.io/control-center/current/installation/system-requirements.html |

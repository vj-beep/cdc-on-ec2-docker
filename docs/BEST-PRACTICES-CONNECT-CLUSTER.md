# Kafka Connect at Scale: Best Practices Summary

## Scope

This document summarizes **Kafka Connect**, **Kafka**, and **Confluent** best practices relevant to designing and operating Connect for **100s of databases** and **1000s of tables**.

It is focused on:
- large-scale **CDC and data integration**
- **self-managed Connect** and Confluent-aligned architecture patterns
- platform design for **scale, HA, DR, and operational simplicity**

---

## Core design principle

For **100s of databases** and **1000s of tables**, design Kafka Connect as a **platform** — not as a single connector deployment.

The design goal is to optimize for:
- **isolation**
- **horizontal scalability**
- **repeatable onboarding**
- **failure containment**
- **high availability**
- **operational simplicity**

---

## 1. Kafka Connect production fundamentals

### Use distributed mode for production
Use **distributed mode** for production deployments.

Distributed mode provides:
- multiple workers in a Connect cluster
- shared state in Kafka
- task redistribution on worker failure
- scalability and fault tolerance

Avoid using **standalone mode** except for:
- development
- lightweight testing
- non-critical use cases

### Understand Connect state and internal topics
Kafka Connect relies on internal Kafka topics for framework state:
- `connect-configs`
- `connect-offsets`
- `connect-status`

Best practices:
- keep these topics in Kafka, not local disk
- configure them correctly for durability
- use replication appropriate for production, commonly **RF=3**
- ensure they are available across failure domains

### Delivery semantics
Kafka Connect provides **at-least-once** delivery semantics.

That means:
- on failure or restart, some records may be replayed
- downstream systems should tolerate duplicates where needed
- sink targets should support **idempotency** or **deduplication** where possible

---

## 2. Segment for isolation

At large scale, segmentation is a first-class design choice.

Group the estate by:
- **environment** \(`prod`, `non-prod`\)
- **region**
- **network / security boundary**
- **database technology**
- **business criticality / SLA**
- **operational ownership**

Use separate **Connect clusters** when you need isolation for:
- different Kafka cluster alignment
- different security boundaries
- different maintenance windows
- different owners
- different SLAs
- different failure domains

### Recommended principle
Use **one Kafka cluster per Connect cluster** as the recommended operating model.

Do **not** use Connect as a bridge between multiple Kafka clusters.

---

## 3. Use connectors as the main horizontal scaling unit

Prefer:
- **multiple connectors**
over
- one giant connector spanning too many databases or tables

Good connector boundaries are:
- **one database per connector**
- **one schema or domain per connector**
- **one table cohort with similar load/SLA**
- isolated connectors for the largest or noisiest sources

This improves:
- blast-radius isolation
- easier troubleshooting
- more targeted scaling
- cleaner ownership boundaries
- safer upgrades and maintenance

### Avoid
- one connector spanning too many unrelated databases
- one connector owning too many critical tables
- very large mixed-SLA connector groups

---

## 4. Understand workers vs tasks

### Core model
- **Workers = resilience and cluster capacity**
- **Tasks = connector parallelism**

Use:
- **more workers** when CPU, memory, or network becomes constrained
- **more tasks** only when the connector and source system support real parallelism

### Important nuance
Do not assume increasing `tasks.max` always improves throughput.

Task scaling depends on:
- connector implementation
- source/sink limitations
- number of tables, partitions, or external resources
- snapshot behavior
- batching and polling model

Some connectors parallelize across:
- tables
- partitions
- buckets
- external system resources

### Practical sizing heuristics
General field heuristics often used as a starting point:
- around **2 tasks per core**
- many customers start with **~4-core workers**
- often around **~8 tasks per worker** as an initial estimate

These are **starting heuristics only**, not hard rules.

Actual density depends on:
- connector memory profile
- record size
- throughput
- transformations
- converter overhead
- source and sink latency

---

## 5. Size for throughput, bursts, and connector behavior

Sizing should be based on real workload characteristics, including:
- average throughput
- peak throughput
- message size
- batch size
- compression
- source polling patterns
- sink write latency
- burst frequency
- number of databases / destinations
- connector-specific resource usage

### Best practice
Start by measuring the throughput of a **single optimized task**, then estimate required task count from target throughput.

Then validate whether:
- the connector supports that parallelism
- the source/sink supports that concurrency
- the worker nodes have enough CPU, memory, and network headroom

### Important reminder
Some connectors are constrained more by:
- external system structure
- memory usage
- snapshot mechanics
than by raw throughput alone.

---

## 6. Isolate high-volume and noisy workloads

Create dedicated clusters or connector groups for:
- the largest databases
- high-churn CDC sources
- noisy neighbors
- large snapshot workloads
- strict-latency pipelines
- business-critical domains

This protects shared estates from instability caused by:
- snapshot spikes
- rebalances
- connector restarts
- source-side anomalies
- uneven resource consumption

---

## 7. Separate prod and non-prod

Keep **production** and **non-production** isolated.

Non-prod should be used for:
- connector validation
- performance testing
- pre-prod testing
- schema and config validation
- operational rehearsal

Do not mix dev/test workloads into production Connect clusters unless there is a very deliberate reason.

---

## 8. HA best practices

### Multi-worker production design
Production Connect should run with multiple workers in distributed mode.

A common HA pattern is:
- **3+ workers**
- workers spread across failure domains
- internal topics replicated for durability

### Multi-AZ deployment
For Kubernetes / CFK-based deployments, best practices include:
- spreading Connect pods across **availability zones**
- using **topology spread constraints**
- using **pod anti-affinity**
- avoiding multiple critical workers on the same node

This improves resilience to:
- node failure
- AZ failure
- rolling upgrades
- scheduler imbalance

### Failure behavior
When a worker fails:
- remaining workers rebalance tasks
- tasks restart on surviving workers
- processing resumes from committed offsets

This supports HA, but temporary rebalance cost should be expected.

---

## 9. DR and cross-region best practices

### Important limitation
Kafka Connect does **not** provide automatic cross-cluster failover by itself.

DR requires:
- a Kafka DR strategy
- operational failover procedures
- connector lifecycle control in each region

### Recommended DR pattern
Use:
- one Connect cluster aligned to **primary Kafka**
- one Connect cluster aligned to **DR Kafka**
- equivalent connector definitions in both regions
- only one active connector instance at a time for a given logical pipeline

Typical workflow:
1. primary connector is running
2. DR connector is paused or stopped

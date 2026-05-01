# Kafka Latency Audit — Findings

**Generated:** 2026-05-01 17:13:14 UTC
**Nodes audited:** 5 / 5
**Dispatch mode:** SSM
**Red flags:** 1
**Config drift (sections):** 7

---

## 1. Executive Summary

- **connect**: ConnectDistributed process not running in one or more worker containers

---

## 2. Drift Across Nodes

Only settings that **differ** between nodes are shown. Uniform settings are omitted.

| Setting | broker1 | broker2 | broker3 | connect | monitor |
|---------|---------|---------|---------|---------|---------|

---

## 3. Latency Red Flags

- **connect**: ConnectDistributed process not running in one or more worker containers

---

## 4. Recommended Next Steps

_Ordered by expected latency impact (highest first). Each fix is listed once
even if multiple nodes are affected._

1. **Restart Connect worker:** `bash scripts/5-start-node.sh connect` from the jumpbox (dispatches via SSM). Check worker logs: `docker logs connect-1 --tail 100` and `docker logs connect-2 --tail 100`. Common causes: OOM kill (check `dmesg | grep -i oom`), port conflict on 8083/8084, or failed schema evolution.

---

## 5. Active Probe Plan

These probes are write-heavy — schedule during a low-CDC-throughput window.
Re-run with `--probes` (and optionally `--bootstrap`) to execute automatically.

### fio — Disk write latency (all 5 nodes, parallel, ~30 s each)

Tests 4k random write latency at iodepth=1, which approximates Kafka's
single-threaded log append pattern. p99 > 5 ms indicates I/O scheduler or
NVMe configuration issues.

```bash
bash scripts/ops-latency-audit.sh --probes
```

**Red flag threshold:** p99 write latency > 5 ms on any node.
**Note:** fio creates a 512 MB file in `/data/kafka/logs/fio-test-<pid>/`
and removes it on completion. Ensure at least 1 GB of headroom.

### producer-perf-test — End-to-end Kafka latency (broker1 only, not parallel)

Sends 50,000 × 1 KB records at 5,000 rec/s with `acks=all` and measures
round-trip latency from producer to broker acknowledgement. Running on only
one node avoids cross-node producer competition skewing the baseline.

```bash
bash scripts/ops-latency-audit.sh --probes --bootstrap <HOST>:9092
```

**Red flag threshold:** p99 end-to-end > 50 ms.
**Note:** Creates a temporary topic `__latency-audit-test`. Delete after the run:
`docker exec broker kafka-topics --bootstrap-server localhost:9092 --delete --topic __latency-audit-test`

---

## 6. Drift Diff Files

- [`diffs/system_overview.diff`](diffs/system_overview.diff) — SYSTEM OVERVIEW
- [`diffs/cpu_and_memory.diff`](diffs/cpu_and_memory.diff) — CPU AND MEMORY
- [`diffs/kernel_parameters.diff`](diffs/kernel_parameters.diff) — KERNEL PARAMETERS
- [`diffs/disk_and_filesystem.diff`](diffs/disk_and_filesystem.diff) — DISK AND FILESYSTEM
- [`diffs/network_configuration.diff`](diffs/network_configuration.diff) — NETWORK CONFIGURATION
- [`diffs/open_file_descriptors.diff`](diffs/open_file_descriptors.diff) — OPEN FILE DESCRIPTORS
- [`diffs/jvm_configuration.diff`](diffs/jvm_configuration.diff) — JVM CONFIGURATION
- [`diffs/kafka_broker_configuration.diff`](diffs/kafka_broker_configuration.diff) — KAFKA BROKER CONFIGURATION
- [`diffs/replication_and_partition_health.diff`](diffs/replication_and_partition_health.diff) — REPLICATION AND PARTITION HEALTH
- [`diffs/network_latency.diff`](diffs/network_latency.diff) — NETWORK LATENCY
- [`diffs/connect_node_health.diff`](diffs/connect_node_health.diff) — CONNECT NODE HEALTH

---

## 7. Raw Reports

- [`raw/broker1-audit.txt`](raw/broker1-audit.txt) — full audit output
- [`raw/broker1.log`](raw/broker1.log) — dispatch log (SSM stdout/stderr)
- [`raw/broker2-audit.txt`](raw/broker2-audit.txt) — full audit output
- [`raw/broker2.log`](raw/broker2.log) — dispatch log (SSM stdout/stderr)
- [`raw/broker3-audit.txt`](raw/broker3-audit.txt) — full audit output
- [`raw/broker3.log`](raw/broker3.log) — dispatch log (SSM stdout/stderr)
- [`raw/connect-audit.txt`](raw/connect-audit.txt) — full audit output
- [`raw/connect.log`](raw/connect.log) — dispatch log (SSM stdout/stderr)
- [`raw/monitor-audit.txt`](raw/monitor-audit.txt) — full audit output
- [`raw/monitor.log`](raw/monitor.log) — dispatch log (SSM stdout/stderr)

# ops-analyze-infrastructure.sh — Infrastructure Analysis Tool

## Overview

Quick infrastructure analysis and tuning guide for your CDC pipeline.

Reads EC2 Instance IDs from `.env` and queries AWS for instance types and specs.

## Usage

### Basic Analysis
```bash
./scripts/ops-analyze-infrastructure.sh
```

Output: EC2 nodes table with tuning recommendations

### JSON Output
```bash
./scripts/ops-analyze-infrastructure.sh --json
```

## Prerequisites

Existing `.env` variables (no new ones required):
```
BROKER_1_INSTANCE_ID=i-0c94b9da838546498
BROKER_2_INSTANCE_ID=i-02b863c43d5871e7a
BROKER_3_INSTANCE_ID=i-0a2273b274d23632a
CONNECT_1_INSTANCE_ID=i-0a9cd118cb94005c1
MONITOR_1_INSTANCE_ID=i-0b85f9f370ddc8dac
AWS_REGION=us-east-1
```

## Quick Tuning Reference

### High CPU (>80%)
```
SQLSERVER_SOURCE_BATCH_SIZE=500
JDBC_SINK_AURORA_BATCH_SIZE=50
./scripts/6-deploy-connectors.sh
```

### High Memory (>85%)
```
KAFKA_HEAP_OPTS="-Xms10G -Xmx12G"
CONNECT_HEAP_OPTS="-Xms2G -Xmx3G"
./scripts/6-deploy-connectors.sh
```

### High Lag (>60 sec)
```
SQLSERVER_SOURCE_POLL_INTERVAL_MS=50
SQLSERVER_SOURCE_BATCH_SIZE=500
./scripts/6-deploy-connectors.sh
```

## Key Metrics

| Metric | Green | Red | Action |
|--------|-------|-----|--------|
| CPU | <30% | >80% | Reduce batches |
| Memory | <40% | >85% | Reduce heap |
| CDC Lag | <1s | >60s | Increase polling |
| Disk I/O | <20% | >80% | Add NVMe |

## For Detailed Tuning

See: `docs/INFRASTRUCTURE-TUNING-GUIDE.md`

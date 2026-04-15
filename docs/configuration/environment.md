# Environment File Management

## Overview

This document explains the different `.env` files and when to use each one.

## Files

### `.env.template` (Template — Always in Repo)
- **Purpose:** Example template with all variables and descriptive comments
- **Status:** Read-only reference; checked into git
- **Usage:** Copy this to create your `.env`
- **Git:** ✅ Committed

### `.env` (Active Configuration — NOT in Repo)
- **Purpose:** Your actual deployment configuration with real values
- **Status:** Must be created and populated before deployment
- **Usage:** `docker compose` commands read this file automatically
- **Git:** ❌ Git-ignored (in `.gitignore`)
- **Contents:** EC2 IPs, database credentials, Kafka settings
- **Lifecycle:**
  1. `cp .env.template .env`
  2. Edit with your real values
  3. Run `./scripts/1-validate-env.sh`
  4. Use for deployment

### `.env.snapshot` (Snapshot Phase Profile — In Repo)
- **Purpose:** Pre-optimized tuning for initial bulk data transfer
- **Status:** Checked into git; ready to use
- **When to use:** During initial data load (`Step 13` of deployment)
- **Optimizations:**
  - Consumer batch size: 5000 records (high throughput)
  - Producer batch size: 512 KB (large batches)
  - Compression: Snappy (reduce network load)
  - Connector tasks: 4 parallel (maximize throughput)
  - Expected throughput: 500-1000 MB/min

### `.env.streaming` (Streaming Phase Profile — In Repo)
- **Purpose:** Pre-optimized tuning for ongoing CDC replication
- **Status:** Checked into git; ready to use
- **When to use:** After initial snapshot completes (`Step 17` of deployment)
- **Optimizations:**
  - Consumer batch size: 100 records (low latency)
  - Producer batch size: 16 KB (small batches)
  - Compression: none (prioritize latency)
  - Consumer max wait: 100 ms (immediate delivery)
  - Expected latency: <1 second end-to-end

### `.env.backup.default` (Backup — Not in Repo)
- **Purpose:** Auto-created backup of last successful default configuration
- **Status:** NOT checked into git
- **When created:** By deployment scripts as safety measure
- **Usage:** Emergency recovery if `.env` gets corrupted
- **Git:** ❌ Git-ignored (in `.gitignore`)
- **Lifecycle:** Created automatically; can be manually deleted

## Workflow

### First Time Setup

```bash
cd /path/to/cdc-on-ec2-docker

# 1. Copy template
cp .env.template .env

# 2. Edit with your values
vim .env
# Fill in:
#   - BROKER_1_IP, BROKER_2_IP, BROKER_3_IP (from AWS Console → EC2 → Private IPv4)
#   - CONNECT_1_IP, MONITOR_1_IP (same)
#   - AURORA_* credentials (from AWS RDS console)
#   - SQLSERVER_* credentials (from AWS RDS or on-premises)
#   - CLUSTER_ID (generate: docker run --rm confluentinc/cp-server:8.0.0 kafka-storage random-uuid)

# 3. Validate
./scripts/1-validate-env.sh

# 4. Check prerequisites
./scripts/on-demand-check-prerequisites.sh
```

### During Snapshot Phase (Initial Load)

```bash
# Use snapshot-optimized settings
cp .env.snapshot .env

# Verify changes
./scripts/1-validate-env.sh

# Deploy connectors (will use high-throughput settings)
./scripts/6-deploy-connectors.sh

# Monitor throughput via Control Center at http://localhost:9021 (SSM port-forward)
# Or check consumer lag:
# kafka-consumer-groups --bootstrap-server <BROKER_1_IP>:9092 --describe --all-groups

# Once snapshot complete, switch to streaming profile:
./scripts/on-demand-switch-profile.sh streaming
```

### Switching to Streaming Phase

```bash
# Switch to streaming profile (distributes updated .env and restarts all nodes)
./scripts/on-demand-switch-profile.sh streaming

# Verify the profile switch
./scripts/1-validate-env.sh
```

### If Something Goes Wrong

```bash
# Restore from backup (if available)
if [[ -f .env.backup.default ]]; then
    cp .env.backup.default .env
    ./scripts/1-validate-env.sh
fi

# If backup doesn't exist, start fresh
rm .env
cp .env.template .env
vim .env
./scripts/1-validate-env.sh
```

## Environment Variables Explained

### EC2 Node IPs
```
BROKER_1_IP=10.0.x.y              # Private IP of broker node 1
BROKER_2_IP=10.0.x.y              # Private IP of broker node 2
BROKER_3_IP=10.0.x.y              # Private IP of broker node 3
CONNECT_1_IP=10.0.x.y             # Private IP of connect node
MONITOR_1_IP=10.0.x.y             # Private IP of monitoring node
```

Find these in: AWS Console → EC2 → Instances → Private IPv4 address

### Aurora PostgreSQL
```
AURORA_HOST=<your-cluster>.writer.rds.amazonaws.com
AURORA_PORT=5432
AURORA_DATABASE=pocdb
AURORA_USER=cdcadmin
AURORA_PASSWORD=<secure-password>
```

### SQL Server
```
SQLSERVER_HOST=<your-instance>.rds.amazonaws.com
SQLSERVER_PORT=1433
SQLSERVER_DATABASE=pocdb
SQLSERVER_USER=cdcadmin
SQLSERVER_PASSWORD=<secure-password>
```

### Apache Kafka® Configuration
```
CP_VERSION=8.0.0                           # Confluent Platform version
CLUSTER_ID=<generate-with-kafka-storage-random-uuid>   # Unique cluster ID (KRaft mode)
KAFKA_REPLICATION_FACTOR=3                # RF for all Kafka topics
```

### Performance Tuning (Snapshot Profile)
```
CONNECT_CONSUMER_MAX_POLL_RECORDS=5000     # Records per fetch (high for throughput)
CONNECT_PRODUCER_BATCH_SIZE=524288         # 512 KB batches (high throughput)
CONNECT_PRODUCER_LINGER_MS=1000            # Wait 1s for batches (reduce network overhead)
CONNECT_CONSUMER_FETCH_MAX_BYTES=104857600 # 100 MB fetch size
```

### Performance Tuning (Streaming Profile)
```
CONNECT_CONSUMER_MAX_POLL_RECORDS=100      # Records per fetch (low for latency)
CONNECT_PRODUCER_BATCH_SIZE=16384          # 16 KB batches (low latency)
CONNECT_PRODUCER_LINGER_MS=0               # No wait (immediate send)
CONNECT_CONSUMER_FETCH_MAX_BYTES=1048576   # 1 MB fetch size
```

## Common Issues

### "Variable 'BROKER_1_IP' is not set" Error

**Cause:** Environment variable not defined in `.env`

**Fix:**
```bash
# Check .env exists
ls -la .env

# Check it has the variable
grep BROKER_1_IP .env

# If missing, validate
./scripts/1-validate-env.sh

# Add missing variable
echo "BROKER_1_IP=10.0.11.146" >> .env
```

### Docker compose Fails with "invalid value"

**Cause:** `.env` file with wrong syntax (missing `=`, extra quotes)

**Fix:**
```bash
# Validate .env syntax
./scripts/1-validate-env.sh

# Check for common issues
grep -n "^[A-Z_]*=[^=]*$" .env | wc -l  # Should match total lines
```

### Credentials Failing During Deployment

**Cause:** Incorrect database credentials in `.env`

**Fix:**
```bash
# Test connection manually
psql -h ${AURORA_HOST} -U ${AURORA_USER} -d ${AURORA_DATABASE} -c "SELECT 1"
sqlcmd -S ${SQLSERVER_HOST} -U ${SQLSERVER_USER} -P ${SQLSERVER_PASSWORD} -Q "SELECT 1"

# If connection fails, update .env with correct credentials
vim .env
./scripts/1-validate-env.sh
```

## Git Ignore Rules

Ensure `.gitignore` contains:
```
.env
.env.backup.*
!.env.template
```

This ensures:
- ✅ `.env.template` is committed (safe example)
- ❌ `.env` is ignored (contains secrets)
- ❌ `.env.backup.*` is ignored (auto-created backups)

---

**Summary:**
- `template` = safe example (in repo)
- `default` = your custom config (NOT in repo, git-ignored)
- `snapshot` = throughput-optimized (in repo, ready to use)
- `streaming` = latency-optimized (in repo, ready to use)
- `backup.default` = auto-created safety copy (NOT in repo, auto-created)

---

*Apache, Apache Kafka, Kafka, and the Kafka logo are trademarks of The Apache Software Foundation.*

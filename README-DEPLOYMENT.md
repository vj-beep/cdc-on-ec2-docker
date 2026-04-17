# Deployment Workflow — Phase-by-Phase

This document walks through deploying the bi-directional CDC pipeline using the numbered scripts in `scripts/`.

## Dispatch Modes

Scripts support two modes for reaching EC2 nodes. Set `DISPATCH_MODE` in `.env` before starting.

### SSM mode (default — `DISPATCH_MODE=ssm`)

Scripts run from **any machine with AWS CLI access** (jumpbox, bastion, local machine). Commands are dispatched to EC2 nodes via AWS Systems Manager — no SSH keys or inbound ports required.

**Requirements:**
- AWS CLI configured with credentials
- EC2 IAM instance profile with `AmazonSSMManagedInstanceCore`
- SSM VPC endpoints (PrivateLink) — required if nodes have no direct internet egress
- `BROKER_*_INSTANCE_ID`, `CONNECT_1_INSTANCE_ID`, `MONITOR_1_INSTANCE_ID` set in `.env`

### SSH mode (`DISPATCH_MODE=ssh`)

Scripts run from **any machine with SSH access** to the nodes. Multi-node scripts dispatch via `ssh`/`scp`. Per-node scripts are run directly on each node with `--local`.

**Requirements:**
- `SSH_KEY_PATH` set in `.env` (path to private key authorised on all nodes)
- `BROKER_*_IP`, `CONNECT_1_IP`, `MONITOR_1_IP` set in `.env` (already required)
- Instance IDs (`*_INSTANCE_ID`) are not required in SSH mode

**Per-node phase workflow (SSH mode):**

| Phase | Where to run | Command |
|-------|-------------|---------|
| **0** | Control machine | `./scripts/0-preflight.sh` (checks SSH reachability) |
| **1** | Control machine | `./scripts/1-validate-env.sh` |
| **2a** | SSH into each of the 5 nodes | `bash scripts/2a-deploy-repo.sh --local` |
| **2b** | Control machine | `./scripts/2b-distribute-env.sh` (uses scp) |
| **3** | SSH into each node | `sudo bash scripts/3-setup-ec2.sh --local` |
| **4** | SSH into Node 4 | `bash scripts/4-build-connect.sh --local` |
| **5** | SSH into target node | `bash scripts/5-start-node.sh --local <node>` |
| **6** | SSH into Node 4 | `./scripts/6-deploy-connectors.sh` |
| **7** | SSH into Node 4 | `./scripts/7-validate-poc.sh` |

> **Proxy required in both modes.** No direct internet egress is assumed — Docker pulls, `dnf` installs, and Maven downloads all route through `HTTP_PROXY`/`HTTPS_PROXY`. Set these in `.env` before deployment.

---

## Overview

| Phase | Script | What it does | Runtime |
|-------|--------|--------------|---------|
| **0** | `0-preflight.sh` | Verify AWS/SSH, nodes, databases are reachable | 2-3 min |
| **1** | `1-validate-env.sh` | Check all .env variables are set and valid | 1 min |
| **2a** | `2a-deploy-repo.sh` | Clone this repo to all 5 EC2 nodes | 3 min |
| **2b** | `2b-distribute-env.sh` | Copy .env to all 5 nodes (SSM or scp) | 2 min |
| **3** | `3-setup-ec2.sh` | Install Docker, format NVMe, kernel tuning | 5 min |
| **4** | `4-build-connect.sh` | Build custom Connect image with Debezium + JDBC | 5-10 min |
| **5** | `5-start-node.sh` | Start services (brokers → connect → monitor) | 1-5 min/node |
| **6** | `6-deploy-connectors.sh` | Deploy 4 CDC connectors via REST API | 2 min |
| **7** | `7-validate-poc.sh` | Validate infrastructure, connectors, DLQ, consumer lag | 2-5 min |

**Total time:** ~30-40 minutes

---

## Prerequisites

Before starting deployment:

1. ✅ **Infrastructure provisioned** — 5 EC2 instances + RDS databases running (via Terraform, CloudFormation, CDK, or AWS Console)
2. ✅ **`.env` file created and populated** — see next section
3. ✅ **AWS CLI configured** — credentials with SSM and EC2 access
4. ✅ **Databases CDC-enabled** — run `db-prep/` scripts on both databases (these set up CDC infrastructure only; create your own tables first, then uncomment the examples in the scripts to enable CDC on them)
5. ✅ **EC2 IAM Instance Profile** — role attached to all 5 instances with these policies:

| Permission | Purpose | Required On |
|------------|---------|-------------|
| `AmazonSSMManagedInstanceCore` | SSM Session Manager access | All nodes |
| `logs:CreateLogGroup`, `logs:PutLogEvents` | CloudWatch Logs shipping | All nodes |
| `secretsmanager:GetSecretValue` | Fetch DB passwords from Secrets Manager | All nodes |
| `ecr:GetAuthorizationToken`, `ecr:BatchGetImage` | Pull custom Connect image (if using ECR) | Node 4 (Connect) |

---

## Create and Populate .env File

The `.env` file drives the entire deployment. It contains infrastructure addresses, credentials, CDC configuration, and performance tuning.

### Step 1: Copy the template

```bash
cp .env.template .env
```

### Step 2: Fill in infrastructure values

| Section | Variables | Where to find |
|---------|-----------|---------------|
| EC2 Node IPs | `BROKER_1_IP`, `BROKER_2_IP`, `BROKER_3_IP`, `CONNECT_1_IP`, `MONITOR_1_IP` | `terraform output` or AWS Console → EC2 → Private IPv4 |
| EC2 Instance IDs | `BROKER_1_INSTANCE_ID` through `MONITOR_1_INSTANCE_ID` | `terraform output instance_ids` or AWS Console → EC2 |
| Aurora PostgreSQL | `AURORA_HOST`, `AURORA_PASSWORD` | `terraform output aurora_password` or AWS Console → RDS → Cluster endpoint |
| SQL Server | `SQLSERVER_HOST`, `SQLSERVER_PASSWORD` | `terraform output sqlserver_password` or AWS Console → RDS → Instance endpoint |
| CDC Reader | `CDC_READER_PASSWORD` | Generate a strong password; used by JDBC sink connectors to authenticate |
| KRaft Cluster ID | `CLUSTER_ID` | Generate once: `python3 -c "import uuid,base64; print(base64.urlsafe_b64encode(uuid.uuid4().bytes).decode().rstrip('='))"` |
| Public Repo | `PUBLIC_REPO_URL` | Your GitHub URL for this repository |

### Step 3: Configure CDC tables

Update these variables to match the tables you created and CDC-enabled in the `db-prep/` step:

| Variable | Example | Purpose |
|----------|---------|---------|
| `SQLSERVER_TABLE_INCLUDE_LIST` | `dbo.table1,dbo.table2,dbo.table3` | Tables to capture from SQL Server |
| `AURORA_TABLE_INCLUDE_LIST` | `public.table1,public.table2,public.table3` | Tables to capture from Aurora |
| `SQLSERVER_TOPIC_PREFIX` | `sqlserver` | Kafka topic prefix for SQL Server changes |
| `AURORA_TOPIC_PREFIX` | `aurora` | Kafka topic prefix for Aurora changes |

**No-PK tables:** If any of your CDC tables lack a primary key, you **must** set `SQLSERVER_MESSAGE_KEY_COLUMNS` and/or `AURORA_MESSAGE_KEY_COLUMNS`. Without this, Debezium produces null-key records and JDBC sink connectors crash.

```bash
# Format: <fully-qualified-table>:<col1>,<col2>
# Example for a no-PK table using a composite unique constraint:
SQLSERVER_MESSAGE_KEY_COLUMNS=yourdb.dbo.audit_log:event_timestamp,source_type
AURORA_MESSAGE_KEY_COLUMNS=public.audit_log:event_timestamp,source_type
```

Leave both empty if all your tables have primary keys. See [connectors/README.md](connectors/README.md) for details.

> **Tuning profile:** The template includes the **snapshot** profile by default — optimized for high-throughput initial data load. No action needed here. After deployment completes and the initial snapshot finishes, switch to the streaming profile using `./scripts/on-demand-switch-profile.sh streaming` (see [Post-Deployment Operations](#switch-tuning-profile)).

### Step 4: Validate

```bash
./scripts/1-validate-env.sh
```

Confirms all required variables are set, IPs are valid format, and KRaft cluster ID is present.

### Step 5: Set Up Databases for CDC (Before Deployment)

Before starting Phase 0, enable CDC on both source databases by running the prep scripts. These scripts:
- Enable transaction log capture (CDC)
- Create the `cdc_reader` login/role with minimal required permissions
- Create your application tables and enable CDC on them (see `db-prep/` examples)

**For fresh deployments with custom database names:**

The prep scripts are parameterized and work with any database/table names. Use the values from your `.env`:

**SQL Server:**
```bash
# Generate a strong password
CDC_PASSWORD=$(openssl rand -base64 16)
echo "CDC_READER_PASSWORD=$CDC_PASSWORD" >> .env

# Read database name from .env, pass to script via sqlcmd variable
DB_NAME=$(grep "^SQLSERVER_DATABASE=" .env | cut -d= -f2)

# Run prep script with database name and password variables
SQLCMDPASSWORD="$SQLSERVER_PASSWORD" sqlcmd -S "$SQLSERVER_HOST",1433 \
  -U "$SQLSERVER_USER" \
  -v DB_NAME="$DB_NAME" \
  -v CDC_PWD="$CDC_PASSWORD" \
  -i db-prep/prep-sqlserver.sql
```

**Aurora PostgreSQL:**
```bash
# Use the same password from above (or generate a new one)
CDC_PASSWORD=$(grep CDC_READER_PASSWORD .env | cut -d= -f2)

# Read database name from .env
DB_NAME=$(grep "^AURORA_DATABASE=" .env | cut -d= -f2)

# Run prep script (database determined by -d flag, not internal variable)
PGPASSWORD="$AURORA_PASSWORD" psql -h "$AURORA_HOST" -U cdcadmin -d "$DB_NAME" \
  -v cdc_password="'$CDC_PASSWORD'" \
  -f db-prep/prep-aurora.sql
```

**Important:** Do NOT hardcode passwords in scripts. Use environment variables or secrets manager. The examples above use variable substitution — the actual password is never exposed in shell history.

**To skip the example tables and use your own:**
- After running the prep scripts (which create CDC infrastructure)
- Create your own tables in the database
- Enable CDC on those tables individually (see `db-prep/prep-*.sql` for examples)
- Update `.env` table variables to match your schema

---

## Step-by-Step Deployment

### Phase 0: Pre-flight Audit

```bash
./scripts/0-preflight.sh
```

Checks:
- AWS CLI and credentials working
- All 5 EC2 instances reachable via SSM
- RDS databases accessible (SQL Server + Aurora)
- Public repo URL reachable
- .env file exists and has no blank required values

**If any check fails**, fix the issue before proceeding.

---

### Phase 1: Validate .env

```bash
./scripts/1-validate-env.sh
```

Validates:
- Every required variable has a value
- IP addresses match expected format
- Database credentials are non-empty
- KRaft cluster ID is set

---

### Phase 2a: Deploy Repository to All Nodes

**SSM mode** (dispatches to all nodes automatically):
```bash
./scripts/2a-deploy-repo.sh
```

**SSH mode** (run on each node after SSH-ing in):
```bash
# SSH into each of the 5 nodes, then:
bash scripts/2a-deploy-repo.sh --local
```

What it does on each node:
- Installs `git` if not present (via proxy)
- Clones `PUBLIC_REPO_URL` to `DEPLOY_DIR` (default: `/home/ec2-user/cdc-on-ec2-docker/`)
- Sets correct ownership

---

### Phase 2b: Distribute .env to All Nodes

```bash
./scripts/2b-distribute-env.sh
```

Works in both SSM and SSH modes (reads `DISPATCH_MODE` from `.env`):
- **SSM mode:** sends file content via SSM (base64-encoded)
- **SSH mode:** uses `scp -i $SSH_KEY_PATH` to copy `.env` to each node
- Writes to `DEPLOY_DIR/.env` with permissions `600` (owner-only read/write)

---

### Phase 3: Bootstrap EC2 Nodes

**SSM mode** (dispatches to all 5 nodes automatically):
```bash
./scripts/3-setup-ec2.sh
```

**SSH mode** (run on each node after SSH-ing in):
```bash
# SSH into each of the 5 nodes, then:
sudo bash scripts/3-setup-ec2.sh --local
```

What it does on each node:
- Installs Docker + Docker Compose
- Detects NVMe drives (i3.4xlarge has 2x1.9TB, m5d has 1x300GB)
- Formats NVMe as xfs, mounts at `/data/kafka` with `noatime`
- Applies kernel tuning (vm.swappiness, net buffers, file limits)

---

### Phase 4: Build Custom Connect Image

```bash
./scripts/4-build-connect.sh
```

Runs on **Node 4 (connect node)** only:
- Builds `cdc-poc-connect:${CP_VERSION}` using `connect/Dockerfile`
- Downloads and installs: Debezium SQL Server, Debezium PostgreSQL, JDBC Sink plugins
- Includes `mssql-jdbc` driver from `connect/jars/`
- Takes 5-10 minutes (Maven plugin downloads)

The image stays local on Node 4 — it is not pushed to any registry.

---

### Phase 5: Start Services

**Parallel Startup (Fastest — 20 minutes total):** Apache Kafka® Brokers, Connect, and Monitor can start simultaneously. Only dependency: brokers must be ready before deploying connectors.

#### Option A: Sequential (Simple, ~25 minutes)

**1. Start brokers (Nodes 1-3):**
```bash
./scripts/5-start-node.sh broker1
./scripts/5-start-node.sh broker2
./scripts/5-start-node.sh broker3
```

**2. Wait 3-5 minutes** for KRaft leader election. Check readiness:
```bash
docker logs $(docker ps --filter 'name=broker' -q) 2>&1 | grep -i "leader"
# Expected: "Leader elected" in logs
```

**3. Start Connect + Schema Registry (Node 4):**
```bash
./scripts/5-start-node.sh connect
```

**4. Start Monitoring (Node 5):**
```bash
./scripts/5-start-node.sh monitor
```

#### Option B: Parallel (Advanced, ~20 minutes)

Open 5 terminal sessions and send commands to all nodes in parallel via AWS SSM:

```bash
# Terminal 1: Broker 1
./scripts/5-start-node.sh broker1

# Terminal 2: Broker 2 (in parallel)
./scripts/5-start-node.sh broker2

# Terminal 3: Broker 3 (in parallel)
./scripts/5-start-node.sh broker3

# Terminal 4: Connect (after T+60s, don't wait for KRaft)
./scripts/5-start-node.sh connect

# Terminal 5: Monitor (completely independent)
./scripts/5-start-node.sh monitor
```

**Expected Timeline (parallel):**
| Time | Event |
|------|-------|
| T+0 | All start commands sent |
| T+30s | Connect/Monitor containers initializing |
| T+1m | Docker logs show progress |
| T+3-5m | KRaft leader election completing on brokers |
| T+5m | All brokers ready (port 9093 listening) |
| T+10m | Connect REST API ready (port 8083) |
| T+15-20m | All services fully initialized |

**Health Check** (after ~10 minutes):
```bash
# Check brokers
for i in 1 2 3; do
  docker exec broker-$i kafka-broker-api-versions --bootstrap-server localhost:9093 --cmd-type metadata 2>/dev/null && echo "✓ Broker $i ready" || echo "✗ Broker $i not ready"
done

# Check Connect REST API
curl -s http://localhost:8083/connectors | jq . && echo "✓ Connect ready" || echo "✗ Connect not ready"

# Check all services
./scripts/ops-health-check.sh
```

#### Service Initialization Timelines

**Brokers (KRaft Election):**
| Time | Status | Notes |
|------|--------|-------|
| T+0-30s | Container starting | Wait |
| T+30-120s | KRaft electing | **Expected** — not hung |
| T+120-300s | Election finalizing | Some port timeouts normal |
| T+300s+ | Ready | Port 9093 listening, brokers accepting connections |

**Connect (REST API):**
| Time | Status | Notes |
|------|--------|-------|
| T+0-30s | JVM starting | Wait |
| T+30-60s | Plugins loading | Watch `docker logs connect-1` |
| T+60-120s | REST API starting | May return 503 — normal |
| T+120s+ | Ready | Responds to `curl http://localhost:8083/connectors` |

**Docker Build Issues:**
- Maven download hanging 5+ min: **Normal** — Maven Central can be slow. Wait up to 10 min.
- `docker: no space left on device`: Run `docker system prune -a`
- Build timeout: SSH to node, check `docker logs` for progress

---

### Phase 6: Deploy CDC Connectors

```bash
./scripts/6-deploy-connectors.sh
```

Deploys all 4 connectors via the Connect REST API:

| Connector | Direction | Port |
|-----------|-----------|------|
| `debezium-sqlserver-source` | SQL Server → Kafka | 8083 |
| `jdbc-sink-aurora` | Kafka → Aurora PostgreSQL | 8083 |
| `debezium-postgres-source` | Aurora → Kafka | 8084 |
| `jdbc-sink-sqlserver` | Kafka → SQL Server | 8084 |

Waits for each connector to report `RUNNING` state before proceeding.

---

### Phase 7: Validate Infrastructure

```bash
./scripts/7-validate-poc.sh
```

Validates infrastructure and service health:
- Connectivity to all brokers, Connect workers, Schema Registry, databases
- All 4 connectors in RUNNING state with healthy tasks
- Schema Registry accessible with registered subjects
- DLQ topics are empty (no error records)
- Consumer lag within acceptable thresholds

---

### Data Path Validation (Optional)

To test actual data replication end-to-end, configure these optional variables in `.env`:

```bash
VALIDATE_TABLE=your_table         # Table name (must exist in both DBs)
VALIDATE_PK_COLUMN=id             # Primary key column (integer)
VALIDATE_PK_START=900000          # Test PK range (high to avoid collisions)
VALIDATE_MARKER_COLUMN=status     # Column to write a marker value into
VALIDATE_MARKER_VALUE=CDCTest     # Marker to identify test rows
VALIDATE_CDC_WAIT=15              # Seconds to wait for CDC propagation
VALIDATE_LOOP_WAIT=20             # Seconds to wait for loop detection
```

Then run your data path validation script to test:
- Forward path: insert in SQL Server → verify in Aurora
- Reverse path: insert in Aurora → verify in SQL Server
- Loop prevention: verify rows don't bounce back to origin

---

## Post-Deployment Operations

### Switch Tuning Profile

The `.env.template` ships with the **snapshot** profile (high-throughput, optimized for initial bulk data load). Once the initial snapshot completes and you're ready for steady-state CDC, switch to the **streaming** profile:

```bash
./scripts/on-demand-switch-profile.sh streaming
```

The script:
1. Merges streaming tuning values into your local `.env`
2. Shows a diff of all changes (batch sizes, compression, poll intervals, etc.)
3. Prompts: **"Distribute .env to all nodes and restart services? [y/N]"**
4. If confirmed: distributes updated `.env` via SSM, then restarts all 5 nodes in order

| Profile | When to use | Key settings |
|---------|-------------|--------------|
| **snapshot** (default) | Initial deployment, bulk data load | Batch 5000, snappy, 4 tasks, `snapshot_mode=initial` |
| **streaming** | After snapshot completes | Batch 500, lz4, 2 tasks, `snapshot_mode=schema_only`, 50ms poll |

To switch back (e.g., adding new tables that need a full snapshot):
```bash
./scripts/on-demand-switch-profile.sh snapshot
```

> **Important:** Only run `on-demand-switch-profile.sh` after the full infrastructure is deployed and running (Phase 7 complete). The script distributes `.env` and restarts services on all nodes.

### Health Checks

```bash
./scripts/ops-health-check.sh                     # Check local node
./scripts/ops-health-check.sh --remote <node-ip>  # Check remote node
./scripts/ops-node-status-ssm.sh                  # Docker status on all 5 nodes
```

### Stop Services

```bash
./scripts/ops-stop-node.sh broker1    # Stop a single node
./scripts/ops-stop-node.sh connect    # Stop connect workers
```

### Teardown (Full Reset)

```bash
./scripts/teardown-reset-all-nodes.sh
```

Stops all containers, removes volumes, and cleans up on all nodes. Use before re-deploying from scratch.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Phase 0: "Cannot find instance" | Instance stopped or wrong ID in .env | Check `aws ec2 describe-instances` and update .env |
| Phase 0: "SSH not reachable" | Key wrong or SG blocks port 22 | Check `SSH_KEY_PATH` and security group inbound rules |
| Phase 1: "SSH_KEY_PATH not set" | SSH mode but key path missing | Add `SSH_KEY_PATH=~/.ssh/id_rsa` to .env |
| Phase 1: "Variable not set" | .env has blank values | Fill all required fields, re-run `1-validate-env.sh` |
| Phase 2a: "git not found" | Git not installed on node | Script installs it automatically via proxy; if it fails: `dnf install -y git` |
| Phase 3: "must be run as root" | Missing sudo | Run with `sudo bash scripts/3-setup-ec2.sh --local` |
| Phase 4: Build hangs | Slow Maven downloads through proxy | SSH to Node 4, check `docker logs`; retry usually works |
| Phase 5: Connect "pull access denied" | Image not built locally | Run Phase 4 first on Node 4 |
| Phase 6: "Connect not responding" | Connect not started or still initializing | Wait 1-2 min after Phase 5, then retry |
| Phase 7: "No data in Aurora" | Connectors not RUNNING | Check: `curl http://localhost:8083/connectors/<name>/status` |
| Profile switch: "No instance ID" | SSM mode + .env missing `*_INSTANCE_ID` vars | Add instance IDs to .env, or switch to `DISPATCH_MODE=ssh` |

---

## Quick Reference

### SSM mode (default — `DISPATCH_MODE=ssm`)

```bash
# Full deployment (run in order from any machine with AWS CLI):
./scripts/0-preflight.sh
./scripts/1-validate-env.sh
./scripts/2a-deploy-repo.sh                  # dispatches git clone to all 5 nodes via SSM
./scripts/2b-distribute-env.sh               # copies .env to all 5 nodes via SSM
./scripts/3-setup-ec2.sh                     # bootstraps all 5 nodes via SSM
./scripts/4-build-connect.sh                 # builds Connect image on Node 4 via SSM
./scripts/5-start-node.sh broker1 && ./scripts/5-start-node.sh broker2 && ./scripts/5-start-node.sh broker3
# Wait 3-5 min for KRaft
./scripts/5-start-node.sh connect
./scripts/5-start-node.sh monitor
./scripts/6-deploy-connectors.sh
./scripts/7-validate-poc.sh
```

### SSH mode (`DISPATCH_MODE=ssh`, `SSH_KEY_PATH=~/.ssh/id_rsa`)

```bash
# From control machine:
./scripts/0-preflight.sh                     # checks SSH reachability of all nodes
./scripts/1-validate-env.sh
./scripts/2b-distribute-env.sh               # scp .env to all 5 nodes

# SSH into each node and run --local (repeat for all 5 nodes):
ssh -i ~/.ssh/id_rsa ec2-user@<node-ip>
  bash scripts/2a-deploy-repo.sh --local     # clone repo
  sudo bash scripts/3-setup-ec2.sh --local   # bootstrap Docker, NVMe, tuning

# SSH into Node 4 only:
ssh -i ~/.ssh/id_rsa ec2-user@<connect-ip>
  bash scripts/4-build-connect.sh --local    # build Connect image

# SSH into each node for start (or use SSM dispatch from control machine):
ssh -i ~/.ssh/id_rsa ec2-user@<broker1-ip>
  bash scripts/5-start-node.sh --local broker1
# ...repeat for broker2, broker3, connect, monitor

# From Node 4 (or any node that can reach Connect REST API):
./scripts/6-deploy-connectors.sh
./scripts/7-validate-poc.sh
```

### Post-deployment (both modes)

```bash
./scripts/on-demand-switch-profile.sh streaming   # After snapshot completes
./scripts/ops-node-status-ssm.sh                  # Check all nodes
./scripts/ops-health-check.sh                     # Health check (local node)
./scripts/teardown-reset-all-nodes.sh             # Full reset
```

---

*Apache, Apache Kafka, Kafka, and the Kafka logo are trademarks of The Apache Software Foundation.*

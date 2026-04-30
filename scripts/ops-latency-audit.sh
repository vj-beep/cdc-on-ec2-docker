#!/usr/bin/env bash
# =============================================================================
# ops-latency-audit.sh — Kafka Latency Audit for 5-Node CDC Cluster
#
# Dispatches from the jumpbox to all nodes (SSM or SSH), collects system
# and Kafka configuration, diffs settings across nodes, and writes a
# consolidated FINDINGS.md with latency red flags and remediation steps.
#
# Usage (from jumpbox — dispatches to all 5 nodes):
#   bash scripts/ops-latency-audit.sh [--workdir DIR] [--probes] [--cleanup]
#
# Usage (on-node — runs local audit only, writes report to stdout + file):
#   sudo bash scripts/ops-latency-audit.sh --local [--bootstrap HOST:PORT]
#
# Options:
#   --workdir DIR         Local output dir (default: ./kafka-audit-YYYYMMDD-HHMMSS)
#   --bootstrap HOST:PORT Kafka bootstrap for --perf probe (e.g. 10.0.1.10:9092)
#   --probes              Also run fio disk probes on all nodes (adds ~2 min)
#   --perf-node NODE      Run producer-perf-test on this node name (default: broker1)
#   --cleanup             Remove remote audit output files after collection
#   --local               On-node mode: run audit locally, do not dispatch
#
# Dispatch modes (read from .env):
#   DISPATCH_MODE=ssm  (default) — AWS SSM send-command
#   DISPATCH_MODE=ssh            — direct SSH (requires SSH_KEY_PATH in .env)
#
# Reference: https://developer.confluent.io/learn/kafka-performance/
# =============================================================================

set -uo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; GREY='\033[0;90m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ─── Parse args ──────────────────────────────────────────────────────────────
LOCAL_MODE=false
RUN_PROBES=false
DO_CLEANUP=false
WORKDIR=""
BOOTSTRAP_SERVER=""
PERF_NODE="broker1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local)      LOCAL_MODE=true;          shift ;;
    --probes)     RUN_PROBES=true;          shift ;;
    --cleanup)    DO_CLEANUP=true;          shift ;;
    --workdir)    WORKDIR="$2";             shift 2 ;;
    --bootstrap)  BOOTSTRAP_SERVER="$2";    shift 2 ;;
    --perf-node)  PERF_NODE="$2";           shift 2 ;;
    --help)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,2\}//' | head -30
      exit 0 ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

# =============================================================================
# ON-NODE MODE: run the audit locally and print report
# =============================================================================
if $LOCAL_MODE; then

  if [[ $EUID -ne 0 ]]; then
    error "On-node mode requires root. Run: sudo bash scripts/ops-latency-audit.sh --local"
    exit 1
  fi

  REPORT_FILE="/tmp/kafka-latency-audit-$(hostname -s)-$(date +%Y%m%d-%H%M%S).txt"
  HOSTNAME_SHORT=$(hostname -s)

  # Load .env for broker config path
  DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
  DEPLOY_DIR="/home/${DEPLOY_USER}/cdc-on-ec2-docker"
  if [[ -f "$DEPLOY_DIR/.env" ]]; then
    # shellcheck disable=SC1090
    set +u; source "$DEPLOY_DIR/.env"; set -u
  fi

  KAFKA_LOG_DIR="${KAFKA_LOG_DIRS:-/data/kafka/logs}"
  BROKER_CONFIG_PATH="${DEPLOY_DIR}/configs/server.properties"

  {
    echo "=== AUDIT METADATA ==="
    echo "Hostname   : $(hostname -f)"
    echo "Date       : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "Kernel     : $(uname -r)"
    echo "Script     : ops-latency-audit.sh --local"
    echo ""

    # ── Section 1: System Overview ──────────────────────────────────────────
    echo "=== SYSTEM OVERVIEW ==="
    echo "--- CPU ---"
    lscpu | grep -E '^(Architecture|CPU\(s\)|Model name|Thread|Core|Socket|NUMA|CPU MHz)'
    echo ""
    echo "--- Memory ---"
    free -h
    echo ""
    echo "--- Instance type (IMDSv2) ---"
    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || echo "")
    if [[ -n "$TOKEN" ]]; then
      curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
        http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo "(unavailable)"
    else
      echo "(IMDSv2 token unavailable)"
    fi
    echo ""
    echo "--- Uptime ---"
    uptime
    echo ""

    # ── Section 2: CPU and Memory ────────────────────────────────────────────
    echo "=== CPU AND MEMORY ==="
    echo "--- vCPU count ---"
    nproc
    echo ""
    echo "--- NUMA topology ---"
    numactl --hardware 2>/dev/null || echo "(numactl not installed)"
    echo ""
    echo "--- Huge pages ---"
    grep -E 'HugePages|Hugepagesize' /proc/meminfo
    echo ""

    # ── Section 3: Kernel Parameters ─────────────────────────────────────────
    echo "=== KERNEL PARAMETERS ==="
    echo "--- Swappiness ---"
    echo "vm.swappiness = $(sysctl -n vm.swappiness)"
    echo ""
    echo "--- Dirty ratio ---"
    sysctl vm.dirty_ratio vm.dirty_background_ratio vm.dirty_expire_centisecs vm.dirty_writeback_centisecs
    echo ""
    echo "--- TCP/socket buffers ---"
    sysctl net.core.rmem_default net.core.rmem_max net.core.wmem_default net.core.wmem_max \
          net.core.somaxconn net.core.netdev_max_backlog \
          net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
          net.ipv4.tcp_max_syn_backlog 2>/dev/null || true
    echo ""
    echo "--- Transparent Huge Pages ---"
    thp_enabled=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "N/A")
    thp_defrag=$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || echo "N/A")
    echo "enabled: $thp_enabled"
    echo "defrag : $thp_defrag"
    echo ""
    echo "--- Open file descriptor limits (ec2-user) ---"
    su - ec2-user -s /bin/bash -c 'ulimit -n' 2>/dev/null || ulimit -n
    echo "(system hard limit)"
    cat /proc/sys/fs/file-max
    echo ""

    # ── Section 4: Disk and Filesystem ───────────────────────────────────────
    echo "=== DISK AND FILESYSTEM ==="
    echo "--- Mount options (all mounts) ---"
    findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS | grep -v 'tmpfs\|cgroup\|proc\|sys\|dev\|run\|overlay' || findmnt
    echo ""
    echo "--- Kafka log dir mount ---"
    KAFKA_MOUNT=$(df -P "${KAFKA_LOG_DIR}" 2>/dev/null | tail -1 | awk '{print $6}') || KAFKA_MOUNT=""
    if [[ -n "$KAFKA_MOUNT" ]]; then
      findmnt -T "${KAFKA_LOG_DIR}" -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || \
        mount | grep "$KAFKA_MOUNT"
    else
      echo "Kafka log dir not found: ${KAFKA_LOG_DIR}"
    fi
    echo ""
    echo "--- I/O scheduler (block devices) ---"
    for dev in /sys/block/*/queue/scheduler; do
      blk=$(echo "$dev" | awk -F/ '{print $4}')
      # Skip loop, ram, dm devices
      [[ "$blk" =~ ^(loop|ram|dm) ]] && continue
      echo "$blk: $(cat "$dev" 2>/dev/null)"
    done
    echo ""
    echo "--- Disk usage ---"
    df -h "${KAFKA_LOG_DIR}" 2>/dev/null || df -h /
    echo ""

    # ── Section 5: Network Configuration ─────────────────────────────────────
    echo "=== NETWORK CONFIGURATION ==="
    echo "--- Network interfaces ---"
    ip -brief addr show | grep -v '^lo'
    echo ""
    echo "--- ENA driver version ---"
    ethtool -i eth0 2>/dev/null | grep -E 'driver|version' || echo "(ethtool unavailable)"
    echo ""
    echo "--- ENA allowance exceeded counters ---"
    ethtool -S eth0 2>/dev/null | grep -i 'allowance_exceeded' || echo "0 (no allowance counters found)"
    echo ""
    echo "--- Ring buffer sizes ---"
    ethtool -g eth0 2>/dev/null || echo "(ring buffer info unavailable)"
    echo ""
    echo "--- Peer RTT (inter-node) ---"
    # Ping other broker IPs if available
    for var in BROKER_1_IP BROKER_2_IP BROKER_3_IP CONNECT_1_IP MONITOR_1_IP; do
      ip_val="${!var:-}"
      [[ -z "$ip_val" ]] && continue
      # Skip pinging ourselves
      if ip addr show | grep -q "$ip_val"; then continue; fi
      rtt=$(ping -c 3 -q "$ip_val" 2>/dev/null | grep 'rtt\|round-trip' | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "unreachable")
      echo "$var ($ip_val): min rtt = ${rtt} ms"
    done
    echo ""

    # ── Section 6: Open File Descriptors ─────────────────────────────────────
    echo "=== OPEN FILE DESCRIPTORS ==="
    echo "--- Per-process FD counts (top 5) ---"
    # Find broker or connect Java process
    for proc_name in kafka connect; do
      pid=$(pgrep -f "kafka.Kafka\|ConnectDistributed" 2>/dev/null | head -1 || true)
      [[ -n "$pid" ]] && break
    done
    if [[ -n "${pid:-}" ]]; then
      fd_count=$(ls /proc/"$pid"/fd 2>/dev/null | wc -l || echo "?")
      fd_limit=$(cat /proc/"$pid"/limits 2>/dev/null | grep 'open files' | awk '{print $4}' || echo "?")
      echo "Kafka/Connect PID $pid: open FDs = $fd_count, limit = $fd_limit"
    else
      echo "(No Kafka or Connect process found)"
    fi
    echo ""
    echo "--- System-wide FD usage ---"
    cat /proc/sys/fs/file-nr
    echo ""

    # ── Section 7: JVM Configuration ─────────────────────────────────────────
    echo "=== JVM CONFIGURATION ==="
    echo "--- Kafka/Connect JVM flags ---"
    # Extract from running process or Docker env
    jvm_flags=""
    for pid in $(pgrep -f 'kafka.Kafka\|ConnectDistributed' 2>/dev/null || true); do
      cmdline=$(tr '\0' ' ' </proc/"$pid"/cmdline 2>/dev/null || echo "")
      if [[ -n "$cmdline" ]]; then
        echo "PID $pid: $(echo "$cmdline" | grep -oE '\-X[^ ]+|\-XX:[^ ]+' | tr '\n' ' ')"
        jvm_flags="found"
      fi
    done
    if [[ -z "$jvm_flags" ]]; then
      # Try Docker container env
      docker inspect broker 2>/dev/null | \
        python3 -c "import sys,json; d=json.load(sys.stdin); \
          [print(e) for c in d for e in c.get('Config',{}).get('Env',[]) if 'HEAP' in e or 'JVM' in e or 'KAFKA_HEAP' in e]" \
        2>/dev/null || echo "(Kafka process not running or not Docker)"
    fi
    echo ""
    echo "--- Java version ---"
    java -version 2>&1 || docker exec broker java -version 2>&1 || echo "(java not in PATH)"
    echo ""

    # ── Section 8: Kafka Broker Configuration ────────────────────────────────
    echo "=== KAFKA BROKER CONFIGURATION ==="
    echo "--- Key broker settings (from running broker via AdminClient) ---"
    CONNECT_URL="http://localhost:8083"
    # Try to read broker config via kafka-configs if available
    if command -v kafka-configs.sh &>/dev/null; then
      kafka-configs.sh --bootstrap-server "localhost:9092" --describe \
        --entity-type brokers --entity-default 2>/dev/null | \
        grep -E 'num\.(io|network|replica)|socket\.(send|receive)|log\.dirs|min\.insync|unclean' || \
        echo "(kafka-configs.sh failed)"
    else
      # Read from docker-compose env or container env
      for key in num.io.threads num.network.threads num.replica.fetchers \
                  socket.send.buffer.bytes socket.receive.buffer.bytes \
                  min.insync.replicas unclean.leader.election.enable \
                  log.dirs log.retention.hours; do
        val=$(docker exec broker bash -c "grep -E '^${key}=' /etc/kafka/server.properties 2>/dev/null || \
          env | grep -i '$(echo $key | tr '.' '_' | tr '[:lower:]' '[:upper:]')' | head -1" 2>/dev/null || echo "")
        [[ -n "$val" ]] && echo "$val" || echo "${key} = (not found)"
      done
    fi
    echo ""
    echo "--- Docker container env (Kafka tuning vars) ---"
    docker inspect broker 2>/dev/null | \
      python3 -c "
import sys, json
d = json.load(sys.stdin)
keys = ['NUM_IO_THREADS','NUM_NETWORK_THREADS','NUM_REPLICA_FETCHERS',
        'SOCKET_SEND_BUFFER','SOCKET_RECEIVE_BUFFER','MIN_INSYNC',
        'UNCLEAN_LEADER','LOG_RETENTION','HEAP_OPTS']
for c in d:
    for e in c.get('Config',{}).get('Env',[]):
        if any(k in e for k in keys):
            print(e)
" 2>/dev/null || echo "(Docker inspect failed — broker may not be running)"
    echo ""

    # ── Section 9: Replication and Partition Health ───────────────────────────
    echo "=== REPLICATION AND PARTITION HEALTH ==="
    BROKER_PORT="${BOOTSTRAP_SERVER:-localhost:9092}"
    BROKER_PORT="${BROKER_PORT##*:}"
    # Use kafka-topics.sh from Docker if available
    URP=$(docker exec broker kafka-topics \
      --bootstrap-server "localhost:9092" \
      --describe --under-replicated-partitions 2>/dev/null | grep -c 'Topic:' || echo "0")
    echo "Under-replicated partitions: $URP"
    UMR=$(docker exec broker kafka-topics \
      --bootstrap-server "localhost:9092" \
      --describe --unavailable-partitions 2>/dev/null | grep -c 'Topic:' || echo "0")
    echo "Unavailable partitions     : $UMR"
    echo ""

    # ── Section 10: Network Latency ───────────────────────────────────────────
    echo "=== NETWORK LATENCY ==="
    echo "--- DNS resolution ---"
    time_dns=$(date +%s%3N)
    host "$(hostname -f)" &>/dev/null || true
    time_dns_end=$(date +%s%3N)
    echo "Local hostname DNS: $((time_dns_end - time_dns)) ms"
    echo ""
    echo "--- TCP connect to local Kafka port ---"
    for port in 9092 8083 8081; do
      t_start=$(date +%s%3N)
      timeout 2 bash -c "echo >/dev/tcp/localhost/$port" 2>/dev/null && \
        echo "localhost:$port reachable ($(( $(date +%s%3N) - t_start )) ms)" || \
        echo "localhost:$port NOT reachable"
    done
    echo ""

    # ── fio probe (only if --probes passed in --local mode) ──────────────────
    if $RUN_PROBES; then
      echo "=== FIO DISK PROBE ==="
      if ! command -v fio &>/dev/null; then
        echo "(fio not installed — skipping)"
      else
        FIO_DIR="${KAFKA_LOG_DIR}/fio-test-$$"
        mkdir -p "$FIO_DIR"
        fio --name=latency-test \
            --ioengine=libaio \
            --rw=randwrite \
            --bs=4k \
            --numjobs=1 \
            --iodepth=1 \
            --runtime=30 \
            --time_based \
            --filename="${FIO_DIR}/fio.dat" \
            --size=512m \
            --output-format=normal \
            --lat_percentiles=1 \
            --percentile_list=50:95:99:99.9 \
            2>/dev/null
        rm -rf "$FIO_DIR"
      fi
      echo ""
    fi

  } 2>&1 | tee "$REPORT_FILE"

  echo ""
  echo "=== REPORT WRITTEN ==="
  echo "$REPORT_FILE"
  exit 0
fi

# =============================================================================
# JUMPBOX MODE: dispatch to all nodes, collect reports, diff, write FINDINGS.md
# =============================================================================

if [[ ! -f "$ENV_FILE" ]]; then
  error ".env not found at $ENV_FILE"
  exit 1
fi

set +u
# shellcheck disable=SC1090
source "$ENV_FILE"
set -u

DISPATCH_MODE="${DISPATCH_MODE:-ssm}"
DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
DEPLOY_DIR="/home/${DEPLOY_USER}/cdc-on-ec2-docker"
AWS_REGION="${AWS_REGION:-us-east-1}"
BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-${KAFKA_BOOTSTRAP_SERVERS:-}}"
WORKDIR="${WORKDIR:-./kafka-audit-$(date +%Y%m%d-%H%M%S)}"

# ─── Build node list ──────────────────────────────────────────────────────────
if [[ "$DISPATCH_MODE" == "ssh" ]]; then
  SSH_KEY="${SSH_KEY_PATH:-}"
  if [[ -z "$SSH_KEY" || ! -f "$SSH_KEY" ]]; then
    error "SSH_KEY_PATH not set or key not found (required for DISPATCH_MODE=ssh)"
    exit 1
  fi
  NODES=(
    "broker1:${BROKER_1_IP:-}"
    "broker2:${BROKER_2_IP:-}"
    "broker3:${BROKER_3_IP:-}"
    "connect:${CONNECT_1_IP:-}"
    "monitor:${MONITOR_1_IP:-}"
  )
else
  if ! command -v aws &>/dev/null; then
    error "AWS CLI not found"
    exit 1
  fi
  NODES=(
    "broker1:${BROKER_1_INSTANCE_ID:-}"
    "broker2:${BROKER_2_INSTANCE_ID:-}"
    "broker3:${BROKER_3_INSTANCE_ID:-}"
    "connect:${CONNECT_1_INSTANCE_ID:-}"
    "monitor:${MONITOR_1_INSTANCE_ID:-}"
  )
fi

# Validate all node addresses are set
for entry in "${NODES[@]}"; do
  name="${entry%%:*}"; addr="${entry##*:}"
  if [[ -z "$addr" ]]; then
    error "Address not set for node '$name' — check .env"
    exit 1
  fi
done

# ─── Helper: run command on a node, poll for completion ───────────────────────
# Writes output to $logfile; returns 0 on success.
run_on_node() {
  local node_name="$1"
  local node_addr="$2"
  local cmd="$3"
  local logfile="$4"
  local timeout_s="${5:-120}"

  if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    ssh -n -i "$SSH_KEY" \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      -o ServerAliveInterval=15 \
      "${DEPLOY_USER}@${node_addr}" \
      "$cmd" >"$logfile" 2>&1
    return $?
  fi

  # SSM mode
  local cmd_id
  cmd_id=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$node_addr" \
    --document-name "AWS-RunShellScript" \
    --parameters "$(jq -n --arg c "$cmd" '{"commands":[$c],"executionTimeout":["300"]}')" \
    --timeout-seconds "$timeout_s" \
    --output text \
    --query 'Command.CommandId' 2>"$logfile") || { echo "SSM send-command failed" >>"$logfile"; return 1; }

  if [[ -z "$cmd_id" || "$cmd_id" == "None" ]]; then
    echo "SSM: empty command ID" >>"$logfile"; return 1
  fi

  local status="Pending"
  for _ in $(seq 1 $(( timeout_s / 5 + 1 ))); do
    sleep 5
    local result
    result=$(aws ssm get-command-invocation \
      --region "$AWS_REGION" \
      --command-id "$cmd_id" \
      --instance-id "$node_addr" \
      --output json 2>/dev/null) || continue

    status=$(echo "$result" | jq -r '.Status // "Pending"')
    case "$status" in
      Success)
        { echo "$result" | jq -r '.StandardOutputContent // empty'
          echo "$result" | jq -r '.StandardErrorContent // empty'; } >"$logfile"
        return 0 ;;
      Failed|TimedOut|Cancelled|DeliveryTimedOut|ExecutionTimedOut)
        { echo "$result" | jq -r '.StandardOutputContent // empty'
          echo "$result" | jq -r '.StandardErrorContent // empty'
          echo "SSM status: $status"; } >>"$logfile"
        return 1 ;;
    esac
  done
  echo "SSM: timed out after ${timeout_s}s (cmd=$cmd_id)" >>"$logfile"
  return 1
}

# ─── Header ───────────────────────────────────────────────────────────────────
mkdir -p "$WORKDIR/raw" "$WORKDIR/diffs"

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║       Kafka Latency Audit — 5-Node CDC Cluster               ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Dispatch mode : ${BOLD}${DISPATCH_MODE^^}${NC}"
echo -e "  Output dir    : ${BOLD}$WORKDIR${NC}"
[[ -n "$BOOTSTRAP_SERVER" ]] && echo -e "  Bootstrap     : ${BOLD}$BOOTSTRAP_SERVER${NC}"
echo ""

# ─── Phase 1: Pre-flight ─────────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}▶ Phase 1: Pre-flight${NC}"

declare -a REACHABLE_NAMES=() REACHABLE_ADDRS=()
FAILED_PREFLIGHT=0

for entry in "${NODES[@]}"; do
  node_name="${entry%%:*}"; node_addr="${entry##*:}"
  echo -n "  Checking $node_name ($node_addr) ... "
  pf_log="$WORKDIR/raw/${node_name}.preflight.log"

  if run_on_node "$node_name" "$node_addr" "echo ok && sudo -n true" "$pf_log" 30; then
    echo -e "${GREEN}ok${NC}"
    REACHABLE_NAMES+=("$node_name")
    REACHABLE_ADDRS+=("$node_addr")
  else
    echo -e "${RED}FAILED${NC} (see $pf_log)"
    FAILED_PREFLIGHT=$((FAILED_PREFLIGHT + 1))
  fi
done

REACHABLE_COUNT="${#REACHABLE_NAMES[@]}"
echo ""
if [[ $REACHABLE_COUNT -eq 0 ]]; then
  error "No nodes reachable. Aborting."; exit 1
fi
[[ $FAILED_PREFLIGHT -gt 0 ]] && \
  warn "$FAILED_PREFLIGHT node(s) unreachable — continuing with $REACHABLE_COUNT node(s)."

# ─── Phase 2: Dispatch audit to all reachable nodes (parallel) ───────────────
echo -e "${BOLD}${BLUE}▶ Phase 2: Running audit on all nodes (parallel, read-only)${NC}"

# Build --probes flag to pass through if requested
PROBE_FLAG=""
$RUN_PROBES && PROBE_FLAG="--probes"

declare -a AUDIT_PIDS=() REPORT_FILES=()

for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
  node_name="${REACHABLE_NAMES[$i]}"
  node_addr="${REACHABLE_ADDRS[$i]}"
  audit_log="$WORKDIR/raw/${node_name}.log"
  report_file="$WORKDIR/raw/${node_name}-audit.txt"
  REPORT_FILES+=("$report_file")

  (
    # Run the audit on the node using this same script with --local
    BOOTSTRAP_ARG=""
    [[ -n "$BOOTSTRAP_SERVER" ]] && BOOTSTRAP_ARG="--bootstrap $BOOTSTRAP_SERVER"
    cmd="cd ${DEPLOY_DIR} && sudo bash scripts/ops-latency-audit.sh --local ${PROBE_FLAG} ${BOOTSTRAP_ARG} 2>&1"

    if run_on_node "$node_name" "$node_addr" "$cmd" "$audit_log" 180; then
      # Extract the report path from output (last line matching /tmp/kafka-latency-audit-*)
      remote_report=$(grep '/tmp/kafka-latency-audit-' "$audit_log" | grep -v '===' | tail -1 | tr -d '[:space:]')

      if [[ -n "$remote_report" ]]; then
        # Pull the file back
        fetch_log="$audit_log.fetch"
        if run_on_node "$node_name" "$node_addr" \
            "base64 -w0 '${remote_report}'" "$fetch_log" 30; then
          grep -E '^[A-Za-z0-9+/=]+$' "$fetch_log" | tail -1 | \
            base64 -d >"$report_file" 2>/dev/null || cp "$audit_log" "$report_file"
        else
          cp "$audit_log" "$report_file"
        fi
      else
        # Report content is in audit_log (SSM stdout capture)
        cp "$audit_log" "$report_file"
      fi
    else
      echo "AUDIT_ERROR: audit failed on $node_name" >>"$audit_log"
      cp "$audit_log" "$report_file"
    fi
  ) &
  AUDIT_PIDS+=($!)
done

# Wait for all
AUDIT_FAILED=0
for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
  node_name="${REACHABLE_NAMES[$i]}"
  if wait "${AUDIT_PIDS[$i]}"; then
    info "$node_name: audit collected → ${REPORT_FILES[$i]}"
  else
    warn "$node_name: audit encountered errors"
    AUDIT_FAILED=$((AUDIT_FAILED + 1))
  fi
done
echo ""

# ─── Phase 3: Cross-node diff ─────────────────────────────────────────────────
echo -e "${BOLD}${BLUE}▶ Phase 3: Cross-node diff${NC}"

SECTIONS=(
  "SYSTEM OVERVIEW"
  "CPU AND MEMORY"
  "KERNEL PARAMETERS"
  "DISK AND FILESYSTEM"
  "NETWORK CONFIGURATION"
  "OPEN FILE DESCRIPTORS"
  "JVM CONFIGURATION"
  "KAFKA BROKER CONFIGURATION"
  "REPLICATION AND PARTITION HEALTH"
  "NETWORK LATENCY"
)

extract_section() {
  local report="$1" section="$2" outfile="$3"
  awk -v sec="$section" '
    /^=== / { in_sec = (toupper($0) ~ toupper(sec)); next }
    in_sec  { print }
  ' "$report" >"$outfile"
}

DRIFT_COUNT=0
declare -a DRIFT_SECTIONS=()

for section in "${SECTIONS[@]}"; do
  slug=$(echo "$section" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
  diff_file="$WORKDIR/diffs/${slug}.diff"

  declare -a sfiles=()
  for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
    n="${REACHABLE_NAMES[$i]}"; r="${REPORT_FILES[$i]}"
    sf="$WORKDIR/raw/${n}.${slug}.txt"
    [[ -f "$r" ]] && extract_section "$r" "$section" "$sf" || touch "$sf"
    sfiles+=("$sf")
  done

  ref="${sfiles[0]}"; has_diff=false
  {
    echo "# Section: $section"
    echo "# Reference: ${REACHABLE_NAMES[0]}"
    echo ""
    for i in $(seq 1 $((REACHABLE_COUNT - 1))); do
      n="${REACHABLE_NAMES[$i]}"
      if ! diff -q "$ref" "${sfiles[$i]}" &>/dev/null; then
        has_diff=true
        echo "## ${REACHABLE_NAMES[0]} vs $n"
        diff -u --label "${REACHABLE_NAMES[0]}" --label "$n" "$ref" "${sfiles[$i]}" || true
        echo ""
      fi
    done
  } >"$diff_file"

  if $has_diff; then
    warn "Drift: $section"
    DRIFT_SECTIONS+=("$section")
    DRIFT_COUNT=$((DRIFT_COUNT + 1))
  else
    info "No drift: $section"
  fi
done
echo ""

# ─── Phase 4: Collect metrics and detect red flags ────────────────────────────
echo -e "${BOLD}${BLUE}▶ Phase 4: Generating FINDINGS.md${NC}"

declare -a RED_FLAGS=()

# Per-node metric extraction
declare -A SWAPPINESS=() THP=() NOATIME=() IOSCHEDULER=() ENA_EX=()
declare -A FD_LIMIT=() JVM_HEAP=() GC_ALGO=()
declare -A NUM_IO=() NUM_NET=() SOCK_BUF=() UNCLEAN=() MIR=() UNDER_REP=()

for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
  n="${REACHABLE_NAMES[$i]}"; r="${REPORT_FILES[$i]}"

  SWAPPINESS["$n"]=$(grep -iE 'vm\.swappiness\s*=' "$r" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "?")
  THP["$n"]=$(grep -iE 'transparent|thp|enabled:' "$r" 2>/dev/null | grep -oE '\[always\]|\[madvise\]|\[never\]' | head -1 || echo "?")
  NOATIME["$n"]=$(grep -ic 'noatime' "$r" 2>/dev/null | grep -q '^0$' && echo "missing" || echo "present")
  IOSCHEDULER["$n"]=$(grep -oE '\[(mq-deadline|none|deadline|cfq|bfq|kyber)\]' "$r" 2>/dev/null | head -1 || echo "?")
  ENA_EX["$n"]=$(grep -iE 'allowance_exceeded' "$r" 2>/dev/null | grep -v ' 0$' | head -1 || echo "0")
  FD_LIMIT["$n"]=$(grep -iE 'limit|nofile|open files' "$r" 2>/dev/null | grep -oE '[0-9]{5,}' | sort -n | tail -1 || echo "?")
  JVM_HEAP["$n"]=$(grep -iEo '\-Xmx[0-9]+[gGmM]|HEAP_OPTS.*[0-9]+[gGmM]' "$r" 2>/dev/null | grep -oE '[0-9]+[gGmM]' | head -1 || echo "?")
  GC_ALGO["$n"]=$(grep -oE 'UseG1GC|UseZGC|UseShenandoahGC|UseCMS|UseParallelGC' "$r" 2>/dev/null | head -1 || echo "?")
  NUM_IO["$n"]=$(grep -iE 'NUM_IO_THREADS|num\.io\.threads' "$r" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "?")
  NUM_NET["$n"]=$(grep -iE 'NUM_NETWORK_THREADS|num\.network\.threads' "$r" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "?")
  SOCK_BUF["$n"]=$(grep -iE 'SOCKET_SEND_BUFFER|socket\.send\.buffer' "$r" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "?")
  UNCLEAN["$n"]=$(grep -iE 'UNCLEAN_LEADER|unclean\.leader\.election' "$r" 2>/dev/null | grep -oiE 'true|false' | head -1 || echo "?")
  MIR["$n"]=$(grep -iE 'MIN_INSYNC|min\.insync\.replicas' "$r" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "?")
  UNDER_REP["$n"]=$(grep -iE 'under.replicated.partition' "$r" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "0")

  # Red flag checks
  sw="${SWAPPINESS[$n]}"
  [[ "$sw" =~ ^[0-9]+$ && $sw -gt 1 ]] && \
    RED_FLAGS+=("**$n**: vm.swappiness=$sw (should be ≤1)")

  [[ "${THP[$n]}" == "[always]" ]] && \
    RED_FLAGS+=("**$n**: Transparent Huge Pages = [always] (should be [never])")

  [[ "${NOATIME[$n]}" == "missing" ]] && \
    RED_FLAGS+=("**$n**: noatime not found on Kafka log dir mount")

  fd="${FD_LIMIT[$n]}"
  [[ "$fd" =~ ^[0-9]+$ && $fd -lt 100000 ]] && \
    RED_FLAGS+=("**$n**: open file descriptor limit=$fd (should be ≥100000)")

  heap="${JVM_HEAP[$n]}"
  heap_gb=0
  [[ "$heap" =~ ^([0-9]+)[gG]$ ]] && heap_gb="${BASH_REMATCH[1]}"
  [[ "$heap" =~ ^([0-9]+)[mM]$ ]] && heap_gb=$(( BASH_REMATCH[1] / 1024 ))
  [[ $heap_gb -gt 6 ]] && \
    RED_FLAGS+=("**$n**: JVM heap=${heap} (>6 GB increases GC pause risk — target 4–6 GB)")

  gc="${GC_ALGO[$n]}"
  [[ -n "$gc" && "$gc" != "?" && "$gc" != "UseG1GC" && "$gc" != "UseZGC" ]] && \
    RED_FLAGS+=("**$n**: GC=${gc} (use G1GC or ZGC for low-latency Kafka)")

  io="${NUM_IO[$n]}"
  [[ "$io" =~ ^[0-9]+$ && $io -lt 8 ]] && \
    RED_FLAGS+=("**$n**: num.io.threads=$io (should match vCPU count, typically ≥8)")

  nt="${NUM_NET[$n]}"
  [[ "$nt" =~ ^[0-9]+$ && $nt -lt 8 ]] && \
    RED_FLAGS+=("**$n**: num.network.threads=$nt (should be ≥8 on busy brokers)")

  sb="${SOCK_BUF[$n]}"
  [[ "$sb" =~ ^[0-9]+$ && $sb -le 102400 ]] && \
    RED_FLAGS+=("**$n**: socket.send.buffer.bytes=$sb (default — increase to 4 MB for high throughput)")

  [[ "${UNCLEAN[$n]}" == "true" ]] && \
    RED_FLAGS+=("**$n**: unclean.leader.election.enable=true (data loss risk)")

  mir="${MIR[$n]}"
  [[ "$mir" =~ ^[0-9]+$ && $mir -lt 2 ]] && \
    RED_FLAGS+=("**$n**: min.insync.replicas=$mir (should be 2 with RF=3)")

  ur="${UNDER_REP[$n]}"
  [[ "$ur" =~ ^[0-9]+$ && $ur -gt 0 ]] && \
    RED_FLAGS+=("**$n**: $ur under-replicated partition(s)")

  ena="${ENA_EX[$n]}"
  [[ "$ena" != "0" && -n "$ena" && "$ena" != "not found" ]] && \
    RED_FLAGS+=("**$n**: ENA allowance_exceeded counters non-zero")
done

RED_FLAG_COUNT="${#RED_FLAGS[@]}"

# ─── Write FINDINGS.md ────────────────────────────────────────────────────────
FINDINGS="$WORKDIR/FINDINGS.md"
NOW=$(date '+%Y-%m-%d %H:%M:%S %Z')
BOOTSTRAP_ARG="${BOOTSTRAP_SERVER:-<HOST>:9092}"

{
cat <<HEADER
# Kafka Latency Audit — Findings

**Generated:** $NOW
**Nodes audited:** $REACHABLE_COUNT / 5
**Dispatch mode:** ${DISPATCH_MODE^^}
**Red flags:** $RED_FLAG_COUNT
**Config drift (sections):** $DRIFT_COUNT

---

## 1. Executive Summary

HEADER

if [[ $RED_FLAG_COUNT -eq 0 ]]; then
  echo "No latency red flags found. All checked settings are within recommended ranges."
else
  top=0
  for flag in "${RED_FLAGS[@]}"; do
    [[ $top -ge 5 ]] && break
    echo "- $flag"
    top=$((top + 1))
  done
  [[ $RED_FLAG_COUNT -gt 5 ]] && echo "_...and $((RED_FLAG_COUNT - 5)) more — see Section 3._"
fi

cat <<'DRIFT_HDR'

---

## 2. Drift Across Nodes

| Setting | broker1 | broker2 | broker3 | connect | monitor |
|---------|---------|---------|---------|---------|---------|
DRIFT_HDR

# Emit a table row only if values differ across nodes
emit_row() {
  local label="$1"; shift
  declare -n map="$1"; shift
  local all_same=true; local first="${map[${REACHABLE_NAMES[0]}]:-?}"
  for n in "${REACHABLE_NAMES[@]}"; do [[ "${map[$n]:-?}" != "$first" ]] && all_same=false; done
  $all_same && return
  local row="| $label"
  for n in broker1 broker2 broker3 connect monitor; do
    row+=" | ${map[$n]:-—}"
  done
  row+=" |"
  echo "$row"
}

emit_row "vm.swappiness"            SWAPPINESS
emit_row "THP"                      THP
emit_row "noatime"                  NOATIME
emit_row "I/O scheduler"            IOSCHEDULER
emit_row "fd limit"                 FD_LIMIT
emit_row "JVM heap"                 JVM_HEAP
emit_row "GC algorithm"             GC_ALGO
emit_row "num.io.threads"           NUM_IO
emit_row "num.network.threads"      NUM_NET
emit_row "socket.send.buffer"       SOCK_BUF
emit_row "unclean.leader.election"  UNCLEAN
emit_row "min.insync.replicas"      MIR
emit_row "under-replicated parts"   UNDER_REP

[[ $DRIFT_COUNT -eq 0 ]] && echo "" && echo "_No configuration drift detected._"

cat <<'FLAGS_HDR'

---

## 3. Latency Red Flags

FLAGS_HDR

if [[ $RED_FLAG_COUNT -eq 0 ]]; then
  echo "No red flags detected."
else
  for flag in "${RED_FLAGS[@]}"; do echo "- $flag"; done
fi

cat <<'STEPS_HDR'

---

## 4. Recommended Next Steps

STEPS_HDR

step=1
printed_fixes=""
emit_fix() {
  local key="$1" text="$2"
  [[ "$printed_fixes" == *"|$key|"* ]] && return
  printed_fixes+="|$key|"
  echo "$step. $text"
  step=$((step + 1))
}

for flag in "${RED_FLAGS[@]}"; do
  case "$flag" in
    *"[always]"*)
      emit_fix THP "**Disable Transparent Huge Pages:** \`echo never > /sys/kernel/mm/transparent_hugepage/enabled\` and persist via \`/etc/rc.local\` or a systemd unit. Reduces multi-ms GC pause spikes." ;;
    *swappiness*)
      emit_fix SWAP "**Set vm.swappiness=1:** \`sysctl -w vm.swappiness=1\` + persist in \`/etc/sysctl.d/99-kafka.conf\`. Prevents latency spikes from memory pressure without risking OOM kills." ;;
    *noatime*)
      emit_fix NOATIME "**Add noatime to Kafka log dir mount:** Edit \`/etc/fstab\`, append \`noatime\` to mount options for \`/data/kafka\`. Eliminates a metadata write on every log segment read." ;;
    *socket*default*|*"socket.send.buffer"*)
      emit_fix SOCKBUF "**Increase socket buffers:** Set \`socket.send.buffer.bytes=4194304\` and \`socket.receive.buffer.bytes=4194304\` in broker config. Also raise \`net.core.rmem_max\` / \`wmem_max\` to match." ;;
    *num.io.threads*)
      emit_fix IOTHREADS "**Increase num.io.threads:** Set to vCPU count (i3.4xlarge = 16). I/O threads handle disk reads/writes — too few causes replication fetch queuing." ;;
    *num.network.threads*)
      emit_fix NETTHREADS "**Increase num.network.threads:** Set to ≥8. Controls the request processor pool — low values bottleneck producer and consumer connections." ;;
    *"JVM heap"*">6"*)
      emit_fix HEAP "**Reduce JVM heap to 4–6 GB:** Use \`-Xmx6g -Xms6g -XX:+UseG1GC\`. Heap >6 GB causes multi-second GC pauses under pressure." ;;
    *GC=*)
      emit_fix GC "**Switch GC to G1GC or ZGC:** Add \`-XX:+UseG1GC\` (Java 8–16) or \`-XX:+UseZGC\` (Java 17+) to \`KAFKA_HEAP_OPTS\`. Avoids stop-the-world pauses from CMS/Parallel GC." ;;
    *unclean*)
      emit_fix UNCLEAN "**Disable unclean leader election:** Set \`unclean.leader.election.enable=false\`. Prevents data loss when an out-of-sync replica is elected leader." ;;
    *min.insync*)
      emit_fix MIR "**Set min.insync.replicas=2:** Ensures that with RF=3 a two-broker outage doesn't silently accept unacknowledged writes." ;;
    *under-replicated*)
      emit_fix URP "**Investigate under-replicated partitions:** Run \`kafka-topics.sh --describe --under-replicated-partitions\`. Common causes: GC pauses, NVMe I/O saturation, or a recently restarted broker still catching up." ;;
    *ENA*allowance*)
      emit_fix ENA "**Check EC2 network allowance:** Non-zero \`*_allowance_exceeded\` counters mean the instance is hitting EC2 network burst limits. Monitor with \`ethtool -S eth0 | grep allowance\`. Consider upgrading instance type or splitting high-replication topics." ;;
    *fd*limit*)
      emit_fix FD "**Raise open file descriptor limit:** Add \`* hard nofile 131072\` and \`* soft nofile 131072\` to \`/etc/security/limits.d/99-kafka.conf\`. Kafka opens one FD per partition per log segment." ;;
  esac
done

[[ $step -eq 1 ]] && echo "No fixes required. Run active probes (Section 5) to establish a baseline."

cat <<PROBES_HDR

---

## 5. Active Probe Plan

Review these commands and re-run the script with \`--probes\` to execute them automatically.

### fio — Disk write latency (all nodes, parallel, ~30 s each)

\`\`\`bash
bash scripts/ops-latency-audit.sh --probes
\`\`\`

Red flag threshold: fio p99 write latency > 5 ms on any node.

### producer-perf-test — End-to-end Kafka latency (broker1 only)

\`\`\`bash
bash scripts/ops-latency-audit.sh --probes --bootstrap ${BOOTSTRAP_ARG}
\`\`\`

Red flag threshold: p99 end-to-end > 50 ms.

**Quiet-window guidance:** Schedule during low-CDC-throughput periods.
fio writes a 512 MB test file to the Kafka log directory — confirm disk has headroom.
producer-perf-test creates a temporary topic; confirm it is deleted after the run.

---

## 6. Drift Diff Files

PROBES_HDR

for section in "${SECTIONS[@]}"; do
  slug=$(echo "$section" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
  echo "- [\`diffs/${slug}.diff\`](diffs/${slug}.diff) — $section"
done

cat <<'RAW_HDR'

---

## 7. Raw Reports

RAW_HDR

for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
  n="${REACHABLE_NAMES[$i]}"
  echo "- [\`raw/${n}-audit.txt\`](raw/${n}-audit.txt)"
  echo "- [\`raw/${n}.log\`](raw/${n}.log) — dispatch log"
done

} >"$FINDINGS"

info "FINDINGS.md written: $FINDINGS"

# ─── Phase 5: Active probes already included via --probes flag ───────────────
# (the --local on-node path runs fio when --probes is set)
if $RUN_PROBES && [[ -n "$BOOTSTRAP_SERVER" ]]; then
  echo ""
  echo -e "${BOLD}${BLUE}▶ Phase 5: producer-perf-test on $PERF_NODE${NC}"
  # Find the perf node
  PERF_ADDR=""
  for entry in "${NODES[@]}"; do
    n="${entry%%:*}"; addr="${entry##*:}"
    [[ "$n" == "$PERF_NODE" ]] && PERF_ADDR="$addr"
  done
  if [[ -n "$PERF_ADDR" ]]; then
    perf_log="$WORKDIR/raw/${PERF_NODE}.perf.log"
    perf_cmd="cd ${DEPLOY_DIR} && docker exec broker kafka-producer-perf-test \
      --topic __latency-audit-test \
      --num-records 50000 \
      --record-size 1024 \
      --throughput 5000 \
      --producer-props bootstrap.servers=${BOOTSTRAP_SERVER} \
        acks=all linger.ms=0 batch.size=16384 \
      --print-metrics 2>&1"
    if run_on_node "$PERF_NODE" "$PERF_ADDR" "$perf_cmd" "$perf_log" 120; then
      info "producer-perf-test complete → $perf_log"
      {
        echo ""
        echo "---"
        echo ""
        echo "## 8. Producer Perf Results"
        echo ""
        echo "\`\`\`"
        tail -30 "$perf_log"
        echo "\`\`\`"
      } >>"$FINDINGS"
    else
      warn "producer-perf-test failed — see $perf_log"
    fi
  else
    warn "Perf node '$PERF_NODE' not in reachable list — skipping"
  fi
fi

# ─── Phase 6: Cleanup ────────────────────────────────────────────────────────
if $DO_CLEANUP; then
  echo ""
  echo -e "${BOLD}${BLUE}▶ Phase 6: Cleanup remote temp files${NC}"
  for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
    n="${REACHABLE_NAMES[$i]}"; addr="${REACHABLE_ADDRS[$i]}"
    cl_log="$WORKDIR/raw/${n}.cleanup.log"
    run_on_node "$n" "$addr" \
      "rm -f /tmp/kafka-latency-audit-*.txt" \
      "$cl_log" 20 && info "$n: cleaned" || warn "$n: cleanup failed"
  done
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║                      Audit Complete                          ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Findings:${NC} $(realpath "$FINDINGS")"
echo ""
echo "  TL;DR:"
if [[ $RED_FLAG_COUNT -eq 0 ]]; then
  echo -e "  • ${GREEN}No latency red flags${NC} — configuration within recommended ranges"
else
  echo -e "  • ${RED}$RED_FLAG_COUNT red flag(s)${NC} — see Section 3 in FINDINGS.md"
fi
if [[ $DRIFT_COUNT -gt 0 ]]; then
  echo -e "  • ${YELLOW}$DRIFT_COUNT section(s) with cross-node drift${NC} — diffs in $WORKDIR/diffs/"
else
  echo -e "  • ${GREEN}No configuration drift${NC} across nodes"
fi
if ! $RUN_PROBES; then
  echo -e "  • Active probes not run — rerun with ${BOLD}--probes${NC} after reviewing FINDINGS.md"
fi
echo ""

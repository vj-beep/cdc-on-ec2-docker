#!/usr/bin/env bash
# =============================================================================
# ops-latency-audit.sh — Kafka Latency Audit for 5-Node CDC Cluster
#
# OVERVIEW
# --------
# Read-only latency assessment for a running Confluent Platform cluster.
# The script re-invokes itself on each EC2 node using the project's standard
# dual-mode dispatch pattern (SSM or SSH), so no separate audit tool is needed.
# The repo is already on every node (Phase 2a); this just runs it.
#
# WHAT IT CHECKS (on every node)
# --------------------------------
#  1. System Overview    — instance type, CPU, RAM, uptime
#  2. CPU & Memory       — vCPU count, NUMA topology, huge pages
#  3. Kernel Parameters  — vm.swappiness, dirty ratios, TCP/socket buffers, THP
#  4. Disk & Filesystem  — mount options (noatime?), I/O scheduler, xfs/ext4,
#                          Kafka log dir mount specifically, disk usage
#  5. Network            — ENA driver, ring buffers, allowance-exceeded counters,
#                          inter-node ping RTT to all other nodes
#  6. File Descriptors   — per-process FD count + limit, system-wide usage
#  7. JVM Configuration  — heap size (-Xmx), GC algorithm, Java version
#  8. Broker Config      — num.io.threads, num.network.threads, socket buffers,
#                          min.insync.replicas, unclean.leader.election
#  9. Partition Health   — under-replicated + unavailable partition counts
# 10. Network Latency    — DNS resolution time, TCP connect time to local ports
#
# WHAT IT PRODUCES (on the jumpbox)
# -----------------------------------
#  WORKDIR/
#    FINDINGS.md                  — consolidated report with red flags + next steps
#    raw/<node>-audit.txt         — full audit output per node
#    raw/<node>.log               — dispatch / SSM stdout for that node
#    diffs/<section>.diff         — unified diff for each config section across nodes
#
# USAGE
# -----
# Standard audit (from jumpbox, reads .env for all node addresses):
#   bash scripts/ops-latency-audit.sh
#
# With active disk probes (~2 min extra, runs fio on each node):
#   bash scripts/ops-latency-audit.sh --probes
#
# With fio + end-to-end producer latency test:
#   bash scripts/ops-latency-audit.sh --probes --bootstrap 10.0.1.10:9092
#
# Custom output directory:
#   bash scripts/ops-latency-audit.sh --workdir /tmp/audit-2026-05-01
#
# Run producer-perf on a node other than broker1:
#   bash scripts/ops-latency-audit.sh --probes --bootstrap 10.0.1.10:9092 --perf-node broker2
#
# Remove remote /tmp/kafka-latency-audit-* files after collection:
#   bash scripts/ops-latency-audit.sh --cleanup
#
# Run the on-node audit directly (e.g. for a manual single-node check):
#   sudo bash scripts/ops-latency-audit.sh --local
#   sudo bash scripts/ops-latency-audit.sh --local --probes
#
# OPTIONS
# -------
#   --workdir DIR         Local output directory
#                         Default: ./kafka-audit-YYYYMMDD-HHMMSS
#   --bootstrap HOST:PORT Kafka bootstrap server for producer-perf-test
#                         Required for --perf probe; read from KAFKA_BOOTSTRAP_SERVERS
#                         in .env if not passed explicitly
#   --probes              Run fio disk probe on all nodes (parallel) and
#                         producer-perf-test on --perf-node (serial, one node only)
#   --perf-node NAME      Node name to run producer-perf-test on (default: broker1)
#                         Must match a node name in NODES list: broker1..monitor
#   --cleanup             After report collection, delete /tmp/kafka-latency-audit-*
#                         from every node
#   --local               On-node execution mode. Runs the full audit locally and
#                         writes the report to /tmp/kafka-latency-audit-<host>-<ts>.txt.
#                         Do not call this directly from the jumpbox — it is invoked
#                         automatically by the dispatch loop.
#
# PREREQUISITES
# -------------
#   Jumpbox: aws CLI, jq, bash 4+
#   Nodes  : sudo without password (ec2-user), docker, python3
#            fio only needed if --probes is used (auto-skipped if not installed)
#
# DISPATCH MODES (.env: DISPATCH_MODE=ssm|ssh)
# ---------------------------------------------
#   ssm (default) — uses aws ssm send-command; nodes need IAM AmazonSSMManagedInstanceCore
#                   .env keys: BROKER_*_INSTANCE_ID, CONNECT_1_INSTANCE_ID, MONITOR_1_INSTANCE_ID
#   ssh           — uses direct SSH; .env keys: SSH_KEY_PATH, BROKER_*_IP, CONNECT_1_IP, MONITOR_1_IP
#
# RED FLAG THRESHOLDS
# -------------------
#   vm.swappiness > 1          Swap causes unpredictable broker pause spikes
#   THP = [always]             Huge page allocation stalls → GC pauses
#   noatime missing            Extra metadata writes on every log segment read
#   I/O scheduler not mq-deadline/none  CFQ/BFQ add latency on NVMe
#   ENA *_allowance_exceeded > 0        EC2 network burst limit being hit
#   fd limit < 100000          Kafka opens 1 FD per partition per segment
#   JVM heap > 6 GB            G1GC stop-the-world scales with heap size
#   GC not G1GC/ZGC            CMS/Parallel add multi-second pauses
#   num.io.threads < 8         Disk I/O queue backs up under replication load
#   num.network.threads < 8    Request processor pool too small for busy brokers
#   socket buffers at default  102400 bytes is ~10x too small for 1 Gbps CDC
#   unclean.leader.election=true        Data loss on partition leader failover
#   min.insync.replicas < 2    With RF=3, one broker outage loses ack'd writes
#   under-replicated partitions > 0     Active replication lag
#
# TIMING
# ------
#   Read-only audit (no --probes): ~3-4 min total (parallel across 5 nodes)
#   With --probes (fio):           ~5-6 min (fio runs 30s per node, parallel)
#   With --probes + --bootstrap:   ~7-8 min (+ 50k-record producer-perf-test)
#
# REFERENCE
# ---------
#   https://developer.confluent.io/learn/kafka-performance/
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
      # Print the header comment block (lines 2-115) as plain text
      sed -n '2,115p' "$0" | sed 's/^# \{0,2\}//' | grep -v '^!'
      exit 0 ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"

# =============================================================================
# ON-NODE MODE  (--local)
#
# This block runs when the jumpbox dispatch loop re-invokes this same script
# on a remote node with "sudo bash scripts/ops-latency-audit.sh --local".
# It collects all metrics locally, writes a timestamped report to /tmp/, and
# prints the report path as the last line of stdout so the jumpbox can find it.
# =============================================================================
if $LOCAL_MODE; then

  if [[ $EUID -ne 0 ]]; then
    error "On-node mode requires root. Run: sudo bash scripts/ops-latency-audit.sh --local"
    exit 1
  fi

  REPORT_FILE="/tmp/kafka-latency-audit-$(hostname -s)-$(date +%Y%m%d-%H%M%S).txt"

  # Load .env so we can read KAFKA_LOG_DIRS and peer IPs for the ping sweep.
  # set +u because .env may contain unset optional vars that would abort under -u.
  DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
  DEPLOY_DIR="/home/${DEPLOY_USER}/cdc-on-ec2-docker"
  if [[ -f "$DEPLOY_DIR/.env" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "$DEPLOY_DIR/.env"
    set -u
  fi

  # KAFKA_LOG_DIRS is the Docker env var name Confluent uses; fall back to the
  # standard NVMe mount point we set in 3-setup-ec2.sh.
  KAFKA_LOG_DIR="${KAFKA_LOG_DIRS:-/data/kafka/logs}"

  # Tee to both stdout (captured by SSM) and the report file.
  {
    echo "=== AUDIT METADATA ==="
    echo "Hostname   : $(hostname -f)"
    echo "Date       : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "Kernel     : $(uname -r)"
    echo "Script     : ops-latency-audit.sh --local"
    echo ""

    # ── Section 1: System Overview ───────────────────────────────────────────
    # IMDSv2 requires a PUT to get a session token before any metadata call.
    # Older scripts that call the metadata service directly (no token) get 401
    # on IMDSv2-enforced instances.
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
    # NUMA node count matters: if Kafka JVM allocates memory across NUMA nodes,
    # cross-node memory access adds ~30-40 ns per access vs same-node ~5 ns.
    # i3.4xlarge has 1 NUMA node (all cores share the same memory bus), so
    # cross-NUMA is not an issue, but larger instances (r5.24xlarge) have 2+.
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
    # vm.swappiness=1 (not 0): setting to 0 disables swap entirely and makes
    # the OOM killer more aggressive — 1 retains swap as last resort but
    # avoids proactive swapping that creates latency spikes.
    #
    # dirty ratios: vm.dirty_ratio=80 / vm.dirty_background_ratio=5 is the
    # Confluent-recommended baseline. Lower dirty_ratio means more frequent
    # small flushes (adds I/O pressure); higher means riskier data loss on crash.
    #
    # THP: transparent_hugepage/enabled=[always] causes the kernel to
    # periodically compact memory to create 2 MB pages. That compaction stall
    # can pause a JVM thread for 10-100 ms. [never] eliminates this entirely.
    # [madvise] is acceptable — only allocates huge pages when explicitly requested.
    echo "=== KERNEL PARAMETERS ==="
    echo "--- Swappiness ---"
    echo "vm.swappiness = $(sysctl -n vm.swappiness)"
    echo ""
    echo "--- Dirty ratio ---"
    sysctl vm.dirty_ratio vm.dirty_background_ratio vm.dirty_expire_centisecs vm.dirty_writeback_centisecs
    echo ""
    echo "--- TCP/socket buffers ---"
    # net.core.rmem_max / wmem_max are the OS hard limits — broker socket.*.buffer.bytes
    # cannot exceed these. If broker config is raised but OS max isn't, the broker
    # silently uses the OS limit instead.
    sysctl net.core.rmem_default net.core.rmem_max net.core.wmem_default net.core.wmem_max \
          net.core.somaxconn net.core.netdev_max_backlog \
          net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
          net.ipv4.tcp_max_syn_backlog 2>/dev/null || true
    echo ""
    echo "--- Transparent Huge Pages ---"
    thp_enabled=$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "N/A")
    thp_defrag=$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || echo "N/A")
    echo "enabled: $thp_enabled"
    # defrag=always triggers synchronous memory compaction on allocation — even
    # worse than enabled=always because it can block any memory allocation call.
    echo "defrag : $thp_defrag"
    echo ""
    echo "--- Open file descriptor limits (ec2-user) ---"
    su - ec2-user -s /bin/bash -c 'ulimit -n' 2>/dev/null || ulimit -n
    echo "(system hard limit)"
    cat /proc/sys/fs/file-max
    echo ""

    # ── Section 4: Disk and Filesystem ───────────────────────────────────────
    # noatime: by default Linux updates the access time (atime) metadata on
    # every file read. For Kafka log segments that are read for replication,
    # this means every fetch triggers a metadata write. noatime eliminates it.
    #
    # xfs is preferred over ext4 for Kafka: xfs handles concurrent writers to
    # the same directory better (separate per-inode locks), which matters when
    # multiple log segments are being written simultaneously.
    #
    # I/O scheduler: mq-deadline or none are correct for NVMe (nvme0n1, etc.)
    # because NVMe drives have their own internal queues and reordering logic.
    # cfq/bfq add a software scheduling layer that degrades NVMe throughput.
    # For EBS (xvda, nvme* attached as EBS), none is also fine.
    echo "=== DISK AND FILESYSTEM ==="
    echo "--- Mount options (all mounts, excluding virtual fs) ---"
    findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS | \
      grep -v 'tmpfs\|cgroup\|proc\|sys\|dev\|run\|overlay' || findmnt
    echo ""
    echo "--- Kafka log dir mount ($KAFKA_LOG_DIR) ---"
    KAFKA_MOUNT=$(df -P "${KAFKA_LOG_DIR}" 2>/dev/null | tail -1 | awk '{print $6}') || KAFKA_MOUNT=""
    if [[ -n "$KAFKA_MOUNT" ]]; then
      findmnt -T "${KAFKA_LOG_DIR}" -o TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || \
        mount | grep "$KAFKA_MOUNT"
    else
      echo "Kafka log dir not found: ${KAFKA_LOG_DIR}"
    fi
    echo ""
    echo "--- I/O scheduler (physical block devices only) ---"
    for dev in /sys/block/*/queue/scheduler; do
      blk=$(echo "$dev" | awk -F/ '{print $4}')
      # Skip loop devices (Docker layers), ram disks, and device-mapper (LVM/RAID).
      # We only care about the physical disk that backs the Kafka log volume.
      [[ "$blk" =~ ^(loop|ram|dm) ]] && continue
      echo "$blk: $(cat "$dev" 2>/dev/null)"
    done
    echo ""
    echo "--- Disk usage ---"
    df -h "${KAFKA_LOG_DIR}" 2>/dev/null || df -h /
    echo ""

    # ── Section 5: Network Configuration ─────────────────────────────────────
    # ENA allowance_exceeded counters are the primary signal that a broker is
    # hitting EC2 network bandwidth limits. Unlike CPU or memory, EC2 network
    # throttling is silent — there's no error, just silently dropped packets
    # that cause retransmits and latency spikes. Non-zero counters are a hard
    # indicator that the instance type is undersized for the replication load.
    echo "=== NETWORK CONFIGURATION ==="
    echo "--- Network interfaces ---"
    ip -brief addr show | grep -v '^lo'
    echo ""
    echo "--- ENA driver version ---"
    ethtool -i eth0 2>/dev/null | grep -E 'driver|version' || echo "(ethtool unavailable)"
    echo ""
    echo "--- ENA allowance exceeded counters ---"
    # bw_in_allowance_exceeded, bw_out_allowance_exceeded, pps_allowance_exceeded,
    # conntrack_allowance_exceeded, linklocal_allowance_exceeded
    ethtool -S eth0 2>/dev/null | grep -i 'allowance_exceeded' || echo "0 (no allowance counters found)"
    echo ""
    echo "--- Ring buffer sizes ---"
    # Small ring buffers cause packet drops under burst replication traffic.
    # Default is often 1024; Confluent recommends 4096 for broker nodes.
    ethtool -g eth0 2>/dev/null || echo "(ring buffer info unavailable)"
    echo ""
    echo "--- Peer RTT (inter-node ping sweep) ---"
    # Ping all other node IPs from .env, skipping our own. This catches routing
    # misconfiguration (cross-AZ placement where you expected same-AZ) and
    # detects network congestion between specific node pairs.
    # Expected: <1 ms same-AZ, <5 ms cross-AZ within same region.
    for var in BROKER_1_IP BROKER_2_IP BROKER_3_IP CONNECT_1_IP MONITOR_1_IP; do
      ip_val="${!var:-}"
      [[ -z "$ip_val" ]] && continue
      # Skip our own IP — the node would have zero RTT which skews the report.
      if ip addr show | grep -q "$ip_val"; then continue; fi
      rtt=$(ping -c 3 -q "$ip_val" 2>/dev/null | \
        grep 'rtt\|round-trip' | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "unreachable")
      echo "$var ($ip_val): min rtt = ${rtt} ms"
    done
    echo ""

    # ── Section 6: Open File Descriptors ─────────────────────────────────────
    # Kafka opens one file descriptor per log segment per partition. A cluster
    # with 500 topics × 3 partitions × 3 segments = 4500 FDs minimum, and that
    # grows with log.retention settings and topic count. 100000 is a safe floor.
    echo "=== OPEN FILE DESCRIPTORS ==="
    echo "--- Kafka/Connect process FD count vs limit ---"
    pid=$(pgrep -f 'kafka.Kafka\|ConnectDistributed' 2>/dev/null | head -1 || true)
    if [[ -n "${pid:-}" ]]; then
      fd_count=$(ls /proc/"$pid"/fd 2>/dev/null | wc -l || echo "?")
      # /proc/<pid>/limits column 4 is the hard limit for open files
      fd_limit=$(awk '/open files/{print $4}' /proc/"$pid"/limits 2>/dev/null || echo "?")
      echo "Kafka/Connect PID $pid: open FDs = $fd_count / limit = $fd_limit"
    else
      echo "(No Kafka or Connect process found — is Docker running?)"
    fi
    echo ""
    echo "--- System-wide FD usage (allocated / max allocated / system max) ---"
    # /proc/sys/fs/file-nr: [in-use] [unused-but-allocated] [system-max]
    cat /proc/sys/fs/file-nr
    echo ""

    # ── Section 7: JVM Configuration ─────────────────────────────────────────
    # Heap sizing for Kafka brokers: the JVM heap holds the metadata cache and
    # request buffers, NOT the data itself (data goes through the page cache).
    # 4-6 GB is the Confluent-recommended range. Larger heaps mean more objects
    # for G1GC to scan in its mixed-collection phase, which lengthens pauses.
    #
    # We read JVM flags from /proc/<pid>/cmdline first (most accurate), then
    # fall back to docker inspect (when the process isn't visible from inside
    # the container's /proc namespace, e.g. during startup or if pid namespace
    # differs).
    echo "=== JVM CONFIGURATION ==="
    echo "--- JVM flags from running process ---"
    jvm_found=""
    for pid in $(pgrep -f 'kafka.Kafka\|ConnectDistributed' 2>/dev/null || true); do
      cmdline=$(tr '\0' ' ' </proc/"$pid"/cmdline 2>/dev/null || echo "")
      if [[ -n "$cmdline" ]]; then
        echo "PID $pid: $(echo "$cmdline" | grep -oE '\-X[^ ]+|\-XX:[^ ]+' | tr '\n' ' ')"
        jvm_found="yes"
      fi
    done
    if [[ -z "$jvm_found" ]]; then
      # Fall back: read KAFKA_HEAP_OPTS from the container environment.
      # This works even when the process cmdline isn't accessible.
      echo "(process not found — reading from Docker container env)"
      docker inspect broker 2>/dev/null | \
        python3 -c "
import sys, json
d = json.load(sys.stdin)
for c in d:
    for e in c.get('Config', {}).get('Env', []):
        if any(k in e for k in ['HEAP', 'JVM', 'KAFKA_HEAP']):
            print(e)
" 2>/dev/null || echo "(Docker inspect failed — broker may not be running)"
    fi
    echo ""
    echo "--- Java version ---"
    # Try host java first; fall back to java inside the broker container.
    java -version 2>&1 || docker exec broker java -version 2>&1 || echo "(java not in PATH)"
    echo ""

    # ── Section 8: Kafka Broker Configuration ────────────────────────────────
    # We read broker config from Docker container env vars (KAFKA_NUM_IO_THREADS etc.)
    # rather than server.properties because in KRaft + Docker Compose mode, Confluent
    # translates KAFKA_* env vars to server.properties at container startup. The env
    # vars are the authoritative source; server.properties may not exist as a static file.
    echo "=== KAFKA BROKER CONFIGURATION ==="
    echo "--- Tuning vars from broker container env ---"
    docker inspect broker 2>/dev/null | \
      python3 -c "
import sys, json
d = json.load(sys.stdin)
# Keys that directly map to latency-relevant broker settings
keys = [
    'NUM_IO_THREADS',        # disk I/O thread pool — should match vCPU count
    'NUM_NETWORK_THREADS',   # request processor threads — should be >=8
    'NUM_REPLICA_FETCHERS',  # replication parallelism per broker
    'SOCKET_SEND_BUFFER',    # OS socket send buffer (bytes)
    'SOCKET_RECEIVE_BUFFER', # OS socket receive buffer (bytes)
    'MIN_INSYNC_REPLICAS',   # durability floor (should be 2 with RF=3)
    'UNCLEAN_LEADER',        # if true, allows data loss on leader election
    'LOG_RETENTION',         # retention period
    'HEAP_OPTS',             # JVM heap sizing
    'LOG_DIRS',              # Kafka log directory (should be on NVMe mount)
]
for c in d:
    for e in c.get('Config', {}).get('Env', []):
        if any(k in e for k in keys):
            print(e)
" 2>/dev/null || echo "(Docker inspect failed — broker may not be running)"
    echo ""

    # ── Section 9: Replication and Partition Health ───────────────────────────
    # Under-replicated partitions (URP) means at least one replica is not caught
    # up with the leader. Even 1 URP is a warning sign: it means a consumer
    # reading from that partition might get stale data, and if the leader fails
    # while the replica is lagging, you risk data loss (unless unclean election
    # is disabled).
    echo "=== REPLICATION AND PARTITION HEALTH ==="
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
    # TCP connect time to localhost ports gives a baseline for "how fast can
    # a producer get a connection accepted?" — this is mostly a sanity check
    # that the broker is listening and not CPU-saturated (which would cause
    # delayed SYN-ACKs even on loopback).
    echo "=== NETWORK LATENCY ==="
    echo "--- DNS resolution time (local hostname) ---"
    t0=$(date +%s%3N)
    host "$(hostname -f)" &>/dev/null || true
    echo "Hostname DNS lookup: $(( $(date +%s%3N) - t0 )) ms"
    echo ""
    echo "--- TCP connect time to local service ports ---"
    for port in 9092 8083 8081; do
      t_start=$(date +%s%3N)
      # /dev/tcp is a bash built-in; no nc or curl needed. timeout 2 prevents
      # hanging on a port that is firewalled (would block) vs not bound (resets fast).
      timeout 2 bash -c "echo >/dev/tcp/localhost/$port" 2>/dev/null && \
        echo "localhost:$port reachable ($(( $(date +%s%3N) - t_start )) ms connect)" || \
        echo "localhost:$port NOT reachable"
    done
    echo ""

    # ── fio disk probe (only when --probes is passed through) ────────────────
    # fio settings explained:
    #   ioengine=libaio  — async I/O matching how Kafka flushes log segments
    #   rw=randwrite     — worst case for NVMe (sequential writes would be faster);
    #                      Kafka appends sequentially, but we test random to expose
    #                      scheduler and alignment issues
    #   bs=4k            — Kafka default log.index.interval.bytes alignment
    #   iodepth=1        — single outstanding I/O; Kafka's log writer is
    #                      single-threaded per partition, so depth=1 is realistic
    #   runtime=30       — long enough for warm-up and stable latency measurement
    #   size=512m        — fits in NVMe buffer but large enough to avoid caching
    if $RUN_PROBES; then
      echo "=== FIO DISK PROBE ==="
      if ! command -v fio &>/dev/null; then
        echo "(fio not installed — install with: sudo dnf install -y fio)"
      else
        FIO_DIR="${KAFKA_LOG_DIR}/fio-test-$$"
        mkdir -p "$FIO_DIR"
        fio --name=kafka-latency \
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

  # Print the report path as the final line of stdout.
  # The jumpbox dispatch loop greps for this pattern to locate the file.
  echo ""
  echo "=== REPORT WRITTEN ==="
  echo "$REPORT_FILE"
  exit 0
fi

# =============================================================================
# JUMPBOX MODE  (default — no --local flag)
#
# Reads .env, builds the node list, dispatches --local to all nodes in
# parallel, collects reports, diffs config sections, and writes FINDINGS.md.
# =============================================================================

if [[ ! -f "$ENV_FILE" ]]; then
  error ".env not found at $ENV_FILE — run from the repo root or set ENV_FILE"
  exit 1
fi

# set +u: .env may contain vars that are intentionally unset on some deployments
set +u
# shellcheck disable=SC1090
source "$ENV_FILE"
set -u

DISPATCH_MODE="${DISPATCH_MODE:-ssm}"
DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
DEPLOY_DIR="/home/${DEPLOY_USER}/cdc-on-ec2-docker"
AWS_REGION="${AWS_REGION:-us-east-1}"
# Allow --bootstrap to override .env value
BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-${KAFKA_BOOTSTRAP_SERVERS:-}}"
WORKDIR="${WORKDIR:-./kafka-audit-$(date +%Y%m%d-%H%M%S)}"

# ─── Build node list ──────────────────────────────────────────────────────────
# Node format: "name:address" where address is an IP (ssh) or instance-id (ssm).
# We use a single array of colon-separated pairs to avoid parallel index bugs
# with two separate arrays.
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

for entry in "${NODES[@]}"; do
  name="${entry%%:*}"; addr="${entry##*:}"
  if [[ -z "$addr" ]]; then
    error "Address not set for node '$name' — check .env (BROKER_*_INSTANCE_ID or BROKER_*_IP)"
    exit 1
  fi
done

# ─── run_on_node: dispatch a command to a remote node, capture output ─────────
#
# SSM mode: aws ssm send-command is async — it returns a CommandId immediately
# and we poll get-command-invocation until status is terminal. We use jq to
# build the SSM parameters JSON because the command string often contains
# commas and slashes (NO_PROXY values, file paths) that break heredoc JSON.
#
# SSH mode: direct blocking call, stdout+stderr redirect to logfile.
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

  # SSM: build parameters JSON with jq to safely escape the command string
  local cmd_id
  cmd_id=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$node_addr" \
    --document-name "AWS-RunShellScript" \
    --parameters "$(jq -n --arg c "$cmd" '{"commands":[$c],"executionTimeout":["300"]}')" \
    --timeout-seconds "$timeout_s" \
    --output text \
    --query 'Command.CommandId' 2>"$logfile") || {
      echo "SSM send-command failed" >>"$logfile"; return 1
    }

  if [[ -z "$cmd_id" || "$cmd_id" == "None" ]]; then
    echo "SSM: empty command ID" >>"$logfile"; return 1
  fi

  # Poll every 5s. SSM typically delivers within 3-5s on a healthy instance.
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
        # Append both stdout and stderr — audit output goes to stdout but
        # some tools (java -version, ethtool errors) write to stderr.
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

# ─── Setup ────────────────────────────────────────────────────────────────────
mkdir -p "$WORKDIR/raw" "$WORKDIR/diffs"

echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║       Kafka Latency Audit — 5-Node CDC Cluster               ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Dispatch mode : ${BOLD}${DISPATCH_MODE^^}${NC}"
echo -e "  Output dir    : ${BOLD}$WORKDIR${NC}"
[[ -n "$BOOTSTRAP_SERVER" ]] && echo -e "  Bootstrap     : ${BOLD}$BOOTSTRAP_SERVER${NC}"
$RUN_PROBES && echo -e "  Probes        : ${BOLD}fio + producer-perf${NC}" || \
  echo -e "  Probes        : ${GREY}disabled (use --probes to enable)${NC}"
echo ""

# =============================================================================
# Phase 1: Pre-flight
#
# Verify each node is reachable and ec2-user has passwordless sudo.
# Nodes that fail here are skipped for the rest of the run — we still
# produce a report for the nodes that succeeded.
# =============================================================================
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
  warn "$FAILED_PREFLIGHT node(s) unreachable — continuing with $REACHABLE_COUNT reachable node(s)."

# =============================================================================
# Phase 2: Dispatch audit to all reachable nodes (parallel)
#
# Each node runs: cd ~/cdc-on-ec2-docker && sudo bash scripts/ops-latency-audit.sh --local
#
# The script re-invokes itself on the node using the copy already deployed
# there in Phase 2a of the CDC deployment. This means the audit logic is
# always in sync with the version of the script on that node — no separate
# audit tool to distribute or version-manage.
#
# After the audit finishes, we retrieve the report file. SSM captures stdout
# in StandardOutputContent (up to 24 KB per invocation). For larger reports
# we base64-encode the file and decode it locally to avoid the size limit.
# =============================================================================
echo -e "${BOLD}${BLUE}▶ Phase 2: Running audit on all nodes (parallel, read-only)${NC}"

PROBE_FLAG=""; $RUN_PROBES && PROBE_FLAG="--probes"

declare -a AUDIT_PIDS=() REPORT_FILES=()

for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
  node_name="${REACHABLE_NAMES[$i]}"
  node_addr="${REACHABLE_ADDRS[$i]}"
  audit_log="$WORKDIR/raw/${node_name}.log"
  report_file="$WORKDIR/raw/${node_name}-audit.txt"
  REPORT_FILES+=("$report_file")

  (
    BOOTSTRAP_ARG=""
    [[ -n "$BOOTSTRAP_SERVER" ]] && BOOTSTRAP_ARG="--bootstrap $BOOTSTRAP_SERVER"
    cmd="cd ${DEPLOY_DIR} && sudo bash scripts/ops-latency-audit.sh --local ${PROBE_FLAG} ${BOOTSTRAP_ARG} 2>&1"

    if run_on_node "$node_name" "$node_addr" "$cmd" "$audit_log" 180; then
      # The on-node script prints the report path as the last non-empty line.
      # We use that to fetch the file via base64 rather than relying on SSM
      # output size limits. If the path isn't found (e.g. SSM truncated it),
      # we fall back to using the captured stdout as the report.
      remote_report=$(grep '/tmp/kafka-latency-audit-' "$audit_log" | \
        grep -v '===' | tail -1 | tr -d '[:space:]')

      if [[ -n "$remote_report" ]]; then
        fetch_log="$audit_log.fetch"
        if run_on_node "$node_name" "$node_addr" \
            "base64 -w0 '${remote_report}'" "$fetch_log" 30; then
          # The fetch_log may contain SSM metadata lines before the base64 blob.
          # We extract only the last line that matches the base64 character set.
          grep -E '^[A-Za-z0-9+/=]+$' "$fetch_log" | tail -1 | \
            base64 -d >"$report_file" 2>/dev/null || cp "$audit_log" "$report_file"
        else
          cp "$audit_log" "$report_file"
        fi
      else
        cp "$audit_log" "$report_file"
      fi
    else
      echo "AUDIT_ERROR: audit failed on $node_name" >>"$audit_log"
      cp "$audit_log" "$report_file"
    fi
  ) &
  AUDIT_PIDS+=($!)
done

AUDIT_FAILED=0
for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
  node_name="${REACHABLE_NAMES[$i]}"
  if wait "${AUDIT_PIDS[$i]}"; then
    info "$node_name: collected → ${REPORT_FILES[$i]}"
  else
    warn "$node_name: audit had errors (see $WORKDIR/raw/${node_name}.log)"
    AUDIT_FAILED=$((AUDIT_FAILED + 1))
  fi
done
echo ""

# =============================================================================
# Phase 3: Cross-node diff
#
# Each report is divided into named sections by "=== SECTION NAME ===" headers.
# We extract each section from every node's report and diff it against broker1
# (the reference node). Only sections with actual differences get a non-empty
# diff file. This makes it easy to spot the one node that has a different
# swappiness or I/O scheduler without reading five full reports.
# =============================================================================
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

# Extract lines between two consecutive "=== ... ===" headers for a named section.
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
    echo "# Reference: ${REACHABLE_NAMES[0]} (all other nodes diffed against this)"
    echo ""
    for i in $(seq 1 $((REACHABLE_COUNT - 1))); do
      n="${REACHABLE_NAMES[$i]}"
      if ! diff -q "$ref" "${sfiles[$i]}" &>/dev/null; then
        has_diff=true
        echo "## ${REACHABLE_NAMES[0]} vs $n"
        diff -u --label "${REACHABLE_NAMES[0]}" --label "$n" \
          "$ref" "${sfiles[$i]}" || true
        echo ""
      fi
    done
  } >"$diff_file"

  if $has_diff; then
    warn "Drift: $section → $diff_file"
    DRIFT_SECTIONS+=("$section")
    DRIFT_COUNT=$((DRIFT_COUNT + 1))
  else
    info "No drift: $section"
  fi
done
echo ""

# =============================================================================
# Phase 4: Collect per-node metrics and detect red flags
#
# We grep known patterns from each report to extract scalar values into
# associative arrays keyed by node name. These feed both the FINDINGS.md
# drift table and the red-flag checks.
#
# grep -ic returns a count (0 = pattern not found). For NOATIME we invert:
# if count is 0 (noatime string not in the mount options output) → "missing".
# =============================================================================
echo -e "${BOLD}${BLUE}▶ Phase 4: Generating FINDINGS.md${NC}"

declare -a RED_FLAGS=()

declare -A SWAPPINESS=() THP=() NOATIME=() IOSCHEDULER=() ENA_EX=()
declare -A FD_LIMIT=() JVM_HEAP=() GC_ALGO=()
declare -A NUM_IO=() NUM_NET=() SOCK_BUF=() UNCLEAN=() MIR=() UNDER_REP=()

for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
  n="${REACHABLE_NAMES[$i]}"; r="${REPORT_FILES[$i]}"

  SWAPPINESS["$n"]=$(grep -iE 'vm\.swappiness\s*=' "$r" 2>/dev/null | \
    grep -oE '[0-9]+' | head -1 || echo "?")

  THP["$n"]=$(grep -iE 'transparent|thp|^enabled:' "$r" 2>/dev/null | \
    grep -oE '\[always\]|\[madvise\]|\[never\]' | head -1 || echo "?")

  # grep -ic: case-insensitive count of lines containing 'noatime'.
  # A count of 0 means noatime is absent from the mount options section.
  noatime_count=$(grep -ic 'noatime' "$r" 2>/dev/null || echo "0")
  [[ "$noatime_count" == "0" ]] && NOATIME["$n"]="missing" || NOATIME["$n"]="present"

  # Extract the active scheduler (shown in brackets by the kernel, e.g. [mq-deadline])
  IOSCHEDULER["$n"]=$(grep -oE '\[(mq-deadline|none|deadline|cfq|bfq|kyber)\]' \
    "$r" 2>/dev/null | head -1 || echo "?")

  # Non-zero allowance counters indicate throttling. We skip lines ending in " 0"
  # (zero counter) and capture the first remaining line.
  ENA_EX["$n"]=$(grep -iE 'allowance_exceeded' "$r" 2>/dev/null | \
    grep -v ' 0$' | head -1 || echo "0")

  # FD limit: extract the largest 5-digit-or-more number from lines mentioning limits.
  # The largest value is the hard limit (soft limit would be smaller or equal).
  FD_LIMIT["$n"]=$(grep -iE 'limit|nofile|open files' "$r" 2>/dev/null | \
    grep -oE '[0-9]{5,}' | sort -n | tail -1 || echo "?")

  JVM_HEAP["$n"]=$(grep -iEo '\-Xmx[0-9]+[gGmM]|HEAP_OPTS.*[0-9]+[gGmM]' \
    "$r" 2>/dev/null | grep -oE '[0-9]+[gGmM]' | head -1 || echo "?")

  GC_ALGO["$n"]=$(grep -oE 'UseG1GC|UseZGC|UseShenandoahGC|UseCMS|UseParallelGC' \
    "$r" 2>/dev/null | head -1 || echo "?")

  NUM_IO["$n"]=$(grep -iE 'NUM_IO_THREADS|num\.io\.threads' "$r" 2>/dev/null | \
    grep -oE '[0-9]+' | head -1 || echo "?")

  NUM_NET["$n"]=$(grep -iE 'NUM_NETWORK_THREADS|num\.network\.threads' "$r" 2>/dev/null | \
    grep -oE '[0-9]+' | head -1 || echo "?")

  SOCK_BUF["$n"]=$(grep -iE 'SOCKET_SEND_BUFFER|socket\.send\.buffer' "$r" 2>/dev/null | \
    grep -oE '[0-9]+' | head -1 || echo "?")

  UNCLEAN["$n"]=$(grep -iE 'UNCLEAN_LEADER|unclean\.leader\.election' "$r" 2>/dev/null | \
    grep -oiE 'true|false' | head -1 || echo "?")

  MIR["$n"]=$(grep -iE 'MIN_INSYNC|min\.insync\.replicas' "$r" 2>/dev/null | \
    grep -oE '[0-9]+' | head -1 || echo "?")

  UNDER_REP["$n"]=$(grep -iE 'under.replicated.partition' "$r" 2>/dev/null | \
    grep -oE '[0-9]+' | head -1 || echo "0")

  # ── Red flag checks for this node ──────────────────────────────────────────

  sw="${SWAPPINESS[$n]}"
  [[ "$sw" =~ ^[0-9]+$ && $sw -gt 1 ]] && \
    RED_FLAGS+=("**$n**: vm.swappiness=$sw (should be ≤1)")

  [[ "${THP[$n]}" == "[always]" ]] && \
    RED_FLAGS+=("**$n**: THP = [always] (should be [never] — causes GC pause spikes)")

  [[ "${NOATIME[$n]}" == "missing" ]] && \
    RED_FLAGS+=("**$n**: noatime not found on Kafka log dir mount")

  fd="${FD_LIMIT[$n]}"
  [[ "$fd" =~ ^[0-9]+$ && $fd -lt 100000 ]] && \
    RED_FLAGS+=("**$n**: fd limit=$fd (should be ≥100000)")

  heap="${JVM_HEAP[$n]}"; heap_gb=0
  [[ "$heap" =~ ^([0-9]+)[gG]$ ]] && heap_gb="${BASH_REMATCH[1]}"
  [[ "$heap" =~ ^([0-9]+)[mM]$ ]] && heap_gb=$(( BASH_REMATCH[1] / 1024 ))
  [[ $heap_gb -gt 6 ]] && \
    RED_FLAGS+=("**$n**: JVM heap=${heap} (>6 GB → longer GC pauses; target 4–6 GB)")

  gc="${GC_ALGO[$n]}"
  [[ -n "$gc" && "$gc" != "?" && "$gc" != "UseG1GC" && "$gc" != "UseZGC" ]] && \
    RED_FLAGS+=("**$n**: GC=${gc} (prefer G1GC or ZGC for low-latency Kafka)")

  io="${NUM_IO[$n]}"
  [[ "$io" =~ ^[0-9]+$ && $io -lt 8 ]] && \
    RED_FLAGS+=("**$n**: num.io.threads=$io (should match vCPU count, typically ≥8)")

  nt="${NUM_NET[$n]}"
  [[ "$nt" =~ ^[0-9]+$ && $nt -lt 8 ]] && \
    RED_FLAGS+=("**$n**: num.network.threads=$nt (should be ≥8)")

  sb="${SOCK_BUF[$n]}"
  [[ "$sb" =~ ^[0-9]+$ && $sb -le 102400 ]] && \
    RED_FLAGS+=("**$n**: socket.send.buffer.bytes=$sb (default 102400 — increase to 4 MB)")

  [[ "${UNCLEAN[$n]}" == "true" ]] && \
    RED_FLAGS+=("**$n**: unclean.leader.election.enable=true (data loss risk on failover)")

  mir="${MIR[$n]}"
  [[ "$mir" =~ ^[0-9]+$ && $mir -lt 2 ]] && \
    RED_FLAGS+=("**$n**: min.insync.replicas=$mir (should be 2 with RF=3)")

  ur="${UNDER_REP[$n]}"
  [[ "$ur" =~ ^[0-9]+$ && $ur -gt 0 ]] && \
    RED_FLAGS+=("**$n**: $ur under-replicated partition(s) — active replication lag")

  ena="${ENA_EX[$n]}"
  [[ "$ena" != "0" && -n "$ena" ]] && \
    RED_FLAGS+=("**$n**: ENA allowance_exceeded counters non-zero → network throttling")
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
  [[ $RED_FLAG_COUNT -gt 5 ]] && \
    echo "_...and $((RED_FLAG_COUNT - 5)) more — see Section 3._"
fi

cat <<'DRIFT_HDR'

---

## 2. Drift Across Nodes

Only settings that **differ** between nodes are shown. Uniform settings are omitted.

| Setting | broker1 | broker2 | broker3 | connect | monitor |
|---------|---------|---------|---------|---------|---------|
DRIFT_HDR

# emit_row: print a table row only if values differ across reachable nodes.
# Uses bash namerefs (declare -n) to accept the associative array by name —
# this avoids eval and works with any map variable name.
emit_row() {
  local label="$1"
  declare -n map="$2"
  local all_same=true
  local first="${map[${REACHABLE_NAMES[0]}]:-?}"
  for n in "${REACHABLE_NAMES[@]}"; do
    [[ "${map[$n]:-?}" != "$first" ]] && all_same=false
  done
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

_Ordered by expected latency impact (highest first). Each fix is listed once
even if multiple nodes are affected._

STEPS_HDR

# emit_fix: deduplicate fixes so the same recommendation isn't printed once
# per node. We track which fix keys have been emitted in a pipe-delimited
# string — set membership in bash without requiring an associative array.
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
      emit_fix THP "**Disable Transparent Huge Pages:** \`echo never > /sys/kernel/mm/transparent_hugepage/enabled\` and persist via \`/etc/rc.local\` or a systemd unit. THP compaction can pause any thread for 10–100 ms." ;;
    *swappiness*)
      emit_fix SWAP "**Set vm.swappiness=1:** \`sysctl -w vm.swappiness=1\` + persist in \`/etc/sysctl.d/99-kafka.conf\`. Value 1 retains swap as OOM last resort without proactive swapping." ;;
    *noatime*)
      emit_fix NOATIME "**Add noatime to Kafka log dir mount:** Edit \`/etc/fstab\`, append \`noatime\` to mount options for \`/data/kafka\`. Removes one metadata write per log segment read." ;;
    *"socket.send.buffer"*|*"102400"*)
      emit_fix SOCKBUF "**Increase socket buffers:** Set \`socket.send.buffer.bytes=4194304\` and \`socket.receive.buffer.bytes=4194304\` in \`KAFKA_SOCKET_SEND_BUFFER_BYTES\` / \`KAFKA_SOCKET_RECEIVE_BUFFER_BYTES\` in .env. Also raise OS limits: \`net.core.rmem_max=4194304\` and \`net.core.wmem_max=4194304\`." ;;
    *num.io.threads*)
      emit_fix IOTHREADS "**Increase num.io.threads:** Set \`KAFKA_NUM_IO_THREADS\` to vCPU count (i3.4xlarge = 16). I/O threads handle log appends and replication fetches — too few causes queue build-up." ;;
    *num.network.threads*)
      emit_fix NETTHREADS "**Increase num.network.threads:** Set \`KAFKA_NUM_NETWORK_THREADS=8\` (minimum). Controls request processor pool for producer/consumer connections." ;;
    *">6 GB"*|*"longer GC"*)
      emit_fix HEAP "**Reduce JVM heap to 4–6 GB:** Set \`KAFKA_HEAP_OPTS='-Xmx6g -Xms6g'\`. Kafka stores data in the OS page cache (not heap), so large heaps only increase G1GC scan time." ;;
    *"GC="*)
      emit_fix GC "**Switch GC algorithm:** Add \`-XX:+UseG1GC\` (Java 8–16) or \`-XX:+UseZGC\` (Java 17+) to \`KAFKA_HEAP_OPTS\`. Eliminates stop-the-world pauses from CMS or Parallel GC." ;;
    *unclean*)
      emit_fix UNCLEAN "**Disable unclean leader election:** Set \`KAFKA_UNCLEAN_LEADER_ELECTION_ENABLE=false\`. Prevents an out-of-sync replica from being promoted to leader and losing data." ;;
    *min.insync*)
      emit_fix MIR "**Set min.insync.replicas=2:** Set \`KAFKA_MIN_INSYNC_REPLICAS=2\`. With RF=3, this ensures a producer using \`acks=all\` gets confirmation from at least 2 brokers." ;;
    *under-replicated*)
      emit_fix URP "**Investigate under-replicated partitions:** Run \`docker exec broker kafka-topics --bootstrap-server localhost:9092 --describe --under-replicated-partitions\`. Common causes: GC pauses, NVMe saturation, or a broker still catching up after restart." ;;
    *allowance_exceeded*|*throttling*)
      emit_fix ENA "**Investigate ENA network throttling:** Non-zero \`*_allowance_exceeded\` counters mean the instance is hitting EC2 network burst limits. Check with \`ethtool -S eth0 | grep allowance\`. Consider a larger instance type or reducing replication factor on high-volume topics." ;;
    *"fd limit"*)
      emit_fix FD "**Raise open file descriptor limit:** Add to \`/etc/security/limits.d/99-kafka.conf\`: \`* hard nofile 131072\` and \`* soft nofile 131072\`. Restart the broker container to apply." ;;
  esac
done

[[ $step -eq 1 ]] && \
  echo "No immediate fixes required. Run active probes (Section 5) to establish a latency baseline."

cat <<PROBES_HDR

---

## 5. Active Probe Plan

These probes are write-heavy — schedule during a low-CDC-throughput window.
Re-run with \`--probes\` (and optionally \`--bootstrap\`) to execute automatically.

### fio — Disk write latency (all 5 nodes, parallel, ~30 s each)

Tests 4k random write latency at iodepth=1, which approximates Kafka's
single-threaded log append pattern. p99 > 5 ms indicates I/O scheduler or
NVMe configuration issues.

\`\`\`bash
bash scripts/ops-latency-audit.sh --probes
\`\`\`

**Red flag threshold:** p99 write latency > 5 ms on any node.
**Note:** fio creates a 512 MB file in \`${KAFKA_LOG_DIR:-/data/kafka/logs}/fio-test-<pid>/\`
and removes it on completion. Ensure at least 1 GB of headroom.

### producer-perf-test — End-to-end Kafka latency (broker1 only, not parallel)

Sends 50,000 × 1 KB records at 5,000 rec/s with \`acks=all\` and measures
round-trip latency from producer to broker acknowledgement. Running on only
one node avoids cross-node producer competition skewing the baseline.

\`\`\`bash
bash scripts/ops-latency-audit.sh --probes --bootstrap ${BOOTSTRAP_ARG}
\`\`\`

**Red flag threshold:** p99 end-to-end > 50 ms.
**Note:** Creates a temporary topic \`__latency-audit-test\`. Delete after the run:
\`docker exec broker kafka-topics --bootstrap-server localhost:9092 --delete --topic __latency-audit-test\`

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
  echo "- [\`raw/${n}-audit.txt\`](raw/${n}-audit.txt) — full audit output"
  echo "- [\`raw/${n}.log\`](raw/${n}.log) — dispatch log (SSM stdout/stderr)"
done

} >"$FINDINGS"

info "FINDINGS.md written: $FINDINGS"

# =============================================================================
# Phase 5: producer-perf-test (only when --probes + --bootstrap are set)
#
# Run on a single node (default: broker1) — running producer-perf in parallel
# across multiple nodes would compete for the same topic partitions and
# artificially inflate end-to-end latency due to broker-side contention.
#
# The fio probe is already handled: --probes was passed through to --local,
# so each node ran fio as part of its on-node audit in Phase 2.
# =============================================================================
if $RUN_PROBES && [[ -n "$BOOTSTRAP_SERVER" ]]; then
  echo ""
  echo -e "${BOLD}${BLUE}▶ Phase 5: producer-perf-test on $PERF_NODE (single node)${NC}"

  PERF_ADDR=""
  for entry in "${NODES[@]}"; do
    n="${entry%%:*}"; addr="${entry##*:}"
    [[ "$n" == "$PERF_NODE" ]] && PERF_ADDR="$addr"
  done

  if [[ -n "$PERF_ADDR" ]]; then
    perf_log="$WORKDIR/raw/${PERF_NODE}.perf.log"
    # acks=all: measures full ISR round-trip (most realistic for CDC workloads).
    # linger.ms=0: no artificial batching delay — measures raw latency.
    # batch.size=16384: default; keeps record batching behavior realistic.
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
        echo "Node: \`$PERF_NODE\` | Bootstrap: \`$BOOTSTRAP_SERVER\`"
        echo ""
        echo "\`\`\`"
        tail -30 "$perf_log"
        echo "\`\`\`"
      } >>"$FINDINGS"
    else
      warn "producer-perf-test failed — see $perf_log"
    fi
  else
    warn "Perf node '$PERF_NODE' not in reachable list — skipping producer-perf"
  fi
fi

# =============================================================================
# Phase 6: Cleanup remote temp files (only when --cleanup is set)
# =============================================================================
if $DO_CLEANUP; then
  echo ""
  echo -e "${BOLD}${BLUE}▶ Phase 6: Cleanup${NC}"
  for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
    n="${REACHABLE_NAMES[$i]}"; addr="${REACHABLE_ADDRS[$i]}"
    cl_log="$WORKDIR/raw/${n}.cleanup.log"
    run_on_node "$n" "$addr" \
      "rm -f /tmp/kafka-latency-audit-*.txt" \
      "$cl_log" 20 && info "$n: cleaned up" || warn "$n: cleanup failed (see $cl_log)"
  done
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║                      Audit Complete                          ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Findings:${NC} $(realpath "$FINDINGS")"
echo ""
echo "  TL;DR:"
if [[ $RED_FLAG_COUNT -eq 0 ]]; then
  echo -e "  • ${GREEN}No latency red flags${NC} — all checked settings within recommended ranges"
else
  echo -e "  • ${RED}$RED_FLAG_COUNT red flag(s)${NC} — see Section 3 in FINDINGS.md"
fi
if [[ $DRIFT_COUNT -gt 0 ]]; then
  echo -e "  • ${YELLOW}$DRIFT_COUNT section(s) with cross-node drift${NC} — diffs in $WORKDIR/diffs/"
else
  echo -e "  • ${GREEN}No configuration drift${NC} across audited nodes"
fi
if ! $RUN_PROBES; then
  echo -e "  • Probes not run — rerun with ${BOLD}--probes${NC} after reviewing FINDINGS.md"
fi
echo ""

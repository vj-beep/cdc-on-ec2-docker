#!/bin/bash

################################################################################
# ops-analyze-infrastructure.sh
#
# Analyzes CDC infrastructure using EC2 Instance IDs from .env
# - Reads BROKER_*_INSTANCE_ID, CONNECT_1_INSTANCE_ID, MONITOR_1_INSTANCE_ID from .env
# - Queries AWS EC2 for instance types and specs
# - Provides role-specific tuning recommendations
#
# Usage:
#   ./scripts/ops-analyze-infrastructure.sh
#   ./scripts/ops-analyze-infrastructure.sh --json
#
# Prerequisites:
#   - .env file with EC2 Instance IDs (already in EC2 Instance IDs section):
#     BROKER_1_INSTANCE_ID=i-0c94b9da838546498
#     BROKER_2_INSTANCE_ID=i-02b863c43d5871e7a
#     BROKER_3_INSTANCE_ID=i-0a2273b274d23632a
#     CONNECT_1_INSTANCE_ID=i-0a9cd118cb94005c1
#     MONITOR_1_INSTANCE_ID=i-0b85f9f370ddc8dac
#   - AWS CLI v2 configured
#   - AWS_REGION in .env
#
################################################################################

set -euo pipefail

# Colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

OUTPUT_FORMAT="human"

while [[ $# -gt 0 ]]; do
  case $1 in
    --json) OUTPUT_FORMAT="json"; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

if [[ ! -f .env ]]; then
  echo -e "${RED}Error: .env file not found${NC}"
  exit 1
fi

source .env

get_instance_specs() {
  local type=$1

  # Exact matches (CDC-typical sizes)
  case $type in
    # i3 series (NVMe) — Kafka brokers
    i3.large) echo "2,16,NVMe" ;;
    i3.xlarge) echo "4,31,NVMe" ;;
    i3.2xlarge) echo "8,61,NVMe" ;;
    i3.4xlarge) echo "16,122,NVMe" ;;
    i3.8xlarge) echo "32,244,NVMe" ;;
    i3.16xlarge) echo "64,488,NVMe" ;;

    # i4i series (newer NVMe)
    i4i.large) echo "2,16,NVMe" ;;
    i4i.xlarge) echo "4,32,NVMe" ;;
    i4i.2xlarge) echo "8,64,NVMe" ;;
    i4i.4xlarge) echo "16,128,NVMe" ;;
    i4i.8xlarge) echo "32,256,NVMe" ;;

    # m5 series (EBS) — Connect, monitoring
    m5.large) echo "2,8,EBS" ;;
    m5.xlarge) echo "4,16,EBS" ;;
    m5.2xlarge) echo "8,32,EBS" ;;
    m5.4xlarge) echo "16,64,EBS" ;;
    m5.8xlarge) echo "32,128,EBS" ;;
    m5.12xlarge) echo "48,192,EBS" ;;
    m5.24xlarge) echo "96,384,EBS" ;;

    # m5d series (NVMe+EBS)
    m5d.large) echo "2,8,NVMe+EBS" ;;
    m5d.xlarge) echo "4,16,NVMe+EBS" ;;
    m5d.2xlarge) echo "8,32,NVMe+EBS" ;;
    m5d.4xlarge) echo "16,64,NVMe+EBS" ;;
    m5d.8xlarge) echo "32,128,NVMe+EBS" ;;
    m5d.12xlarge) echo "48,192,NVMe+EBS" ;;
    m5d.24xlarge) echo "96,384,NVMe+EBS" ;;

    # m6i series (newer Intel)
    m6i.large) echo "2,8,EBS" ;;
    m6i.xlarge) echo "4,16,EBS" ;;
    m6i.2xlarge) echo "8,32,EBS" ;;
    m6i.4xlarge) echo "16,64,EBS" ;;
    m6i.8xlarge) echo "32,128,EBS" ;;

    # m6g series (Graviton2)
    m6g.large) echo "2,8,EBS" ;;
    m6g.xlarge) echo "4,16,EBS" ;;
    m6g.2xlarge) echo "8,32,EBS" ;;
    m6g.4xlarge) echo "16,64,EBS" ;;

    # m7i series (latest Intel)
    m7i.large) echo "2,8,EBS" ;;
    m7i.xlarge) echo "4,16,EBS" ;;
    m7i.2xlarge) echo "8,32,EBS" ;;
    m7i.4xlarge) echo "16,64,EBS" ;;

    # m7g series (latest Graviton)
    m7g.large) echo "2,8,EBS" ;;
    m7g.xlarge) echo "4,16,EBS" ;;
    m7g.2xlarge) echo "8,32,EBS" ;;
    m7g.4xlarge) echo "16,64,EBS" ;;

    # r6i series (memory-optimized Intel)
    r6i.large) echo "2,16,EBS" ;;
    r6i.xlarge) echo "4,32,EBS" ;;
    r6i.2xlarge) echo "8,64,EBS" ;;
    r6i.4xlarge) echo "16,128,EBS" ;;
    r6i.8xlarge) echo "32,256,EBS" ;;

    # r6g series (memory-optimized Graviton2)
    r6g.large) echo "2,16,EBS" ;;
    r6g.xlarge) echo "4,32,EBS" ;;
    r6g.2xlarge) echo "8,64,EBS" ;;
    r6g.4xlarge) echo "16,128,EBS" ;;

    # r7i series (memory-optimized Intel)
    r7i.large) echo "2,16,EBS" ;;
    r7i.xlarge) echo "4,32,EBS" ;;
    r7i.2xlarge) echo "8,64,EBS" ;;
    r7i.4xlarge) echo "16,128,EBS" ;;

    # r7g series (memory-optimized Graviton)
    r7g.large) echo "2,16,EBS" ;;
    r7g.xlarge) echo "4,32,EBS" ;;
    r7g.2xlarge) echo "8,64,EBS" ;;
    r7g.4xlarge) echo "16,128,EBS" ;;

    # c6i series (compute-optimized Intel)
    c6i.large) echo "2,4,EBS" ;;
    c6i.xlarge) echo "4,8,EBS" ;;
    c6i.2xlarge) echo "8,16,EBS" ;;
    c6i.4xlarge) echo "16,32,EBS" ;;
    c6i.8xlarge) echo "32,64,EBS" ;;

    # c6g series (compute-optimized Graviton2)
    c6g.large) echo "2,4,EBS" ;;
    c6g.xlarge) echo "4,8,EBS" ;;
    c6g.2xlarge) echo "8,16,EBS" ;;
    c6g.4xlarge) echo "16,32,EBS" ;;

    # c7i series (compute-optimized Intel)
    c7i.large) echo "2,4,EBS" ;;
    c7i.xlarge) echo "4,8,EBS" ;;
    c7i.2xlarge) echo "8,16,EBS" ;;
    c7i.4xlarge) echo "16,32,EBS" ;;

    # c7g series (compute-optimized Graviton)
    c7g.large) echo "2,4,EBS" ;;
    c7g.xlarge) echo "4,8,EBS" ;;
    c7g.2xlarge) echo "8,16,EBS" ;;
    c7g.4xlarge) echo "16,32,EBS" ;;

    # Fallback: derive from size pattern
    *)
      local size="${type##*.}"  # Extract size (e.g., "2xlarge" from "m5.2xlarge")
      local family="${type%%.*}" # Extract family (e.g., "m5" from "m5.2xlarge")

      # Family-based specs (vCPU, RAM pattern)
      case "$family" in
        i3*|i4*) echo "$(derive_nvme_specs "$size")NVMe" ;;
        m5*|m6*|m7*) echo "$(derive_general_specs "$size")EBS" ;;
        m5d*|m6d*|m7d*) echo "$(derive_general_specs "$size")NVMe+EBS" ;;
        r6*|r7*) echo "$(derive_memory_specs "$size")EBS" ;;
        c6*|c7*) echo "$(derive_compute_specs "$size")EBS" ;;
        t3*|t4*) echo "$(derive_general_specs "$size")EBS" ;;
        *) echo "unknown,unknown,unknown" ;;
      esac
      ;;
  esac
}

# Derive specs for NVMe instance families (i3, i4)
derive_nvme_specs() {
  local size=$1
  case "$size" in
    large) echo "2,16," ;;
    xlarge) echo "4,31," ;;
    2xlarge) echo "8,61," ;;
    4xlarge) echo "16,122," ;;
    8xlarge) echo "32,244," ;;
    16xlarge) echo "64,488," ;;
    *) echo "unknown,unknown," ;;
  esac
}

# Derive specs for general purpose (m5, m6, m7)
derive_general_specs() {
  local size=$1
  case "$size" in
    large) echo "2,8," ;;
    xlarge) echo "4,16," ;;
    2xlarge) echo "8,32," ;;
    4xlarge) echo "16,64," ;;
    8xlarge) echo "32,128," ;;
    12xlarge) echo "48,192," ;;
    16xlarge) echo "64,256," ;;
    24xlarge) echo "96,384," ;;
    *) echo "unknown,unknown," ;;
  esac
}

# Derive specs for memory-optimized (r6, r7)
derive_memory_specs() {
  local size=$1
  case "$size" in
    large) echo "2,16," ;;
    xlarge) echo "4,32," ;;
    2xlarge) echo "8,64," ;;
    4xlarge) echo "16,128," ;;
    8xlarge) echo "32,256," ;;
    12xlarge) echo "48,384," ;;
    16xlarge) echo "64,512," ;;
    *) echo "unknown,unknown," ;;
  esac
}

# Derive specs for compute-optimized (c6, c7)
derive_compute_specs() {
  local size=$1
  case "$size" in
    large) echo "2,4," ;;
    xlarge) echo "4,8," ;;
    2xlarge) echo "8,16," ;;
    4xlarge) echo "16,32," ;;
    8xlarge) echo "32,64," ;;
    9xlarge) echo "36,72," ;;
    12xlarge) echo "48,96," ;;
    18xlarge) echo "72,144," ;;
    24xlarge) echo "96,192," ;;
    *) echo "unknown,unknown," ;;
  esac
}

fetch_instance_type() {
  local instance_id=$1
  local region="${AWS_REGION:-us-east-1}"

  [[ -z "$instance_id" ]] && echo "unknown" && return

  aws ec2 describe-instances \
    --region "$region" \
    --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].InstanceType' \
    --output text 2>/dev/null || echo "unknown"
}

get_tuning_advice() {
  local role=$1 type=$2

  case $role in
    broker)
      cat <<'EOF'

Broker Tuning (i3.4xlarge):
  • num.network.threads=12 (handle parallel connections)
  • num.io.threads=12 (match vCPU for I/O throughput)
  • replica.socket.send.buffer.bytes=102400 (100 KB)
  • replica.socket.receive.buffer.bytes=102400
  • num.replica.fetchers=4 (parallel replication)
  • compression.type=snappy (CPU-efficient, 3-4x compression)
  • JVM heap: 12-16 GB (60% of available RAM)
  • Monitor: CPU <80%, Memory <85%, Disk I/O <50%
EOF
      ;;
    connect)
      cat <<'EOF'

Connect Tuning (m5.2xlarge):
  • tasks.max=2 (one forward, one reverse CDC)
  • JDBC sink batch.size=50-100 (lower for Aurora, higher for stable networks)
  • Debezium source batch.size=100-1000 (snapshot: 1000, streaming: 100)
  • source poll.interval.ms=100 (streaming), 500 (snapshot)
  • JVM heap: 3-4 GB per task (total 6-8 GB for 2 tasks)
  • Consumer fetch.min.bytes=1 (streaming profile)
  • Monitor: CPU <80%, Memory <85%, connector lag <60s
EOF
      ;;
    monitor)
      cat <<'EOF'

Monitoring Tuning (m5d.2xlarge):
  • Grafana: ensure 4-6 GB RAM available
  • Prometheus: retention 24-72 hours (trade-off storage vs history)
  • ksqlDB heap: 4-8 GB (if running aggregations)
  • JVM defaults acceptable unless high metric volume
EOF
      ;;
  esac
}

output_human() {
  local b1=$1 b2=$2 b3=$3 c=$4 m=$5

  echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════════════════════════${NC}"
  echo -e "${BLUE}CDC Infrastructure Analysis — $(date '+%Y-%m-%d %H:%M:%S')${NC}"
  echo -e "${BLUE}═══════════════════════════════════════════════════════════════════════════════════${NC}\n"

  echo -e "${GREEN}EC2 Instances${NC}\n"
  printf "%-25s %-15s %-8s %-8s %-12s\n" "Node" "Type" "vCPU" "RAM GB" "Storage"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  for i in 1 2 3; do
    eval "t=\$b$i"
    local specs=$(get_instance_specs "$t")
    IFS=',' read -r vcpu ram storage <<<"$specs"
    printf "%-25s %-15s %-8s %-8s %-12s\n" "broker-${i}" "$t" "$vcpu" "$ram" "$storage"
  done

  local specs=$(get_instance_specs "$c")
  IFS=',' read -r vcpu ram storage <<<"$specs"
  printf "%-25s %-15s %-8s %-8s %-12s\n" "connect-1" "$c" "$vcpu" "$ram" "$storage"

  specs=$(get_instance_specs "$m")
  IFS=',' read -r vcpu ram storage <<<"$specs"
  printf "%-25s %-15s %-8s %-8s %-12s\n" "monitor-1" "$m" "$vcpu" "$ram" "$storage"

  echo -e "\n${GREEN}General Tuning Recommendations${NC}"
  echo ""
  get_tuning_advice "broker" "$b1"
  echo ""
  get_tuning_advice "connect" "$c"
  echo ""
  get_tuning_advice "monitor" "$m"

  echo -e "\n${YELLOW}Key Metrics to Monitor${NC}\n"
  cat <<'METRICS'
Metric              Green       Yellow      Red         Action
──────────────────────────────────────────────────────────────────────────────
CPU Usage           <30%        30-70%      >80%        Reduce batch sizes
Memory Usage        <40%        40-70%      >85%        Reduce JVM heap
CDC Lag             <1s         1-60s       >60s        Increase polling
Disk I/O (util)     <20%        20-50%      >80%        Add NVMe storage
GC Pause Time       <100ms      100-500ms   >1s         Tune heap, batches
METRICS

  echo -e "\n${GREEN}Next Steps:${NC}"
  echo "1. Review tuning recommendations above"
  echo "2. Edit .env with recommended settings"
  echo "3. Redeploy: ./scripts/6-deploy-connectors.sh"
  echo "4. For detailed guidance: cat docs/INFRASTRUCTURE-TUNING-GUIDE.md"
  echo ""
}

output_json() {
  local b1=$1 c=$4 m=$5

  cat <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "infrastructure": {
    "brokers": {
      "type": "$b1",
      "count": 3,
      "specs": "$(get_instance_specs "$b1" | cut -d, -f1-2 | sed 's/,/ vCPU, /;s/$/ GB RAM/')"
    },
    "connect": {
      "type": "$c",
      "specs": "$(get_instance_specs "$c" | cut -d, -f1-2 | sed 's/,/ vCPU, /;s/$/ GB RAM/')"
    },
    "monitor": {
      "type": "$m",
      "specs": "$(get_instance_specs "$m" | cut -d, -f1-2 | sed 's/,/ vCPU, /;s/$/ GB RAM/')"
    }
  }
}
EOF
}

if [[ -z "${BROKER_1_INSTANCE_ID:-}" ]] || [[ -z "${CONNECT_1_INSTANCE_ID:-}" ]] || [[ -z "${MONITOR_1_INSTANCE_ID:-}" ]]; then
  echo -e "${RED}Error: Instance IDs not configured in .env${NC}"
  echo ""
  echo "Required variables in .env:"
  echo "  BROKER_1_INSTANCE_ID=i-..."
  echo "  BROKER_2_INSTANCE_ID=i-..."
  echo "  BROKER_3_INSTANCE_ID=i-..."
  echo "  CONNECT_1_INSTANCE_ID=i-..."
  echo "  MONITOR_1_INSTANCE_ID=i-..."
  exit 1
fi

echo -e "${BLUE}CDC Infrastructure Analyzer${NC}"
echo "[*] Fetching instance types from AWS..." >&2

b1=$(fetch_instance_type "${BROKER_1_INSTANCE_ID}")
b2=$(fetch_instance_type "${BROKER_2_INSTANCE_ID:-}")
b3=$(fetch_instance_type "${BROKER_3_INSTANCE_ID:-}")
c=$(fetch_instance_type "${CONNECT_1_INSTANCE_ID}")
m=$(fetch_instance_type "${MONITOR_1_INSTANCE_ID}")

b2="${b2:-$b1}"
b3="${b3:-$b1}"

case $OUTPUT_FORMAT in
  human) output_human "$b1" "$b2" "$b3" "$c" "$m" ;;
  json) output_json "$b1" "$b2" "$b3" "$c" "$m" ;;
esac

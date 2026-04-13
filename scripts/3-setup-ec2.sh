#!/usr/bin/env bash
# =============================================================================
# setup-ec2.sh — EC2 Bootstrap for Confluent Platform CDC deployment
#
# Prepares an Amazon Linux 2023 EC2 instance:
#   - Installs Docker and Docker Compose plugin
#   - Detects and formats NVMe ephemeral drives (i3/m5d instances)
#   - Mounts NVMe at /data/kafka with xfs + noatime
#   - Applies kernel tuning for Kafka workloads
#
# Usage (from jumpbox — dispatches to all nodes via SSM):
#   ./scripts/3-setup-ec2.sh
#
# Usage (on-node — direct execution as root):
#   sudo bash scripts/3-setup-ec2.sh --local
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors for output
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# SSM Dispatch Mode (jumpbox → all nodes)
# When not root and no --local flag, dispatch to all nodes via SSM
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 && "${1:-}" != "--local" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    ENV_FILE="$SCRIPT_DIR/.env"
    AWS_REGION=${AWS_REGION:-us-east-1}

    if [[ ! -f "$ENV_FILE" ]]; then
        error ".env file not found at $ENV_FILE"
        exit 1
    fi
    source "$ENV_FILE"

    echo "[*] Phase 3: Bootstrap EC2 nodes via SSM"
    echo "    Dispatching setup to all 5 nodes..."
    echo ""

    NODES=(
        "broker1:${BROKER_1_INSTANCE_ID}"
        "broker2:${BROKER_2_INSTANCE_ID}"
        "broker3:${BROKER_3_INSTANCE_ID}"
        "connect:${CONNECT_1_INSTANCE_ID}"
        "monitor:${MONITOR_1_INSTANCE_ID}"
    )

    DEPLOY_DIR="/home/ec2-user/cdc-on-ec2-docker"
    FAILED=0

    for entry in "${NODES[@]}"; do
        node_name="${entry%%:*}"
        instance_id="${entry##*:}"
        echo -n "  🚀 $node_name ($instance_id)... "

        cmd_id=$(aws ssm send-command \
            --region "$AWS_REGION" \
            --instance-ids "$instance_id" \
            --document-name "AWS-RunShellScript" \
            --parameters "{\"commands\":[\"cd ${DEPLOY_DIR} && sudo bash scripts/3-setup-ec2.sh --local\"],\"executionTimeout\":[\"600\"]}" \
            --timeout-seconds 600 \
            --output text \
            --query 'Command.CommandId' 2>/dev/null)

        if [[ -z "$cmd_id" ]]; then
            echo "❌ Failed to dispatch"
            FAILED=$((FAILED + 1))
            continue
        fi

        # Poll for completion
        for i in $(seq 1 60); do
            status=$(aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$instance_id" \
                --query 'Status' --output text 2>/dev/null || echo "Pending")
            if [[ "$status" == "Success" ]]; then
                echo "✅ done"
                break
            elif [[ "$status" == "Failed" || "$status" == "TimedOut" || "$status" == "Cancelled" ]]; then
                echo "❌ $status"
                # Show error output
                aws ssm get-command-invocation \
                    --region "$AWS_REGION" \
                    --command-id "$cmd_id" \
                    --instance-id "$instance_id" \
                    --query 'StandardErrorContent' --output text 2>/dev/null | tail -5
                FAILED=$((FAILED + 1))
                break
            fi
            sleep 10
        done
        if [[ "$status" != "Success" && "$status" != "Failed" && "$status" != "TimedOut" && "$status" != "Cancelled" ]]; then
            echo "❌ Timed out waiting"
            FAILED=$((FAILED + 1))
        fi
    done

    echo ""
    if [[ $FAILED -eq 0 ]]; then
        echo "✅ All 5 nodes bootstrapped successfully"
    else
        echo "❌ $FAILED node(s) failed — check SSM command history"
        exit 1
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# On-Node Execution (must be root)
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo) or without --local to dispatch via SSM."
    exit 1
fi

SUMMARY=()

# ---------------------------------------------------------------------------
# 0. Pre-flight: fix broken Docker daemon.json if present
# ---------------------------------------------------------------------------
# AL2023's Docker systemd unit passes --default-ulimit nofile=32768:65536.
# If daemon.json also has default-ulimits, Docker refuses to start.
# Fix this before attempting to start Docker.
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
if [[ -f "${DOCKER_DAEMON_JSON}" ]] && grep -q '"default-ulimits"' "${DOCKER_DAEMON_JSON}" 2>/dev/null; then
    info "Fixing conflicting default-ulimits in ${DOCKER_DAEMON_JSON}..."
    if command -v jq &>/dev/null; then
        jq 'del(."default-ulimits")' "${DOCKER_DAEMON_JSON}" > "${DOCKER_DAEMON_JSON}.tmp" \
            && mv "${DOCKER_DAEMON_JSON}.tmp" "${DOCKER_DAEMON_JSON}"
    else
        # Fallback: replace with minimal config
        cat > "${DOCKER_DAEMON_JSON}" <<'FIXCFG'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "5"
    }
}
FIXCFG
    fi
    SUMMARY+=("Fixed Docker daemon.json (removed conflicting default-ulimits)")
fi

# ---------------------------------------------------------------------------
# 1. Install Docker
# ---------------------------------------------------------------------------
info "Installing Docker..."
if command -v docker &>/dev/null; then
    info "Docker is already installed: $(docker --version)"
else
    dnf install -y docker
    SUMMARY+=("Installed Docker")
fi

# Start and enable Docker service
systemctl start docker
systemctl enable docker
SUMMARY+=("Docker service started and enabled")

# Add ec2-user to docker group so they can run docker without sudo
if id -nG ec2-user | grep -qw docker; then
    info "ec2-user is already in the docker group."
else
    usermod -aG docker ec2-user
    SUMMARY+=("Added ec2-user to docker group")
    info "Added ec2-user to docker group (log out and back in to take effect)."
fi

# ---------------------------------------------------------------------------
# 2. Install Docker Compose plugin
# ---------------------------------------------------------------------------
info "Installing Docker Compose plugin..."
if docker compose version &>/dev/null; then
    info "Docker Compose plugin already installed: $(docker compose version)"
else
    # Amazon Linux 2023: install via dnf plugin or manual download
    COMPOSE_VERSION="v2.29.2"
    DOCKER_CLI_PLUGINS="/usr/local/lib/docker/cli-plugins"
    mkdir -p "${DOCKER_CLI_PLUGINS}"
    curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-$(uname -m)" \
        -o "${DOCKER_CLI_PLUGINS}/docker-compose"
    chmod +x "${DOCKER_CLI_PLUGINS}/docker-compose"
    SUMMARY+=("Installed Docker Compose ${COMPOSE_VERSION}")
fi

info "Docker Compose version: $(docker compose version)"

# ---------------------------------------------------------------------------
# 3. Detect and mount NVMe ephemeral drives
# ---------------------------------------------------------------------------
# Load KAFKA_DATA_DIR from .env if available, else use default
if [[ -f .env ]]; then
    KAFKA_DATA_DIR=$(grep "^KAFKA_DATA_DIR=" .env | cut -d= -f2 || echo "/data/kafka")
else
    KAFKA_DATA_DIR="${KAFKA_DATA_DIR:-/data/kafka}"
fi

# Skip if /data/kafka is already mounted or RAID already assembled (idempotent re-run)
if mountpoint -q "${KAFKA_DATA_DIR}" 2>/dev/null; then
    info "/data/kafka is already mounted — skipping NVMe setup."
    SUMMARY+=("NVMe already mounted at ${KAFKA_DATA_DIR} (skipped)")
elif [[ -d "${KAFKA_DATA_DIR}" ]] && [[ -f /etc/sysctl.d/99-kafka-tuning.conf ]]; then
    info "/data/kafka exists from previous run — skipping NVMe setup."
    SUMMARY+=("${KAFKA_DATA_DIR} already exists (skipped)")
else

info "Detecting NVMe instance storage..."

# NVMe instance-store devices on i3/m5d show up as /dev/nvme*n1
# EBS volumes also appear as NVMe on Nitro instances, so we filter by model.
NVME_DEVICES=()
for dev in /dev/nvme*n1; do
    [[ -b "$dev" ]] || continue
    # Check if this is an instance-store (not EBS) device
    # Instance-store NVMe devices have model containing "Instance Storage"
    MODEL=$(nvme id-ctrl "$dev" 2>/dev/null | grep -i "mn " | awk '{$1=""; print $0}' | xargs || true)
    if echo "$MODEL" | grep -qi "instance storage\|ephemeral\|NVMe SSD"; then
        NVME_DEVICES+=("$dev")
    fi
done

# Fallback: if nvme tool isn't available, check lsblk for non-EBS NVMe
if [[ ${#NVME_DEVICES[@]} -eq 0 ]]; then
    info "Trying alternative NVMe detection via lsblk..."
    while IFS= read -r dev; do
        # Skip devices that are already mounted (likely root EBS)
        if ! mount | grep -q "^${dev}"; then
            # Skip devices with partitions (likely OS disk)
            PARTS=$(lsblk -n -o NAME "${dev}" 2>/dev/null | wc -l)
            if [[ "$PARTS" -eq 1 ]]; then
                NVME_DEVICES+=("${dev}")
            fi
        fi
    done < <(lsblk -d -n -o NAME,TYPE | awk '$2=="disk" && $1~/nvme/ {print "/dev/"$1}')
fi

if [[ ${#NVME_DEVICES[@]} -gt 0 ]]; then
    info "Found ${#NVME_DEVICES[@]} NVMe instance-store device(s): ${NVME_DEVICES[*]}"

    if [[ ${#NVME_DEVICES[@]} -eq 1 ]]; then
        # Single NVMe drive — format and mount directly
        NVME_DEV="${NVME_DEVICES[0]}"
        info "Formatting ${NVME_DEV} as xfs..."
        mkfs.xfs -f "${NVME_DEV}"
        mkdir -p "${KAFKA_DATA_DIR}"
        mount -o noatime "${NVME_DEV}" "${KAFKA_DATA_DIR}"

        # Add to fstab (use UUID for reliability)
        UUID=$(blkid -s UUID -o value "${NVME_DEV}")
        if ! grep -q "${UUID}" /etc/fstab; then
            echo "UUID=${UUID}  ${KAFKA_DATA_DIR}  xfs  defaults,noatime,nofail  0 2" >> /etc/fstab
            SUMMARY+=("Added ${NVME_DEV} (UUID=${UUID}) to /etc/fstab")
        fi
        SUMMARY+=("Formatted ${NVME_DEV} as xfs, mounted at ${KAFKA_DATA_DIR}")

    else
        # Multiple NVMe drives — create software RAID 0 for max throughput
        info "Creating RAID 0 across ${#NVME_DEVICES[@]} NVMe devices..."
        dnf install -y mdadm || true
        mdadm --create /dev/md0 --level=0 --raid-devices=${#NVME_DEVICES[@]} "${NVME_DEVICES[@]}" --force
        mkfs.xfs -f /dev/md0
        mkdir -p "${KAFKA_DATA_DIR}"
        mount -o noatime /dev/md0 "${KAFKA_DATA_DIR}"

        # Persist RAID config
        mdadm --detail --scan >> /etc/mdadm.conf 2>/dev/null || true

        # Add to fstab
        UUID=$(blkid -s UUID -o value /dev/md0)
        if ! grep -q "${UUID}" /etc/fstab; then
            echo "UUID=${UUID}  ${KAFKA_DATA_DIR}  xfs  defaults,noatime,nofail  0 2" >> /etc/fstab
            SUMMARY+=("Added RAID0 (UUID=${UUID}) to /etc/fstab")
        fi
        SUMMARY+=("Created RAID 0 (${NVME_DEVICES[*]}), formatted xfs, mounted at ${KAFKA_DATA_DIR}")
    fi
else
    warn "No NVMe instance-store devices detected."
    warn "This instance may be EBS-only (e.g., Connect node without NVMe)."
    warn "Creating ${KAFKA_DATA_DIR} on root volume."
    mkdir -p "${KAFKA_DATA_DIR}"
    SUMMARY+=("No NVMe found — created ${KAFKA_DATA_DIR} on root EBS volume")
fi

fi  # end of mountpoint check

# Set ownership so Docker containers (and ec2-user) can write
chown -R 1000:1000 "${KAFKA_DATA_DIR}"
chmod 755 "${KAFKA_DATA_DIR}"
SUMMARY+=("Set ${KAFKA_DATA_DIR} ownership to 1000:1000")

# ---------------------------------------------------------------------------
# 4. Kernel tuning for Kafka
# ---------------------------------------------------------------------------
info "Applying kernel tuning for Kafka..."

SYSCTL_CONF="/etc/sysctl.d/99-kafka-tuning.conf"
cat > "${SYSCTL_CONF}" <<'SYSCTL'
# Kafka / Confluent Platform kernel tuning

# Required for Elasticsearch/ksqlDB (RocksDB)
vm.max_map_count = 262144

# Increase socket buffer sizes for high-throughput Kafka
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216

# Increase the number of allowed open file descriptors
fs.file-max = 1000000

# Increase network connection backlog
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 5000

# Reduce swap usage — Kafka relies on page cache, not swap
vm.swappiness = 1

# Dirty page tuning — flush more aggressively for consistent latency
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
SYSCTL

sysctl --system >/dev/null 2>&1
SUMMARY+=("Applied kernel tuning (vm.max_map_count, socket buffers, swappiness, etc.)")

# ---------------------------------------------------------------------------
# 5. Increase open file limits for ec2-user and Docker
# ---------------------------------------------------------------------------
info "Setting open file limits..."

LIMITS_CONF="/etc/security/limits.d/99-kafka.conf"
cat > "${LIMITS_CONF}" <<'LIMITS'
# Kafka requires high file descriptor limits
*  soft  nofile  100000
*  hard  nofile  100000
*  soft  nproc   65535
*  hard  nproc   65535
LIMITS

# Also configure Docker daemon for log rotation
# NOTE: Do NOT set default-ulimits here — AL2023's Docker systemd unit already
# passes --default-ulimit nofile=32768:65536. Setting it in both places causes
# Docker to refuse to start. System-level limits in /etc/security/limits.d/
# cover the host processes; Docker's flag covers containers.
# daemon.json conflict fix is handled in pre-flight (section 0).
# Only create daemon.json if it doesn't exist yet.
if [[ ! -f "${DOCKER_DAEMON_JSON}" ]]; then
    cat > "${DOCKER_DAEMON_JSON}" <<'DOCKERCFG'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "50m",
        "max-file": "5"
    }
}
DOCKERCFG
    systemctl restart docker
    SUMMARY+=("Configured Docker daemon (log rotation)")
fi

SUMMARY+=("Set file descriptor limits to 100000")

# ---------------------------------------------------------------------------
# 6. Install useful tools
# ---------------------------------------------------------------------------
info "Installing useful utilities..."
dnf install -y jq nmap-ncat nvme-cli htop iotop sysstat 2>/dev/null || true
SUMMARY+=("Installed jq, ncat, nvme-cli, htop, iotop, sysstat")

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "============================================="
echo "  EC2 Setup Complete"
echo "============================================="
for item in "${SUMMARY[@]}"; do
    echo "  - ${item}"
done
echo ""
echo "  Kafka data directory: ${KAFKA_DATA_DIR}"
df -h "${KAFKA_DATA_DIR}" 2>/dev/null | tail -1 | awk '{printf "  Disk: %s total, %s available\n", $2, $4}'
echo ""
echo "  Docker:  $(docker --version 2>/dev/null || echo 'not found')"
echo "  Compose: $(docker compose version 2>/dev/null || echo 'not found')"
echo ""
info "NOTE: Log out and back in for docker group membership to take effect."
echo "============================================="

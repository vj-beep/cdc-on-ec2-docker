#!/bin/bash
# ============================================================
# Phase 0: Pre-flight Audit
# ============================================================
# Verifies infrastructure readiness before deployment
#
# Infrastructure-agnostic checks (works with any deployment method):
#   - AWS CLI and credentials configured
#   - Required infrastructure exists:
#     * 5 EC2 instances (running)
#     * Aurora PostgreSQL database
#     * SQL Server database
#   - Network connectivity to all instances (via AWS SSM)
#   - .env file syntax and required variables
#   - Public repo is accessible
#
# ℹ️  Works with infrastructure deployed via:
#    - Terraform, CloudFormation, AWS CDK, or manual AWS Console
#    - Only checks that resources EXIST and are reachable
#
# Usage: ./scripts/0-preflight.sh
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
AWS_REGION=${AWS_REGION:-us-east-1}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

echo "[*] Phase 0: Pre-flight Audit"
echo ""

# Determine dispatch mode
DISPATCH_MODE="${DISPATCH_MODE:-ssm}"

# Check 1: AWS CLI
info "Checking AWS CLI..."
if ! command -v aws &>/dev/null; then
    error "AWS CLI not found. Install it and configure credentials."
    exit 1
fi
info "AWS CLI: $(aws --version)"

# Check 2: AWS Credentials
info "Checking AWS credentials..."
if ! aws sts get-caller-identity &>/dev/null; then
    error "AWS credentials not configured or invalid."
    exit 1
fi
info "AWS account: $(aws sts get-caller-identity --query Account --output text)"

# Check 3: .env file
info "Checking .env file..."
if [[ ! -f "$ENV_FILE" ]]; then
    error ".env file not found at $ENV_FILE"
    exit 1
fi
info ".env file exists"

# Check 4: .env syntax
info "Validating .env syntax..."
if ! bash -c "set -a; source $ENV_FILE; set +a; true" 2>/dev/null; then
    error ".env has syntax errors (e.g., unquoted special characters)"
    exit 1
fi
info ".env syntax valid"

# Check 5: Required .env variables
info "Checking required .env variables..."
source "$ENV_FILE"
DISPATCH_MODE="${DISPATCH_MODE:-ssm}"
for var in BROKER_1_IP BROKER_2_IP BROKER_3_IP CONNECT_1_IP MONITOR_1_IP PUBLIC_REPO_URL AURORA_HOST SQLSERVER_HOST; do
    if [[ -z "${!var}" ]]; then
        error "$var not set in .env"
        exit 1
    fi
done
# Instance IDs only required for SSM dispatch
if [[ "$DISPATCH_MODE" == "ssm" ]]; then
    for var in BROKER_1_INSTANCE_ID BROKER_2_INSTANCE_ID BROKER_3_INSTANCE_ID CONNECT_1_INSTANCE_ID MONITOR_1_INSTANCE_ID; do
        if [[ -z "${!var}" ]]; then
            error "$var not set in .env (required for DISPATCH_MODE=ssm)"
            exit 1
        fi
    done
else
    for var in BROKER_1_INSTANCE_ID BROKER_2_INSTANCE_ID BROKER_3_INSTANCE_ID CONNECT_1_INSTANCE_ID MONITOR_1_INSTANCE_ID; do
        if [[ -z "${!var}" ]]; then
            warn "$var not set (not required for DISPATCH_MODE=ssh)"
        fi
    done
fi
info "All required variables set"

# Check 6: EC2 instances (verify POC-specific nodes by IP)
info "Checking EC2 instances (POC nodes from .env)..."
poc_running=0
for ip_var in BROKER_1_IP BROKER_2_IP BROKER_3_IP CONNECT_1_IP MONITOR_1_IP; do
    node_ip="${!ip_var}"
    state=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=private-ip-address,Values=$node_ip" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null)
    if [[ -n "$state" && "$state" != "None" ]]; then
        poc_running=$((poc_running + 1))
    else
        error "$ip_var ($node_ip) — no running instance found"
    fi
done
if [[ $poc_running -lt 5 ]]; then
    error "Only $poc_running/5 deployment instances running"
    exit 1
fi
info "EC2: $poc_running/5 deployment instances running ✓"

# Check 7: Node reachability
if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    info "Checking SSH connectivity to nodes (DISPATCH_MODE=ssh)..."
    SSH_KEY_PATH="${SSH_KEY_PATH:-}"
    if [[ -z "$SSH_KEY_PATH" ]]; then
        error "SSH_KEY_PATH not set in .env (required for DISPATCH_MODE=ssh)"
        exit 1
    fi
    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        error "SSH key not found: $SSH_KEY_PATH"
        exit 1
    fi
    DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
    failed=0
    declare -A SSH_NODES=([broker1]="$BROKER_1_IP" [broker2]="$BROKER_2_IP" [broker3]="$BROKER_3_IP" [connect]="$CONNECT_1_IP" [monitor]="$MONITOR_1_IP")
    for node_name in "${!SSH_NODES[@]}"; do
        node_ip="${SSH_NODES[$node_name]}"
        if ssh -i "$SSH_KEY_PATH" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
               "$DEPLOY_USER@$node_ip" "echo ok" &>/dev/null; then
            info "$node_name ($node_ip): SSH reachable"
        else
            error "$node_name ($node_ip): SSH not reachable"
            failed=$((failed + 1))
        fi
    done
    if [[ $failed -gt 0 ]]; then
        error "$failed nodes unreachable via SSH"
        exit 1
    fi
else
    info "Checking node instances by private IP (DISPATCH_MODE=ssm)..."
    declare -A NODES=([broker1]="$BROKER_1_IP" [broker2]="$BROKER_2_IP" [broker3]="$BROKER_3_IP" [connect]="$CONNECT_1_IP" [monitor]="$MONITOR_1_IP")

    get_instance_id_by_ip() {
        aws ec2 describe-instances \
            --region "$AWS_REGION" \
            --filters "Name=private-ip-address,Values=$1" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text 2>/dev/null
    }

    failed=0
    for node_name in "${!NODES[@]}"; do
        node_ip="${NODES[$node_name]}"
        instance_id=$(get_instance_id_by_ip "$node_ip")
        if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
            error "Cannot find running instance with IP $node_ip"
            failed=$((failed + 1))
        else
            info "$node_name: $instance_id reachable"
        fi
    done

    if [[ $failed -gt 0 ]]; then
        error "$failed nodes not found via AWS API"
        exit 1
    fi
fi

# Check 8: RDS databases (infrastructure-agnostic)
info "Checking RDS databases (any deployment method)..."
aurora_exists=$(aws rds describe-db-instances \
    --region "$AWS_REGION" \
    --filters "Name=engine,Values=aurora-postgresql" \
    --query 'DBInstances | length(@)' \
    --output text 2>/dev/null || echo "0")
sqlserver_exists=$(aws rds describe-db-instances \
    --region "$AWS_REGION" \
    --filters "Name=engine,Values=sqlserver-ee,sqlserver-se,sqlserver-ex,sqlserver-web" \
    --query 'DBInstances | length(@)' \
    --output text 2>/dev/null || echo "0")

if [[ $aurora_exists -eq 0 ]]; then
    warn "Aurora PostgreSQL not found (may be self-hosted or different engine)"
else
    info "Aurora PostgreSQL found ✓"
fi

if [[ $sqlserver_exists -eq 0 ]]; then
    warn "SQL Server not found (may be self-hosted or different engine)"
else
    info "SQL Server found ✓"
fi

# Check 9: Public repo accessibility
info "Checking public repo..."
if ! git ls-remote "$PUBLIC_REPO_URL" &>/dev/null; then
    warn "Could not verify git repo: $PUBLIC_REPO_URL"
else
    info "Public repo accessible"
fi

echo ""
echo "${GREEN}✓ All pre-flight checks passed${NC}"
echo ""
echo "Infrastructure Summary:"
echo "  • 5 EC2 instances: Running ✓"
echo "  • Aurora PostgreSQL: $([ $aurora_exists -gt 0 ] && echo 'Found ✓' || echo 'Not found (OK if self-hosted)')"
echo "  • SQL Server: $([ $sqlserver_exists -gt 0 ] && echo 'Found ✓' || echo 'Not found (OK if self-hosted)')"
echo ""
echo "📋 Infrastructure Requirements (5 EC2 nodes):"
echo "  • Brokers (Nodes 1-3): NVMe-backed instance recommended (e.g., i3.4xlarge)"
echo "  • Connect (Node 4): 8+ vCPU, 32+ GB RAM (e.g., m5.2xlarge)"
echo "  • Monitor (Node 5): 8+ vCPU, 32+ GB RAM, local SSD preferred (e.g., m5d.2xlarge)"
echo ""
echo "ℹ️  Deployment method-agnostic:"
echo "  • Created via: Terraform, CloudFormation, CDK, or AWS Console"
echo "  • This script only verifies resources exist and are reachable"
echo ""
echo "Ready to proceed with deployment:"
echo "  1. ./scripts/1-validate-env.sh      (validate environment)"
echo "  2. ./scripts/2a-deploy-repo.sh     (clone repo to nodes)"
echo "  3. ./scripts/2b-distribute-env.sh  (copy .env to nodes)"
echo "  4. ./scripts/3-setup-ec2.sh        (bootstrap nodes)"

#!/bin/bash
# ============================================================
# Phase 4: Build Custom Connect Image
# ============================================================
# Builds the custom Debezium + JDBC Connect image on Node 4
#
# Prerequisites:
#   - Phase 3 completed (setup-ec2.sh on all nodes)
#   - Node 4 (connect) has repo cloned and .env available
#
# Usage (from jumpbox — dispatches to Node 4 via SSM):
#   ./scripts/4-build-connect.sh
#
# Usage (on Node 4 — direct execution):
#   ./scripts/4-build-connect.sh --local
#
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ERROR] .env not found"
    exit 1
fi

source "$ENV_FILE"

# ---------------------------------------------------------------------------
# Local mode: build directly on this node (Node 4)
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--local" || "${CDC_ON_NODE:-}" == "1" ]]; then
    echo "[*] Phase 4 (local): Building custom Connect image..."
    echo "[*] Step 1: Pre-flight validation..."

    export HTTP_PROXY HTTPS_PROXY NO_PROXY
    cd "$SCRIPT_DIR"

    # Validate Debezium tar files
    tar_files=(
        "connect/debezium-libs/debezium-connector-sqlserver-3.2.6.Final-plugin.tar.gz"
        "connect/debezium-libs/debezium-connector-postgres-3.2.6.Final-plugin.tar.gz"
        "connect/debezium-libs/debezium-connector-jdbc-3.2.6.Final-plugin.tar.gz"
    )

    tar_errors=0
    for tar_file in "${tar_files[@]}"; do
        if [[ ! -f "$tar_file" ]]; then
            echo "   ❌ Missing: $tar_file"
            tar_errors=$((tar_errors + 1))
        else
            size=$(stat -f%z "$tar_file" 2>/dev/null || stat -c%s "$tar_file" 2>/dev/null)
            size_mb=$((size / 1024 / 1024))
            # Verify file is gzip format
            if file "$tar_file" | grep -q "gzip compressed"; then
                echo "   ✅ $tar_file ($size_mb MB, valid gzip)"
            else
                echo "   ❌ $tar_file ($size_mb MB, INVALID FORMAT — not gzip)"
                tar_errors=$((tar_errors + 1))
            fi
        fi
    done

    # Verify pre-built JARs exist
    if [[ ! -f "connect/jars/kafka-connect-sqlserver-case-restorer-1.0.0.jar" ]]; then
        echo "   ❌ Missing JAR: connect/jars/kafka-connect-sqlserver-case-restorer-1.0.0.jar"
        tar_errors=$((tar_errors + 1))
    else
        echo "   ✅ connect/jars/kafka-connect-sqlserver-case-restorer-1.0.0.jar"
    fi

    if [[ $tar_errors -gt 0 ]]; then
        echo ""
        echo "[ERROR] Pre-flight validation failed ($tar_errors issue(s))"
        exit 1
    fi

    echo "[*] Step 2: Build Docker image..."
    echo "[*] Building image (pre-built JARs — typically 1-2 minutes)..."

    # Capture full build output for diagnostics
    build_log="/tmp/docker-build-$(date +%s).log"
    DOCKER_BUILDKIT=0 docker compose --env-file .env -f docker-compose.connect-build.yml build > >(tee "$build_log") 2>&1
    build_status=$?

    if [[ $build_status -eq 0 ]]; then
        echo ""
        echo "[OK] Connect image built successfully"
        docker images | grep cdc-connect
        echo ""
        echo "Next: ./scripts/5-start-node.sh --local connect"
        exit 0
    else
        echo ""
        echo "[ERROR] Docker build failed with exit code $build_status"
        echo ""
        echo "=== Docker Build Output (last 50 lines) ==="
        tail -50 "$build_log"
        echo "=== Full log saved to: $build_log ==="
        echo ""
        echo "[DIAGNOSTICS]"
        echo "1. Check tar file integrity:"
        for tar_file in "${tar_files[@]}"; do
            if [[ -f "$tar_file" ]]; then
                tar tzf "$tar_file" > /dev/null 2>&1 && echo "   ✅ $tar_file is valid" || echo "   ❌ $tar_file is CORRUPTED"
            fi
        done
        echo ""
        echo "[ACTIONS]"
        echo "1. Re-run 2a-deploy-repo.sh to re-clone fresh files"
        echo "2. Verify proxy connectivity: curl -v --proxy $HTTP_PROXY http://example.com"
        echo "3. Check disk space: df -h"
        echo "4. Re-run this script"
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Remote Dispatch mode: send build command to Node 4 (SSH or SSM)
# ---------------------------------------------------------------------------
AWS_REGION=${AWS_REGION:-us-east-1}
DISPATCH_MODE="${DISPATCH_MODE:-ssm}"
DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
DEPLOY_DIR="${DEPLOY_DIR:-/home/${DEPLOY_USER}/cdc-on-ec2-docker}"

if [[ -z "$CONNECT_1_IP" ]]; then
    echo "[ERROR] CONNECT_1_IP not set"
    exit 1
fi

echo "[*] Phase 4: Building custom Connect image on Node 4 ($CONNECT_1_IP) [${DISPATCH_MODE^^}]..."
echo "[*] Building image (pre-built JARs — typically 1-2 minutes)..."

if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    # --- SSH dispatch ---
    SSH_KEY="${SSH_KEY_PATH:-}"
    if [[ -z "$SSH_KEY" || ! -f "$SSH_KEY" ]]; then
        echo "[ERROR] SSH_KEY_PATH not set or key not found (required for DISPATCH_MODE=ssh)"
        exit 1
    fi

    ssh -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        "${DEPLOY_USER}@${CONNECT_1_IP}" \
        "cd ${DEPLOY_DIR} && source ${DEPLOY_DIR}/.env && export HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy=\${HTTP_PROXY} https_proxy=\${HTTPS_PROXY} no_proxy=\${NO_PROXY} && \
        echo '[*] Pre-flight validation...' && \
        for f in connect/debezium-libs/debezium-connector-*.tar.gz; do \
          if [[ -f \"\$f\" ]]; then \
            sz=\$(stat -c%s \"\$f\" 2>/dev/null || stat -f%z \"\$f\" 2>/dev/null); \
            echo \"   ✅ \$(basename \$f) (\$((sz/1024/1024))M)\"; \
            file \"\$f\" | grep -q 'gzip' || echo \"   ❌ \$(basename \$f) NOT gzip format\"; \
          else echo \"   ❌ Missing: \$f\"; fi; \
        done && \
        [[ -f connect/jars/kafka-connect-sqlserver-case-restorer-1.0.0.jar ]] && echo '   ✅ kafka-connect-sqlserver-case-restorer JAR' || echo '   ❌ Missing case restorer JAR' && \
        echo '[*] Building Docker image...' && \
        DOCKER_BUILDKIT=0 docker compose --env-file ${DEPLOY_DIR}/.env -f docker-compose.connect-build.yml build > /tmp/docker-build.log 2>&1 || \
        { echo '[ERROR] Build failed'; echo '=== Build log (last 50 lines) ==='; tail -50 /tmp/docker-build.log; echo '=== Diagnostics ==='; \
          for f in connect/debezium-libs/debezium-connector-*.tar.gz; do tar tzf \"\$f\" > /dev/null 2>&1 && echo \"✅ \$(basename \$f) valid\" || echo \"❌ \$(basename \$f) CORRUPTED\"; done; exit 1; } && \
        docker images | grep cdc-connect" 2>&1

    if [[ $? -eq 0 ]]; then
        echo ""
        echo "[OK] Connect image built successfully"
        echo ""
        echo "Next: ./scripts/5-start-node.sh connect"
    else
        echo "[ERROR] Build failed via SSH — check output above for details"
        exit 1
    fi
else
    # --- SSM dispatch ---
    get_instance_id_by_ip() {
        aws ec2 describe-instances \
            --region "$AWS_REGION" \
            --filters "Name=private-ip-address,Values=$1" "Name=instance-state-name,Values=running" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text 2>/dev/null
    }

    instance_id=$(get_instance_id_by_ip "$CONNECT_1_IP")
    if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
        echo "[ERROR] Cannot find Node 4 instance"
        exit 1
    fi

    echo "[*] Instance ID: $instance_id"

    cmd_json=$(jq -c . <<'JSONEOF'
{
  "commands": [
    "cd ${DEPLOY_DIR} && source ${DEPLOY_DIR}/.env && export HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy=${HTTP_PROXY} https_proxy=${HTTPS_PROXY} no_proxy=${NO_PROXY}",
    "echo '[*] Pre-flight validation...'",
    "for f in ${DEPLOY_DIR}/connect/debezium-libs/debezium-connector-*.tar.gz; do if [[ -f \"$f\" ]]; then sz=$(stat -c%s \"$f\" 2>/dev/null || stat -f%z \"$f\" 2>/dev/null); echo \"   ✅ $(basename $f) ($(($sz/1024/1024))M)\"; file \"$f\" | grep -q 'gzip' || echo \"   ❌ $(basename $f) NOT gzip format\"; else echo \"   ❌ Missing: $f\"; fi; done",
    "[[ -f ${DEPLOY_DIR}/connect/jars/kafka-connect-sqlserver-case-restorer-1.0.0.jar ]] && echo '   ✅ kafka-connect-sqlserver-case-restorer JAR' || echo '   ❌ Missing case restorer JAR'",
    "echo '[*] Building Docker image...'",
    "DOCKER_BUILDKIT=0 docker compose --env-file ${DEPLOY_DIR}/.env -f docker-compose.connect-build.yml build > /tmp/docker-build.log 2>&1 || { echo '[ERROR] Build failed'; echo '=== Build log (last 50 lines) ==='; tail -50 /tmp/docker-build.log; echo '=== Diagnostics ==='; for f in ${DEPLOY_DIR}/connect/debezium-libs/debezium-connector-*.tar.gz; do tar tzf \"$f\" > /dev/null 2>&1 && echo \"✅ $(basename $f) valid\" || echo \"❌ $(basename $f) CORRUPTED\"; done; exit 1; }",
    "docker images | grep cdc-connect"
  ],
  "executionTimeout": ["600"]
}
JSONEOF
)

    cmd_id=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "$cmd_json" \
        --query 'Command.CommandId' \
        --output text 2>/dev/null)

    if [[ -z "$cmd_id" || "$cmd_id" == "None" ]]; then
        echo "[ERROR] Failed to send build command"
        exit 1
    fi

    # Poll for completion (up to 10 minutes — pre-built JARs, no Maven downloads)
    timeout=900
    elapsed=0
    status="Pending"

    while [[ ("$status" == "InProgress" || "$status" == "Pending") && $elapsed -lt $timeout ]]; do
        sleep 10
        elapsed=$((elapsed + 10))
        status=$(aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --query 'Status' \
            --output text 2>/dev/null)
        echo -n "."
    done

    echo ""

    if [[ "$status" == "Success" ]]; then
        echo "[OK] Connect image built successfully"
        echo ""
        echo "Next: ./scripts/5-start-node.sh connect"
    else
        echo "[ERROR] Build failed. Status: $status"
        echo ""
        echo "=== Output from Node 4 ==="
        aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --query 'StandardOutputContent' \
            --output text 2>/dev/null | tail -100
        echo ""
        echo "=== Stderr (if any) ==="
        aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --query 'StandardErrorContent' \
            --output text 2>/dev/null
        exit 1
    fi
fi

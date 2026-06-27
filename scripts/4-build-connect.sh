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

    # Diagnostics function for proxy issues
    diagnose_proxy() {
        echo ""
        echo "[PROXY DIAGNOSTICS]"
        echo "Proxy Config:"
        echo "  HTTP_PROXY=${HTTP_PROXY:-<not set>}"
        echo "  HTTPS_PROXY=${HTTPS_PROXY:-<not set>}"
        echo "  NO_PROXY=${NO_PROXY:-<not set>}"

        if [[ -z "$HTTP_PROXY" ]]; then
            echo ""
            echo "⚠️  WARNING: HTTP_PROXY is not set"
            echo "   If Node 4 lacks direct internet, downloads may fail"
            return 0
        fi

        # Extract proxy host and port
        proxy_url="${HTTP_PROXY#*://}"
        proxy_host="${proxy_url%%:*}"
        proxy_port="${proxy_url##*:}"

        echo ""
        echo "Testing proxy connectivity..."

        # Test 1: TCP connection to proxy
        if timeout 3 bash -c "echo -n > /dev/tcp/$proxy_host/$proxy_port" 2>/dev/null; then
            echo "  ✅ TCP connection to $proxy_host:$proxy_port OK"
        else
            echo "  ❌ CANNOT reach proxy at $proxy_host:$proxy_port"
            echo "     Fix: Check network routing, firewalls, proxy host/port in .env"
            return 1
        fi

        # Test 2: HTTP proxy functionality (GET request)
        local proxy_test_resp
        proxy_test_resp=$(curl -s -w "%{http_code}" --connect-timeout 5 --proxy "$HTTP_PROXY" http://httpbin.org/get 2>/dev/null | tail -c 3)
        if [[ "$proxy_test_resp" == "200" ]]; then
            echo "  ✅ HTTP proxy functionality OK (httpbin.org reachable)"
        elif [[ "$proxy_test_resp" == "000" ]]; then
            echo "  ⚠️  Cannot reach external sites through proxy"
            echo "     Fix: Proxy may block external traffic, check proxy rules"
            return 1
        else
            echo "  ⚠️  HTTP proxy returned status $proxy_test_resp"
        fi

        # Test 3: DNS resolution
        if timeout 3 bash -c "getent hosts 8.8.8.8 > /dev/null" 2>/dev/null || ping -c 1 8.8.8.8 > /dev/null 2>&1; then
            echo "  ✅ DNS/external connectivity OK"
        else
            echo "  ⚠️  DNS or external connectivity may be limited"
        fi

        # Test 4: Docker daemon proxy config
        if systemctl is-active --quiet docker; then
            docker_proxy_status=$(docker info 2>/dev/null | grep -i proxy || echo "Not configured")
            if [[ "$docker_proxy_status" != "Not configured" ]]; then
                echo "  ℹ️  Docker daemon proxy: $docker_proxy_status"
            else
                echo "  ℹ️  Docker daemon proxy: Not configured (will use shell env vars)"
            fi
        fi

        echo ""
        return 0
    }

    # Run proxy diagnostics first
    diagnose_proxy || echo "[WARNING] Proxy diagnostics indicated issues"

    echo "[CONFLUENT HUB CONNECTORS]"
    # Connectors are installed from Confluent Hub at image build time (confluent-hub install).
    # No pre-downloaded tarballs required — confluent-hub runs inside the Docker build.
    echo "   ✅ debezium/debezium-connector-sqlserver (installed at build time)"
    echo "   ✅ debezium/debezium-connector-postgresql (installed at build time)"
    echo "   ✅ confluentinc/kafka-connect-jdbc (installed at build time)"
    tar_errors=0

    echo ""
    echo "[PRE-BUILT JAR FILES]"
    # Custom SMTs and SQL Server JDBC driver
    jar_files=(
        "connect/jars/kafka-connect-sqlserver-case-restorer-1.0.0.jar"
        "connect/jars/strip-null-bytes-smt.jar"
        "connect/jars/mssql-jdbc-12.4.2.jre11.jar"
    )

    jar_errors=0
    for jar_file in "${jar_files[@]}"; do
        if [[ ! -f "$jar_file" ]]; then
            echo "   ❌ Missing: $jar_file"
            jar_errors=$((jar_errors + 1))
        else
            size=$(stat -f%z "$jar_file" 2>/dev/null || stat -c%s "$jar_file" 2>/dev/null)
            size_kb=$((size / 1024))
            if [[ $size_kb -lt 10 ]]; then
                size_display="${size} B"
            else
                size_display="${size_kb} KB"
            fi
            echo "   ✅ $jar_file ($size_display)"
        fi
    done

    if [[ $jar_errors -gt 0 ]]; then
        echo ""
        echo "[ERROR] Missing JAR file(s) ($jar_errors)"
        tar_errors=$((tar_errors + jar_errors))
    fi

    if [[ $tar_errors -gt 0 ]]; then
        echo ""
        echo "[ERROR] Pre-flight validation failed ($tar_errors issue(s))"
        exit 1
    fi

    echo ""
    echo "[BUILD SUMMARY]"
    echo "   Source Connectors: debezium/debezium-connector-sqlserver + postgresql (Confluent Hub)"
    echo "   Sink Connector:    confluentinc/kafka-connect-jdbc (Confluent Hub)"
    echo "   Custom SMTs: 2 pre-built JARs (SqlServerCaseRestorer, StripNullBytes)"
    echo "   JDBC Driver: mssql-jdbc-12.4.2.jre11.jar (MS SQL Server)"
    echo ""

    echo "[*] Step 2: Build Docker image..."
    echo "[*] Building image (pre-built JARs — typically 1-2 minutes)..."

    # Capture full build output for diagnostics (silent, no interactive tee)
    build_log="/tmp/docker-build-$(date +%s).log"
    DOCKER_BUILDKIT=0 docker compose --env-file .env -f docker-compose.connect-build.yml build > "$build_log" 2>&1
    build_status=$?

    if [[ $build_status -eq 0 ]]; then
        echo ""
        echo "[OK] Connect image built successfully"
        echo ""
        echo "[IMAGE DETAILS]"
        docker images | grep cdc-connect | awk '{printf "   Image: %s:%s (%s MB)\n", $1, $2, int($4)}'
        echo ""

        # Extract image ID for JAR diagnostics
        image_id=$(docker images | grep cdc-connect | head -1 | awk '{print $3}')

        echo "[CUSTOM JAR FILES COPIED]"
        jdbc_plugin_dir="/usr/share/confluent-hub-components/confluentinc-kafka-connect-jdbc"
        shared_java_dir="/usr/share/java"
        for jar in mssql-jdbc-12.4.2.jre11.jar; do
            size=$(docker run --rm --entrypoint stat "$image_id" -c%s "${jdbc_plugin_dir}/${jar}" 2>/dev/null || echo "0")
            if [[ "$size" -gt 0 ]]; then
                echo "   ✅ $jar ($(( size / 1024 )) KB) in $jdbc_plugin_dir"
            else
                echo "   ❌ $jar MISSING from image"
            fi
        done
        for jar in kafka-connect-sqlserver-case-restorer-1.0.0.jar strip-null-bytes-smt.jar; do
            size=$(docker run --rm --entrypoint stat "$image_id" -c%s "${shared_java_dir}/${jar}" 2>/dev/null || echo "0")
            if [[ "$size" -gt 0 ]]; then
                echo "   ✅ $jar ($(( size / 1024 )) KB) in $shared_java_dir"
            else
                echo "   ❌ $jar MISSING from image"
            fi
        done
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
        echo "1. Proxy configuration:"
        echo "   HTTP_PROXY=${HTTP_PROXY:-<not set>}"
        echo "   HTTPS_PROXY=${HTTPS_PROXY:-<not set>}"
        echo "   NO_PROXY=${NO_PROXY:-<not set>}"

        echo ""
        echo "[ROOT CAUSE ANALYSIS]"
        if grep -q "confluent-hub" "$build_log"; then
            if grep -q "Failed to install" "$build_log" || grep -q "Could not connect" "$build_log"; then
                echo "❌ confluent-hub install failed — likely a network/proxy issue during Docker build"
                echo "   Confluent Hub requires outbound HTTPS to confluent-hub.com"
                echo "   Ensure HTTP_PROXY/HTTPS_PROXY in .env allow that destination"
            fi
        fi

        echo ""
        echo "[REMEDIATION STEPS]"
        echo "1. Verify proxy allows outbound HTTPS from Node 4 to confluent-hub.com:"
        echo "   curl -v --proxy \$HTTP_PROXY https://confluent-hub.com"
        echo ""
        echo "2. If proxy blocks Confluent Hub, pass proxy build args explicitly:"
        echo "   docker build --build-arg HTTP_PROXY=\$HTTP_PROXY --build-arg HTTPS_PROXY=\$HTTPS_PROXY ..."
        echo ""
        echo "3. After fixing, re-run:"
        echo "   ./scripts/4-build-connect.sh"
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
        bash ${DEPLOY_DIR}/scripts/4-build-connect.sh --local" 2>&1

    if [[ $? -eq 0 ]]; then
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

    # Dispatch to Node 4 — run full script with --local flag to get all diagnostics
    cmd_json=$(jq -cn --arg d "$DEPLOY_DIR" '{
  "commands": [
    ("set -e" +
     " && cd " + $d +
     " && source " + $d + "/.env" +
     " && export HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy=${HTTP_PROXY} https_proxy=${HTTPS_PROXY} no_proxy=${NO_PROXY}" +
     " && bash " + $d + "/scripts/4-build-connect.sh --local")
  ],
  "executionTimeout": ["600"]
}')

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
        echo ""
        echo "=== Build Output from Node 4 ==="
        aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --query 'StandardOutputContent' \
            --output text 2>/dev/null
    else
        echo "[ERROR] Build failed. Status: $status"
        echo ""
        echo "=== Build Output from Node 4 (stdout) ==="
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

    echo ""
    echo "Next: ./scripts/5-start-node.sh broker1"
fi

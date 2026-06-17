#!/bin/bash
# ============================================================
# Phase 2a: Deploy public repo to all EC2 nodes
# ============================================================
# Clones the public repo to all 5 EC2 nodes.
#
# Run BEFORE 2b-distribute-env.sh — repo directory must exist
# before .env can be copied into it.
#
# Usage (SSM mode — dispatches to all nodes from control machine):
#   ./scripts/2a-deploy-repo.sh
#
# Usage (SSH mode — run on each node after SSH-ing in):
#   ./scripts/2a-deploy-repo.sh --local
#
# Prerequisites:
#   1. .env file populated with:
#      - BROKER_1_IP, BROKER_2_IP, BROKER_3_IP
#      - CONNECT_1_IP, MONITOR_1_IP
#      - PUBLIC_REPO_URL
#      - DISPATCH_MODE (ssm or ssh)
#   2. SSM mode: AWS CLI configured, EC2 instances have SSM agent + IAM role
#   3. SSH mode: SSH into each node and run with --local
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
AWS_REGION=${AWS_REGION:-us-east-1}

# Verify .env exists
if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ ERROR: .env file not found at $ENV_FILE"
    echo "Run: cp .env.template .env, then fill in values"
    exit 1
fi

# Source .env to get node IPs and repo URL
source "$ENV_FILE"

DISPATCH_MODE="${DISPATCH_MODE:-ssm}"

# ---------------------------------------------------------------------------
# --local mode: clone repo on this node only (SSH mode — run per node)
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--local" ]]; then
    deploy_user="${DEPLOY_USER:-ec2-user}"
    deploy_dir="${DEPLOY_DIR:-/home/${deploy_user}/cdc-on-ec2-docker}"
    deploy_home="$(dirname "$deploy_dir")"
    repo_url="${PUBLIC_REPO_URL:-}"

    if [[ -z "$repo_url" ]]; then
        echo "❌ ERROR: PUBLIC_REPO_URL not set in .env"
        exit 1
    fi

    echo "[*] Phase 2a (local): Cloning repo on $(hostname)..."

    # Export proxy for git and dnf
    if [[ -n "${HTTP_PROXY:-}" ]]; then
        export HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy="${HTTP_PROXY}" https_proxy="${HTTPS_PROXY}" no_proxy="${NO_PROXY}"
    fi

    # Proxy diagnostics function
    diagnose_proxy_for_git() {
        echo ""
        echo "[PROXY DIAGNOSTICS FOR GIT CLONE]"

        if [[ -z "$HTTP_PROXY" ]]; then
            echo "   ℹ️  No proxy configured (direct internet access assumed)"
            return 0
        fi

        # Extract proxy host and port
        proxy_url="${HTTP_PROXY#*://}"
        proxy_host="${proxy_url%%:*}"
        proxy_port="${proxy_url##*:}"

        echo "   Proxy: $HTTP_PROXY"
        echo "   Target: $repo_url"
        echo ""

        # Test 1: TCP connection to proxy
        echo "   1. Testing TCP connection to proxy..."
        if timeout 5 bash -c "echo -n > /dev/tcp/$proxy_host/$proxy_port" 2>/dev/null; then
            echo "      ✅ Can reach proxy at $proxy_host:$proxy_port"
        else
            echo "      ❌ CANNOT reach proxy at $proxy_host:$proxy_port"
            echo "         Fix: Check network routing, security groups, firewall"
            return 1
        fi

        # Test 2: HTTPS CONNECT through proxy (required for git clone over HTTPS)
        echo ""
        echo "   2. Testing HTTPS CONNECT through proxy (for git)..."
        if timeout 10 curl -v --proxy "$HTTP_PROXY" --connect-timeout 5 https://github.com 2>&1 | grep -q "Connected to proxy"; then
            echo "      ✅ Proxy accepts HTTPS CONNECT tunneling"
        else
            # Try alternative test with curl head request
            local curl_test
            curl_test=$(timeout 10 curl -sI --proxy "$HTTP_PROXY" --connect-timeout 5 https://github.com 2>&1)
            if echo "$curl_test" | grep -qi "HTTP\|302\|301"; then
                echo "      ✅ Proxy allows HTTPS traffic to github.com"
            else
                echo "      ⚠️  Proxy may not support HTTPS CONNECT or is blocking github.com"
                echo "         Output: $(echo "$curl_test" | head -3 | tr '\n' ' ')"
                echo ""
                echo "         Common issues:"
                echo "         - Proxy doesn't support CONNECT tunneling (required for HTTPS)"
                echo "         - Proxy is blocking github.com explicitly"
                echo "         - Proxy requires authentication (not set in .env)"
                echo "         - Firewall between this node and proxy"
                return 1
            fi
        fi

        # Test 3: Test git clone over HTTP (fallback if HTTPS fails)
        echo ""
        echo "   3. Testing git connectivity..."
        local http_repo="${repo_url/https:\/\//http:\/\/}"
        if timeout 15 git ls-remote "$http_repo" HEAD > /dev/null 2>&1; then
            echo "      ✅ Git can reach repo (at least via HTTP)"
        else
            echo "      ⚠️  Git connectivity test inconclusive"
        fi

        echo ""
        return 0
    }

    # Run diagnostics before attempting clone
    diagnose_proxy_for_git || {
        echo ""
        echo "[REMEDIATION]"
        echo "Option 1: Configure proxy to allow HTTPS CONNECT (proxy admin task)"
        echo "Option 2: Use SSH-based git clone if available"
        echo "Option 3: Check proxy firewall rules for github.com"
        echo ""
        echo "Attempting clone anyway... (may fail)"
        echo ""
    }

    which git >/dev/null 2>&1 || dnf install -y git
    mkdir -p "$deploy_home"

    MAX_RETRIES=3
    attempt=0
    while [[ $attempt -lt $MAX_RETRIES ]]; do
        attempt=$((attempt + 1))
        [[ $attempt -gt 1 ]] && echo "[*] Retry $attempt/$MAX_RETRIES (tarball corruption detected)..."

        # Backup existing .env before wiping
        if [[ -f "$deploy_dir/.env" ]]; then
            env_backup="${deploy_home}/.env.$(date +%Y%m%d_%H%M%S)"
            cp "$deploy_dir/.env" "$env_backup"
            echo "   Backed up .env to $env_backup"
        fi

        rm -rf "$deploy_dir" 2>/dev/null || true
        ref_args=(); [[ -n "${PUBLIC_REPO_TAG:-}" ]] && ref_args=(--branch "$PUBLIC_REPO_TAG" --depth 1)

        if ! git clone "${ref_args[@]}" "$repo_url" "$deploy_dir"; then
            echo "[ERROR] Git clone failed on attempt $attempt"
            [[ $attempt -ge $MAX_RETRIES ]] && exit 1
            continue
        fi

        chown -R "${deploy_user}:${deploy_user}" "$deploy_dir"

        # Validate tarballs — proxy truncation produces a truncated file that passes
        # COPY but explodes in tar during docker build. Catch it here while we can retry.
        echo "[*] Validating tarballs..."
        tarball_ok=true
        for f in "$deploy_dir"/connect/debezium-libs/debezium-connector-*.tar.gz; do
            sz=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
            if tar -tzf "$f" > /dev/null 2>&1; then
                echo "   ✅ $(basename "$f") ($((sz / 1024 / 1024))M)"
            else
                echo "   ❌ $(basename "$f") ($((sz / 1024 / 1024))M) — corrupt, proxy likely truncated during clone"
                tarball_ok=false
            fi
        done

        if $tarball_ok; then
            break
        fi

        if [[ $attempt -ge $MAX_RETRIES ]]; then
            echo ""
            echo "[ERROR] Tarballs still corrupt after $MAX_RETRIES attempts"
            echo "   Root cause: proxy is truncating large binaries during git clone"
            echo "   Fix options:"
            echo "   1. Switch to SSH clone: set PUBLIC_REPO_URL=git@github.com:... in .env"
            echo "   2. Increase proxy timeout/buffer limits (proxy admin task)"
            exit 1
        fi
    done

    # Restore most recent .env backup
    latest_backup=$(ls -t "${deploy_home}"/.env.* 2>/dev/null | head -1)
    if [[ -n "$latest_backup" ]]; then
        cp "$latest_backup" "$deploy_dir/.env"
        echo "   Restored .env from $latest_backup"
    fi
    ls -lh "$deploy_dir/docker-compose.yml"
    echo "✅ Repo cloned to $deploy_dir"
    echo ""
    echo "Next: copy .env into $deploy_dir/.env (run 2b-distribute-env.sh from control machine, or scp manually)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Remote dispatch: deploy repo to all 5 nodes (SSH or SSM)
# ---------------------------------------------------------------------------
DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
DEPLOY_DIR="${DEPLOY_DIR:-/home/${DEPLOY_USER}/cdc-on-ec2-docker}"

NODE_NAMES=(broker1 broker2 broker3 connect monitor)

if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    SSH_KEY="${SSH_KEY_PATH:-}"
    if [[ -z "$SSH_KEY" || ! -f "$SSH_KEY" ]]; then
        echo "❌ SSH_KEY_PATH not set or key not found (required for DISPATCH_MODE=ssh)"
        exit 1
    fi
    NODE_ADDRS=("$BROKER_1_IP" "$BROKER_2_IP" "$BROKER_3_IP" "$CONNECT_1_IP" "$MONITOR_1_IP")
else
    for var in BROKER_1_INSTANCE_ID BROKER_2_INSTANCE_ID BROKER_3_INSTANCE_ID CONNECT_1_INSTANCE_ID MONITOR_1_INSTANCE_ID PUBLIC_REPO_URL; do
        if [[ -z "${!var}" ]]; then
            echo "❌ ERROR: $var is not set in .env"
            exit 1
        fi
    done
    NODE_ADDRS=("$BROKER_1_INSTANCE_ID" "$BROKER_2_INSTANCE_ID" "$BROKER_3_INSTANCE_ID" "$CONNECT_1_INSTANCE_ID" "$MONITOR_1_INSTANCE_ID")
fi

echo "[*] Phase 2a: Deploy public repo to all 5 EC2 nodes (${DISPATCH_MODE^^} mode)"
echo "   Repo URL: $PUBLIC_REPO_URL"
echo ""

deploy_to_node() {
    local node_name="$1"
    local node_addr="$2"
    local repo_url="$3"
    local validate_tarballs="${4:-false}"  # only true for connect node

    echo "🚀 Deploying to $node_name ($node_addr)..."

    if [[ "$DISPATCH_MODE" == "ssh" ]]; then
        # SSH: clone directly — repo doesn't exist on node yet, can't use --local
        local output
        output=$(ssh -i "$SSH_KEY" \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${DEPLOY_USER}@${node_addr}" "bash -s" <<REMOTE_EOF 2>&1
set -e
export HTTP_PROXY='${HTTP_PROXY:-}' HTTPS_PROXY='${HTTPS_PROXY:-}' NO_PROXY='${NO_PROXY:-}'
export http_proxy='${HTTP_PROXY:-}' https_proxy='${HTTPS_PROXY:-}' no_proxy='${NO_PROXY:-}'
which git >/dev/null 2>&1 || sudo dnf install -y git
deploy_home=\$(dirname ${DEPLOY_DIR})
if [[ -f "${DEPLOY_DIR}/.env" ]]; then
    env_backup="\${deploy_home}/.env.\$(date +%Y%m%d_%H%M%S)"
    cp "${DEPLOY_DIR}/.env" "\$env_backup"
    echo "   Backed up .env to \$env_backup"
fi
rm -rf ${DEPLOY_DIR} 2>/dev/null || true
ref_args=(); [[ -n "${PUBLIC_REPO_TAG:-}" ]] && ref_args=(--branch "${PUBLIC_REPO_TAG}" --depth 1)
git clone "${ref_args[@]}" ${repo_url} ${DEPLOY_DIR}
latest_backup=\$(ls -t "\${deploy_home}"/.env.* 2>/dev/null | head -1)
if [[ -n "\$latest_backup" ]]; then
    cp "\$latest_backup" "${DEPLOY_DIR}/.env"
    echo "   Restored .env from \$latest_backup"
fi
ls -lh ${DEPLOY_DIR}/docker-compose.yml
REMOTE_EOF
) && {
            echo "   ✅ $node_name deployment completed successfully"
            return 0
        } || {
            echo "   ❌ $node_name deployment FAILED"
            echo "$output" | tail -5 | sed 's/^/   /'
            return 1
        }
    else
        # SSM dispatch
        local proxy_cmd="true"
        if [[ -n "${HTTP_PROXY:-}" ]]; then
            proxy_cmd="export HTTP_PROXY='${HTTP_PROXY}' HTTPS_PROXY='${HTTPS_PROXY}' NO_PROXY='${NO_PROXY}' http_proxy='${HTTP_PROXY}' https_proxy='${HTTPS_PROXY}' no_proxy='${NO_PROXY}'"
        fi
        local cmd_json
        local ref_flag=""
        [[ -n "${PUBLIC_REPO_TAG:-}" ]] && ref_flag="--branch ${PUBLIC_REPO_TAG} --depth 1"

        local clone_cmd="git clone ${ref_flag:+$ref_flag }${repo_url} ${DEPLOY_DIR} 2>&1 || { echo '[ERROR] Git clone failed'; exit 1; }"

        # Tarball validation command (connect node only — empty string for others)
        local validate_cmd="echo '[*] Skipping tarball validation (not connect node)'"
        if [[ "$validate_tarballs" == "true" ]]; then
            validate_cmd="echo '[*] Validating tarballs...' && ok=true && for f in ${DEPLOY_DIR}/connect/debezium-libs/debezium-connector-*.tar.gz; do sz=\$(stat -c%s \"\$f\" 2>/dev/null || echo 0); if tar -tzf \"\$f\" > /dev/null 2>&1; then echo \"   OK \$(basename \$f) (\$((sz/1024/1024))M)\"; else echo \"   CORRUPT \$(basename \$f) (\$((sz/1024/1024))M) — proxy truncated during clone\"; ok=false; fi; done && \$ok || { echo '[ERROR] Tarball validation failed — re-run 2a-deploy-repo.sh to retry'; exit 1; }"
        fi

        cmd_json=$(jq -n \
            --arg proxy "$proxy_cmd" \
            --arg deploy_home "$(dirname "$DEPLOY_DIR")" \
            --arg repo "$repo_url" \
            --arg user "$DEPLOY_USER" \
            --arg dir "$DEPLOY_DIR" \
            --arg http_proxy "${HTTP_PROXY:-}" \
            --arg clone_cmd "$clone_cmd" \
            --arg validate_cmd "$validate_cmd" \
            '{commands: [
                $proxy,
                "if [[ -n \"\($http_proxy)\" ]]; then proxy_host=$(echo \($http_proxy) | cut -d: -f2 | tr -d /); proxy_port=$(echo \($http_proxy) | cut -d: -f3); echo \"   Testing proxy: $proxy_host:$proxy_port\"; timeout 5 bash -c \"echo -n > /dev/tcp/$proxy_host/$proxy_port\" && echo \"   Proxy reachable\" || echo \"   CANNOT reach proxy at $proxy_host:$proxy_port\"; else echo \"   No proxy configured\"; fi",
                "which git >/dev/null 2>&1 || dnf install -y git",
                ("mkdir -p " + $deploy_home),
                ("if [ -f " + $dir + "/.env ]; then cp " + $dir + "/.env " + $deploy_home + "/.env.$(date +%Y%m%d_%H%M%S) && echo Backed up .env; fi"),
                ("rm -rf " + $dir + " 2>/dev/null || true"),
                $clone_cmd,
                ("chown -R " + $user + ":" + $user + " " + $dir),
                ("latest=$(ls -t " + $deploy_home + "/.env.* 2>/dev/null | head -1) && [ -n \"$latest\" ] && cp \"$latest\" " + $dir + "/.env && echo Restored .env from $latest || true"),
                $validate_cmd,
                ("ls -lh " + $dir + "/docker-compose.yml")
            ]}'
        )

        local cmd_id
        cmd_id=$(aws ssm send-command \
            --region "$AWS_REGION" \
            --instance-ids "$node_addr" \
            --document-name "AWS-RunShellScript" \
            --parameters "$cmd_json" \
            --query 'Command.CommandId' \
            --output text 2>/dev/null)

        if [[ -z "$cmd_id" || "$cmd_id" == "None" ]]; then
            echo "   ❌ ERROR: Failed to send SSM command"
            return 1
        fi

        echo "   ⏱️  Command ID: $cmd_id (polling for completion...)"

        local timeout=300
        local elapsed=0
        local status="InProgress"

        while [[ "$status" == "InProgress" && $elapsed -lt $timeout ]]; do
            sleep 5
            elapsed=$((elapsed + 5))
            status=$(aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$node_addr" \
                --query 'Status' \
                --output text 2>/dev/null)
        done

        if [[ "$status" == "Success" ]]; then
            # Verify critical file was actually created (don't trust SSM status alone)
            local verify_output
            verify_output=$(aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$node_addr" \
                --query 'StandardOutputContent' \
                --output text 2>/dev/null)

            if echo "$verify_output" | grep -q "docker-compose.yml"; then
                echo "   ✅ $node_name deployment completed successfully"
                return 0
            else
                echo "   ❌ $node_name deployment FAILED (docker-compose.yml not found)"
                echo "   Last output: $(echo "$verify_output" | tail -3 | tr '\n' ' ')"
                return 1
            fi
        elif [[ "$status" == "Failed" ]]; then
            echo "   ❌ $node_name deployment FAILED"
            local stdout_output error_output
            stdout_output=$(aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$node_addr" \
                --query 'StandardOutputContent' \
                --output text 2>/dev/null)
            error_output=$(aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$node_addr" \
                --query 'StandardErrorContent' \
                --output text 2>/dev/null)

            # Check for proxy-related errors
            if echo "$error_output" | grep -qi "Failed to connect\|proxy\|443"; then
                echo "   [PROXY ERROR DETECTED]"
                echo "   Git failed to reach github.com via proxy"
                echo "   Error snippet: $(echo "$error_output" | grep -i "failed\|proxy" | head -1)"
                echo ""
                echo "   Diagnostics:"
                echo "   - Proxy reachability: $(echo "$stdout_output" | grep -E "✅|❌" | head -1)"
                echo "   - Check: proxy allows HTTPS CONNECT tunneling for git"
                echo "   - Check: firewall rules between node and proxy"
                echo "   - Check: proxy not blocking github.com"
            else
                [[ -n "$error_output" ]] && echo "   Error: $(echo "$error_output" | head -3 | tr '\n' ' ')"
            fi
            return 1
        else
            echo "   ⚠️  $node_name deployment status: $status (timeout after ${timeout}s)"
            return 1
        fi
    fi
}

failed=0
for i in "${!NODE_NAMES[@]}"; do
    # Only the connect node (index 3) needs the debezium tarballs validated
    validate="false"
    [[ "${NODE_NAMES[$i]}" == "connect" ]] && validate="true"
    if ! deploy_to_node "${NODE_NAMES[$i]}" "${NODE_ADDRS[$i]}" "$PUBLIC_REPO_URL" "$validate"; then
        failed=$((failed + 1))
    fi
done

echo ""

# ============================================================
# Post-Deployment Diagnostics
# ============================================================
if [[ $failed -eq 0 ]]; then
    echo "[*] Phase 2a diagnostics..."
    echo ""

    diag_failed=0

    # Check repo integrity on jumpbox
    echo "  📋 Repo integrity:"
    if [[ -d "$SCRIPT_DIR/.git" ]]; then
        echo "     ✅ .git directory present"
    else
        echo "     ❌ .git directory missing"
        diag_failed=$((diag_failed + 1))
    fi

    # Check critical files
    for f in docker-compose.yml .env.template scripts/3-setup-ec2.sh scripts/4-build-connect.sh; do
        if [[ -f "$SCRIPT_DIR/$f" ]]; then
            echo "     ✅ $f"
        else
            echo "     ❌ $f MISSING"
            diag_failed=$((diag_failed + 1))
        fi
    done

    # Check tarball integrity
    echo ""
    echo "  📦 Debezium tarballs:"
    for f in "$SCRIPT_DIR"/connect/debezium-libs/debezium-connector-*.tar.gz; do
        if [[ -f "$f" ]]; then
            if tar -tzf "$f" > /dev/null 2>&1; then
                sz=$(($(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null) / 1024 / 1024))
                echo "     ✅ $(basename $f) ($sz MB, valid gzip)"
            else
                echo "     ❌ $(basename $f) CORRUPTED (invalid gzip)"
                diag_failed=$((diag_failed + 1))
            fi
        else
            echo "     ❌ $(basename $f) MISSING"
            diag_failed=$((diag_failed + 1))
        fi
    done

    # Check case restorer JAR
    echo ""
    echo "  🔧 Pre-built JARs:"
    if [[ -f "$SCRIPT_DIR/connect/jars/kafka-connect-sqlserver-case-restorer-1.0.0.jar" ]]; then
        echo "     ✅ kafka-connect-sqlserver-case-restorer-1.0.0.jar"
    else
        echo "     ❌ kafka-connect-sqlserver-case-restorer-1.0.0.jar MISSING"
        diag_failed=$((diag_failed + 1))
    fi

    if [[ -f "$SCRIPT_DIR/connect/jars/mssql-jdbc-12.4.2.jre11.jar" ]]; then
        echo "     ✅ mssql-jdbc-12.4.2.jre11.jar"
    else
        echo "     ❌ mssql-jdbc-12.4.2.jre11.jar MISSING"
        diag_failed=$((diag_failed + 1))
    fi

    if [[ -f "$SCRIPT_DIR/connect/jars/strip-null-bytes-smt.jar" ]]; then
        echo "     ✅ strip-null-bytes-smt.jar"
    else
        echo "     ❌ strip-null-bytes-smt.jar MISSING"
        diag_failed=$((diag_failed + 1))
    fi

    echo ""
    if [[ $diag_failed -eq 0 ]]; then
        echo "  ✅ All diagnostics passed"
    else
        echo "  ⚠️  $diag_failed diagnostic(s) failed — fix above before Phase 2b"
        exit 1
    fi
fi

echo ""
if [[ $failed -eq 0 ]]; then
    echo "✅ All nodes deployed successfully"
else
    echo "⚠️  $failed node(s) failed deployment"
    exit 1
fi

echo ""
echo "Next: ./scripts/2b-distribute-env.sh"

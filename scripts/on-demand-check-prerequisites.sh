#!/bin/bash
# ============================================================
# Check that all required files and directories exist
# ============================================================
# Run before deployment to catch missing files early.
#
# Usage: ./scripts/on-demand-check-prerequisites.sh
# ============================================================

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

echo ""
echo "🔍 Checking prerequisites..."
echo ""

MISSING=0

# Check critical directories
DIRS=(
    "connect"
    "connectors"
    "monitoring"
    "monitoring/jmx-exporter"
    "monitoring/grafana"
    "monitoring/prometheus"
    "scripts"
)

echo "📁 Directories:"
for dir in "${DIRS[@]}"; do
    if [[ -d "$dir" ]]; then
        echo "  ✅ $dir"
    else
        echo "  ❌ Missing: $dir"
        ((MISSING++))
    fi
done

echo ""
echo "📄 Files:"

# Check critical files
FILES=(
    "connect/Dockerfile"
    "docker-compose.yml"
    "docker-compose.broker1.yml"
    "docker-compose.broker2.yml"
    "docker-compose.broker3.yml"
    "docker-compose.connect-schema-registry.yml"
    "docker-compose.ksqldb-monitoring.yml"
    "docker-compose.connect-build.yml"
    "connectors/debezium-sqlserver-source.json"
    "connectors/jdbc-sink-aurora.json"
    "connectors/debezium-postgres-source.json"
    "connectors/jdbc-sink-sqlserver.json"
    "connectors/deploy-all-connectors.py"
    "connectors/deploy-all-connectors.sh"
    ".env.template"
    "README.md"
)

for file in "${FILES[@]}"; do
    if [[ -f "$file" ]]; then
        echo "  ✅ $file"
    else
        echo "  ❌ Missing: $file"
        ((MISSING++))
    fi
done

echo ""
echo "🔧 Scripts:"

SCRIPTS=(
    "scripts/0-preflight.sh"
    "scripts/1-validate-env.sh"
    "scripts/2a-deploy-repo.sh"
    "scripts/2b-distribute-env.sh"
    "scripts/3-setup-ec2.sh"
    "scripts/4-build-connect.sh"
    "scripts/5-start-node.sh"
    "scripts/6-deploy-connectors.sh"
    "scripts/7-validate-poc.sh"
    "scripts/on-demand-check-prerequisites.sh"
    "scripts/on-demand-switch-profile.sh"
    "scripts/ops-health-check.sh"
    "scripts/ops-node-status-ssm.sh"
    "scripts/ops-stop-node.sh"
    "scripts/teardown-reset-all-nodes.sh"
)

for script in "${SCRIPTS[@]}"; do
    if [[ -f "$script" && -x "$script" ]]; then
        echo "  ✅ $script (executable)"
    elif [[ -f "$script" ]]; then
        echo "  ⚠️  $script (not executable - run: chmod +x $script)"
    else
        echo "  ❌ Missing: $script"
        ((MISSING++))
    fi
done

echo ""
echo "📦 Optional:"

# JDBC driver (optional warning)
if [[ -f "connect/jars/mssql-jdbc-12.4.2.jre11.jar" ]]; then
    echo "  ✅ SQL Server JDBC driver found (1.4 MB)"
else
    echo "  ⚠️  SQL Server JDBC driver not found"
    echo "      Location: connect/jars/mssql-jdbc-12.4.2.jre11.jar"
    echo "      Download: https://github.com/microsoft/mssql-jdbc/releases"
    echo "      Version: 12.4.2 (compatible with CP 8.x)"
fi

if [[ -f "monitoring/jmx-exporter/jmx_prometheus_javaagent.jar" ]]; then
    echo "  ✅ JMX exporter JAR found"
else
    echo "  ⚠️  JMX exporter JAR not found (optional - monitoring only)"
fi

echo ""

if [[ $MISSING -gt 0 ]]; then
    echo "❌ ERROR: $MISSING critical files/directories missing"
    exit 1
else
    echo "✅ All prerequisites present"
    echo ""
    echo "Next: ./scripts/1-validate-env.sh"
    exit 0
fi

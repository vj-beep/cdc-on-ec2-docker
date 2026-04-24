#!/usr/bin/env bash
# Downloads the JMX Prometheus Java Agent JAR into this directory.
# Run once per node before starting Docker Compose.
set -euo pipefail

VERSION="1.0.1"
JAR="jmx_prometheus_javaagent.jar"
URL="https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${VERSION}/jmx_prometheus_javaagent-${VERSION}.jar"

cd "$(dirname "$0")"

# Source proxy env vars from .env if not already set (supports standalone execution)
REPO_ENV="$(dirname "$0")/../../.env"
if [[ -z "${HTTP_PROXY:-}" && -f "$REPO_ENV" ]]; then
    _P=$(grep "^HTTP_PROXY=" "$REPO_ENV" | cut -d= -f2- || true)
    if [[ -n "$_P" ]]; then
        export HTTP_PROXY="$_P" http_proxy="$_P"
        export HTTPS_PROXY=$(grep "^HTTPS_PROXY=" "$REPO_ENV" | cut -d= -f2- || true)
        export https_proxy="${HTTPS_PROXY}"
        export NO_PROXY=$(grep "^NO_PROXY=" "$REPO_ENV" | cut -d= -f2- || true)
        export no_proxy="${NO_PROXY}"
    fi
fi

if [ -f "$JAR" ]; then
    echo "JMX exporter JAR already exists: $JAR"
    exit 0
fi

echo "Downloading JMX Prometheus Java Agent ${VERSION}..."
curl -sSL -o "$JAR" "$URL"
echo "Downloaded: $JAR"

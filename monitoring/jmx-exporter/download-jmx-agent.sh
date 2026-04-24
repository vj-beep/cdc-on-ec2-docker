#!/usr/bin/env bash
# Downloads the JMX Prometheus Java Agent JAR into this directory.
# Run once per node before starting Docker Compose.
set -euo pipefail

VERSION="1.0.1"
JAR="jmx_prometheus_javaagent.jar"
URL="https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/${VERSION}/jmx_prometheus_javaagent-${VERSION}.jar"

cd "$(dirname "$0")"

if [ -f "$JAR" ]; then
    echo "JMX exporter JAR already exists: $JAR"
    exit 0
fi

echo "Downloading JMX Prometheus Java Agent ${VERSION}..."
curl -sSL -o "$JAR" "$URL"
echo "Downloaded: $JAR"

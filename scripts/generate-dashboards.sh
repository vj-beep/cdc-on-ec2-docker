#!/bin/bash
# Generate Grafana dashboards from templates, substituting configuration values
# This script reads .env, extracts key CDC config, and generates dashboard JSON

set -e

DASHBOARDS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../monitoring/grafana/dashboards" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$(dirname "$SCRIPT_DIR")"

if [ ! -f .env ]; then
  echo "Error: .env not found. Must run from cdc-on-ec2-docker root."
  exit 1
fi

# Source .env and extract key variables only (skip comments)
eval "$(grep -E '^[A-Z_][A-Z0-9_]*=' .env | grep -v '^#')"

echo "Generating Grafana dashboards from templates..."
echo "  SQLSERVER_TABLE_INCLUDE_LIST: $SQLSERVER_TABLE_INCLUDE_LIST"
echo "  AURORA_TABLE_INCLUDE_LIST: $AURORA_TABLE_INCLUDE_LIST"

for template in "$DASHBOARDS_DIR"/*.json.template; do
  dashboard="${template%.template}"
  dashboard_name=$(basename "$dashboard")

  echo "Processing: $dashboard_name"

  # Use Python to safely substitute env vars in JSON strings
  python3 << 'EOF' "$template" "$dashboard" "$SQLSERVER_TABLE_INCLUDE_LIST" "$AURORA_TABLE_INCLUDE_LIST" "$JDBC_SINK_AURORA_TOPICS_REGEX" "$JDBC_SINK_SQLSERVER_TOPIC_REGEX"
import sys
import json
import re

template_file = sys.argv[1]
output_file = sys.argv[2]
sqlserver_tables = sys.argv[3]
aurora_tables = sys.argv[4]
aurora_sink_regex = sys.argv[5]
sqlserver_sink_regex = sys.argv[6]

with open(template_file) as f:
    content = f.read()

# First pass: substitute markdown content in text panels
# Replace ${VAR} in "content" fields with actual values (safely)
content = content.replace('${SQLSERVER_TABLE_INCLUDE_LIST}', sqlserver_tables)
content = content.replace('${AURORA_TABLE_INCLUDE_LIST}', aurora_tables)

# For regex patterns, escape them properly for JSON
aurora_sink_regex_escaped = aurora_sink_regex.replace('\\', '\\\\').replace('"', '\\"')
sqlserver_sink_regex_escaped = sqlserver_sink_regex.replace('\\', '\\\\').replace('"', '\\"')

content = content.replace('${JDBC_SINK_AURORA_TOPICS_REGEX}', aurora_sink_regex_escaped)
content = content.replace('${JDBC_SINK_SQLSERVER_TOPIC_REGEX}', sqlserver_sink_regex_escaped)

# Validate JSON
try:
    json.loads(content)
except json.JSONDecodeError as e:
    print(f"ERROR: Generated invalid JSON: {e}", file=sys.stderr)
    sys.exit(1)

with open(output_file, 'w') as f:
    f.write(content)

print(f"  Generated: {output_file}")
EOF
done

echo "Done. Dashboards ready for Grafana."

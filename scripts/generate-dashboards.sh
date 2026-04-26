#!/bin/bash
# Generate Grafana dashboards from templates using envsubst
# Processes .json.template files to substitute ${VAR} placeholders

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DASHBOARDS_DIR="$ROOT_DIR/monitoring/grafana/dashboards"

cd "$ROOT_DIR"

if [ ! -f .env ]; then
  echo "Error: .env not found at $ROOT_DIR/.env"
  exit 1
fi

echo "Generating Grafana dashboards from templates..."

# Load env vars and export them for envsubst
set -a
eval "$(grep -E '^[A-Z_][A-Z0-9_]*=' .env)"
set +a

for template in "$DASHBOARDS_DIR"/*.json.template; do
  dashboard="${template%.template}"
  dashboard_name=$(basename "$dashboard")

  echo "Processing: $dashboard_name"
  envsubst < "$template" > "$dashboard" 2>/dev/null || {
    echo "ERROR: Failed to process $dashboard_name"
    exit 1
  }
done

echo "Done. Dashboards ready for Grafana."

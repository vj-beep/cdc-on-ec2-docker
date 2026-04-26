#!/bin/bash
# Generate Grafana dashboards from templates using envsubst
# Processes .json.template files to substitute ${VAR} placeholders with .env values

set -e

DASHBOARDS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../monitoring/grafana/dashboards" && pwd)"

if [ ! -f .env ]; then
  echo "Error: .env not found. Must run from cdc-on-ec2-docker root directory."
  exit 1
fi

source .env

echo "Generating Grafana dashboards from templates..."

for template in "$DASHBOARDS_DIR"/*.json.template; do
  dashboard="${template%.template}"
  echo "Processing: $template → $dashboard"
  envsubst < "$template" > "$dashboard"
done

echo "Done. Dashboards ready for Grafana provisioning."

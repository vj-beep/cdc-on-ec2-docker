#!/bin/sh
# profile-exporter.sh
#
# Writes a Prometheus textfile collector metric indicating the active CDC tuning profile.
# Runs on Node 5 only (monitor node); harmless no-op on broker/connect nodes where .env
# may not be mounted.
#
# Metric: cdc_tuning_mode
#   1 = streaming (schema_only or no_data snapshot mode)
#   0 = snapshot  (initial snapshot mode)
#
# Output file is picked up by node-exporter's textfile collector
# (mounted at /textfile inside this container).

TEXTFILE=/textfile/cdc_tuning_mode.prom
ENV_FILE=/app/.env

while true; do
    if [ -f "$ENV_FILE" ]; then
        mode=$(grep -E '^DEBEZIUM_SNAPSHOT_MODE=' "$ENV_FILE" \
               | cut -d= -f2 \
               | tr -d "'" \
               | tr -d '"' \
               | tr -d ' ')
        case "$mode" in
            schema_only|no_data|never)
                value=1
                label="streaming"
                ;;
            *)
                value=0
                label="snapshot"
                ;;
        esac
    else
        # .env not mounted — emit 0 with unknown label
        value=0
        label="unknown"
    fi

    {
        printf '# HELP cdc_tuning_mode Active CDC tuning profile (1=streaming, 0=snapshot)\n'
        printf '# TYPE cdc_tuning_mode gauge\n'
        printf 'cdc_tuning_mode{profile="%s"} %s\n' "$label" "$value"
    } > "$TEXTFILE.tmp" && mv "$TEXTFILE.tmp" "$TEXTFILE"

    sleep 15
done

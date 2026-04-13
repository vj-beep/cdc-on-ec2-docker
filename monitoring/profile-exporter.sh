#!/bin/sh
# profile-exporter.sh
#
# Writes a Prometheus textfile collector metric indicating the active CDC tuning profile.
# Runs on Node 5 only (monitor node); harmless no-op on broker/connect nodes where .env
# may not be mounted.
#
# Metric: cdc_tuning_mode
#   1 = streaming (CONNECT_CONSUMER_FETCH_MIN_BYTES=1)
#   0 = snapshot  (CONNECT_CONSUMER_FETCH_MIN_BYTES=anything else, e.g. 1048576)
#
# Uses CONNECT_CONSUMER_FETCH_MIN_BYTES as the tuning indicator because it is
# the single most impactful latency setting: snapshot profile holds fetches
# until 1 MB accumulates (~500 ms wait); streaming profile returns immediately
# on 1 byte. DEBEZIUM_SNAPSHOT_MODE is intentionally ignored — it stays
# "initial" for fresh deployments even when all tuning values are streaming.
#
# Output file is picked up by node-exporter's textfile collector
# (mounted at /textfile inside this container).

TEXTFILE=/textfile/cdc_tuning_mode.prom
ENV_FILE=/app/.env

while true; do
    if [ -f "$ENV_FILE" ]; then
        fetch_min=$(grep -E '^CONNECT_CONSUMER_FETCH_MIN_BYTES=' "$ENV_FILE" \
                    | cut -d= -f2 \
                    | tr -d "'" \
                    | tr -d '"' \
                    | tr -d ' ')
        case "$fetch_min" in
            1)
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

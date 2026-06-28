#!/usr/bin/env bash
set -Eeuo pipefail

KAFKA_BOOTSTRAP_SERVER="${KAFKA_BOOTSTRAP_SERVER:-kafka:19092}"
KAFKA_TOPIC="${KAFKA_TOPIC:-urban.telemetry}"
LIVE_INTERVAL_SECONDS="${LIVE_INTERVAL_SECONDS:-60}"
LIVE_DATA_DIR="${LIVE_DATA_DIR:-/dataset/live}"

if [[ ! "$LIVE_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || (( LIVE_INTERVAL_SECONDS < 1 )); then
    echo "ERROR: LIVE_INTERVAL_SECONDS must be a positive integer." >&2
    exit 2
fi

for minute in 00 15 30 45; do
    path="$LIVE_DATA_DIR/batch_${minute}.lp"
    [[ -f "$path" ]] || {
        echo "ERROR: missing live template: $path" >&2
        exit 1
    }
done

point_count="$(awk 'NF && $1 !~ /^#/ {count++} END {print count + 0}' "$LIVE_DATA_DIR/batch_00.lp")"
last_sample_epoch=-1

shutdown() {
    echo "Continuous live producer stopped."
    exit 0
}
trap shutdown INT TERM

echo "Continuous live producer started."
echo "Kafka topic: $KAFKA_TOPIC"
echo "Interval: ${LIVE_INTERVAL_SECONDS}s"
echo "Points per sample: $point_count"

while true; do
    now_epoch="$(date -u +%s)"
    sample_epoch=$((now_epoch / LIVE_INTERVAL_SECONDS * LIVE_INTERVAL_SECONDS))

    if (( sample_epoch != last_sample_epoch )); then
        minute="$(date -u -d "@$sample_epoch" +%M)"
        template_minute=$((10#$minute / 15 * 15))
        printf -v template_suffix '%02d' "$template_minute"
        template="$LIVE_DATA_DIR/batch_${template_suffix}.lp"
        timestamp_ns=$((sample_epoch * 1000000000))

        awk -v ts="$timestamp_ns" 'NF && $1 !~ /^#/ {print $0 " " ts}' "$template" \
            | /opt/kafka/bin/kafka-console-producer.sh \
                --bootstrap-server "$KAFKA_BOOTSTRAP_SERVER" \
                --topic "$KAFKA_TOPIC" >/dev/null

        echo "Published $point_count sensor points at $(date -u -d "@$sample_epoch" +%FT%TZ) using batch_${template_suffix}.lp"
        last_sample_epoch="$sample_epoch"
    fi

    next_epoch=$((sample_epoch + LIVE_INTERVAL_SECONDS))
    sleep_seconds=$((next_epoch - $(date -u +%s)))
    (( sleep_seconds > 0 )) || sleep_seconds=1
    sleep "$sleep_seconds" &
    wait $!
done

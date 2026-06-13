#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
DELAY="${DELAY_SECONDS:-2}"
if [[ "${1:-}" == "--delay" ]]; then DELAY="${2:?Missing seconds}"; fi
for minute in 00 15 30 45; do
  [[ -f "data/dataset/live/batch_${minute}.lp" ]] || { echo "Missing live batch $minute" >&2; exit 1; }
done
# Start of the last fully completed UTC hour.
now_epoch=$(date -u +%s)
base_epoch=$(( (now_epoch / 3600) * 3600 - 3600 ))
for minute in 00 15 30 45; do
  offset=$((10#$minute * 60))
  ts_ns=$(( (base_epoch + offset) * 1000000000 ))
  echo "Publishing batch $minute with logical timestamp $(date -u -d "@$((base_epoch + offset))" +%FT%TZ)..."
  awk -v ts="$ts_ns" 'NF && $1 !~ /^#/ {print $0 " " ts}' "data/dataset/live/batch_${minute}.lp" \
    | docker compose exec -T kafka /opt/kafka/bin/kafka-console-producer.sh \
        --bootstrap-server kafka:19092 --topic urban.telemetry >/dev/null
  sleep "$DELAY"
done
echo "Replay completed. Telegraf will ingest the raw points; the InfluxDB Tasks will derive hourly data and alerts."

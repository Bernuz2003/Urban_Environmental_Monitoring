#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ -f .env ]] || { echo "Create .env first." >&2; exit 1; }
set -a; source .env; set +a
: "${INFLUX_ORG:?}"; : "${INFLUX_TOKEN:?}"
echo "Deriving historical alerts from urban_hourly..."
docker compose exec -T influxdb influx query \
  --host http://localhost:8086 --org "$INFLUX_ORG" --token "$INFLUX_TOKEN" \
  --file /workspace/influx/backfill_alerts.flux >/dev/null
echo "Historical urban_alerts backfill completed."

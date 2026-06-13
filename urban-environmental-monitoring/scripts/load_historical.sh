#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

[[ -f .env ]] || {
    echo "ERROR: create .env from .env.example first." >&2
    exit 1
}

# The script is executed by Bash even when the interactive shell is Fish.
set -a
source .env
set +a

: "${INFLUX_ORG:?Missing INFLUX_ORG}"
: "${INFLUX_TOKEN:?Missing INFLUX_TOKEN}"

BATCH_SIZE="${BATCH_SIZE:-5000}"
INFLUX_LINE_PROTOCOL_PRECISION="${INFLUX_LINE_PROTOCOL_PRECISION:-us}"

case "$INFLUX_LINE_PROTOCOL_PRECISION" in
    s|ms|us|ns) ;;
    *)
        echo "ERROR: unsupported InfluxDB precision: $INFLUX_LINE_PROTOCOL_PRECISION" >&2
        echo "Allowed values: s, ms, us, ns" >&2
        exit 1
        ;;
esac

format_duration() {
    local seconds="$1"

    printf '%02dh:%02dm:%02ds' \
        $((seconds / 3600)) \
        $(((seconds % 3600) / 60)) \
        $((seconds % 60))
}

validate_timestamp_precision() {
    local path="$1"
    local first_timestamp
    local digits
    local expected_digits

    local first_line

    # Read one complete line without a pipeline that can fail with SIGPIPE
    # under `set -o pipefail`.
    IFS= read -r first_line < <(gzip -cd "$path")
    first_timestamp="${first_line##* }"

    [[ "$first_timestamp" =~ ^[0-9]+$ ]] || {
        echo "ERROR: invalid Line Protocol timestamp in $path: $first_timestamp" >&2
        exit 1
    }

    digits="${#first_timestamp}"

    case "$INFLUX_LINE_PROTOCOL_PRECISION" in
        s)  expected_digits=10 ;;
        ms) expected_digits=13 ;;
        us) expected_digits=16 ;;
        ns) expected_digits=19 ;;
    esac

    if (( digits != expected_digits )); then
        echo "ERROR: timestamp precision mismatch for $path" >&2
        echo "  configured precision: $INFLUX_LINE_PROTOCOL_PRECISION" >&2
        echo "  first timestamp:      $first_timestamp" >&2
        echo "  observed digits:      $digits" >&2
        echo "  expected digits:      $expected_digits" >&2
        exit 1
    fi
}

load_dataset() {
    local bucket="$1"
    local filename="$2"
    local path="data/dataset/influx/$filename"

    [[ -f "$path" ]] || {
        echo "ERROR: missing dataset file: $path" >&2
        exit 1
    }

    validate_timestamp_precision "$path"

    local total_points
    local total_batches
    local loaded_points=0
    local completed_batches=0
    local started_at
    local elapsed
    local percentage
    local rate
    local eta
    local batch=()

    echo
    echo "Counting points in $filename..."

    total_points="$(gzip -cd "$path" | wc -l | tr -d '[:space:]')"
    total_batches=$(((total_points + BATCH_SIZE - 1) / BATCH_SIZE))

    echo "============================================================"
    echo "Bucket:              $bucket"
    echo "File:                $path"
    echo "Compressed size:     $(du -h "$path" | cut -f1)"
    echo "Timestamp precision: $INFLUX_LINE_PROTOCOL_PRECISION"
    echo "Total points:        $total_points"
    echo "Batch size:          $BATCH_SIZE"
    echo "Total batches:       $total_batches"
    echo "Started at:          $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "============================================================"

    started_at="$(date +%s)"

    exec 3< <(gzip -cd "$path")

    while true; do
        batch=()
        mapfile -t -n "$BATCH_SIZE" batch <&3 || true

        if (( ${#batch[@]} == 0 )); then
            break
        fi

        printf '%s\n' "${batch[@]}" |
            docker compose exec -T influxdb influx write \
                --host http://localhost:8086 \
                --org "$INFLUX_ORG" \
                --token "$INFLUX_TOKEN" \
                --bucket "$bucket" \
                --format lp \
                --precision "$INFLUX_LINE_PROTOCOL_PRECISION"

        completed_batches=$((completed_batches + 1))
        loaded_points=$((loaded_points + ${#batch[@]}))
        percentage=$((loaded_points * 100 / total_points))
        elapsed=$(($(date +%s) - started_at))

        if (( elapsed > 0 )); then
            rate=$((loaded_points / elapsed))
            if (( rate > 0 )); then
                eta=$(((total_points - loaded_points) / rate))
            else
                eta=0
            fi
        else
            rate=0
            eta=0
        fi

        printf '\r[%3d%%] %-14s %9d/%-9d points | batch %d/%d | %d pt/s | elapsed %s | ETA %s' \
            "$percentage" \
            "$bucket" \
            "$loaded_points" \
            "$total_points" \
            "$completed_batches" \
            "$total_batches" \
            "$rate" \
            "$(format_duration "$elapsed")" \
            "$(format_duration "$eta")"
    done

    exec 3<&-
    elapsed=$(($(date +%s) - started_at))

    echo
    echo "Loaded $bucket successfully."
    echo "Points written: $loaded_points"
    echo "Elapsed time:   $(format_duration "$elapsed")"
}

echo "InfluxDB historical import"
echo "Organization:        $INFLUX_ORG"
echo "Timestamp precision: $INFLUX_LINE_PROTOCOL_PRECISION"
echo "Batch size:          $BATCH_SIZE points"

load_dataset "urban_raw" "urban_raw.lp.gz"
load_dataset "urban_hourly" "urban_hourly.lp.gz"
load_dataset "urban_daily" "urban_daily.lp.gz"

echo
echo "============================================================"
echo "Historical import completed successfully."
echo "Finished at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "============================================================"

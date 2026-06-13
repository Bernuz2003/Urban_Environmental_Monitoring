#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

info() { printf '\n==> %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
skip() { printf 'SKIP: %s\n' "$*"; }

load_env_if_present() {
    if [[ ! -f .env ]]; then
        warn ".env not found"
        printf 'Create it with: cp .env.example .env\n'
        return 1
    fi

    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
    return 0
}

docker_ready() {
    command -v docker >/dev/null 2>&1 || {
        warn "docker command not found"
        return 1
    }

    docker compose version >/dev/null 2>&1 || {
        warn "docker compose is not available"
        return 1
    }

    docker info >/dev/null 2>&1 || {
        warn "Docker daemon is not running or is not reachable"
        return 1
    }
}

service_running() {
    local id
    id="$(docker compose ps -q "$1" 2>/dev/null || true)"
    [[ -n "$id" ]] || return 1
    [[ "$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null || true)" == "running" ]]
}

influx_config_ready() {
    [[ -n "${INFLUX_ORG:-}" && -n "${INFLUX_TOKEN:-}" && "${INFLUX_TOKEN:-}" != PASTE_* ]]
}

influx_exec() {
    docker compose exec -T influxdb influx "$@"
}

print_docker_services() {
    info "Docker services"
    docker compose ps || true
}

print_postgres_status() {
    info "PostgreSQL context"
    if ! service_running postgres; then
        skip "postgres is not running"
        return
    fi

    if [[ -z "${POSTGRES_USER:-}" || -z "${POSTGRES_DB:-}" ]]; then
        skip "POSTGRES_USER or POSTGRES_DB missing in .env"
        return
    fi

    docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /dev/stdin < postgres/checks/context.sql || true
}

print_influx_setup() {
    info "InfluxDB buckets"
    if ! service_running influxdb; then
        skip "influxdb is not running"
        return
    fi

    if ! influx_config_ready; then
        skip "INFLUX_ORG or INFLUX_TOKEN is not configured"
        return
    fi

    influx_exec bucket list \
        --host http://localhost:8086 \
        --org "$INFLUX_ORG" \
        --token "$INFLUX_TOKEN" || true

    info "InfluxDB Tasks"
    influx_exec task list \
        --host http://localhost:8086 \
        --org "$INFLUX_ORG" \
        --token "$INFLUX_TOKEN" || true
}

print_count_query() {
    local label="$1"
    local query="$2"

    printf '\n%s\n' "$label"
    influx_exec query \
        --host http://localhost:8086 \
        --org "$INFLUX_ORG" \
        --token "$INFLUX_TOKEN" \
        "$query" || true
}

print_influx_counts() {
    info "InfluxDB counts"
    if ! service_running influxdb; then
        skip "influxdb is not running"
        return
    fi

    if ! influx_config_ready; then
        skip "INFLUX_ORG or INFLUX_TOKEN is not configured"
        return
    fi

    print_count_query "urban_raw points" \
        'from(bucket: "urban_raw") |> range(start: 0) |> filter(fn: (r) => r._measurement == "urban_telemetry") |> count() |> group() |> sum(column: "_value") |> keep(columns: ["_value"])'
    print_count_query "urban_hourly points" \
        'from(bucket: "urban_hourly") |> range(start: 0) |> filter(fn: (r) => r._measurement == "urban_telemetry") |> count() |> group() |> sum(column: "_value") |> keep(columns: ["_value"])'
    print_count_query "urban_daily points" \
        'from(bucket: "urban_daily") |> range(start: 0) |> filter(fn: (r) => r._measurement == "urban_telemetry") |> count() |> group() |> sum(column: "_value") |> keep(columns: ["_value"])'
    print_count_query "urban_alerts severity points" \
        'from(bucket: "urban_alerts") |> range(start: 0) |> filter(fn: (r) => r._measurement == "urban_alerts" and r._field == "severity_level") |> count() |> group() |> sum(column: "_value") |> keep(columns: ["_value"])'
}

print_kafka_status() {
    info "Kafka topic"
    if ! service_running kafka; then
        skip "kafka is not running"
        return
    fi

    docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server kafka:19092 \
        --describe \
        --topic urban.telemetry || true

    info "Kafka offsets"
    docker compose exec -T kafka /opt/kafka/bin/kafka-get-offsets.sh \
        --bootstrap-server kafka:19092 \
        --topic urban.telemetry || true

    info "Kafka consumer group urban-telegraf"
    docker compose exec -T kafka /opt/kafka/bin/kafka-consumer-groups.sh \
        --bootstrap-server kafka:19092 \
        --describe \
        --group urban-telegraf || true
}

print_telegraf_logs() {
    info "Recent Telegraf logs"
    if ! service_running telegraf; then
        skip "telegraf is not running"
        return
    fi

    docker compose logs --tail=30 telegraf || true
}

load_env_if_present || exit 0
docker_ready || exit 0

print_docker_services
print_postgres_status
print_influx_setup
print_influx_counts
print_kafka_status
print_telegraf_logs

ok "status completed"

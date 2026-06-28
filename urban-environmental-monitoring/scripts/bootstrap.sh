#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-}"
if (( $# > 0 )); then
    shift
fi

info() { printf '\n==> %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
next() { printf 'NEXT: %s\n' "$*"; }

usage() {
    cat <<'EOF'
Usage:
  ./scripts/bootstrap.sh core
  ./scripts/bootstrap.sh data
  ./scripts/bootstrap.sh live [--no-producer]

The script is checkpoint-based. Missing manual setup is reported as a next step
instead of being treated as a fatal error.
EOF
}

ensure_env_file() {
    if [[ -f .env ]]; then
        ok ".env found"
        return 0
    fi

    warn ".env not found"
    next "copy .env.example to .env and review the values"
    printf '      cp .env.example .env\n'
    return 1
}

load_env() {
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
}

check_required_env() {
    local missing=()
    local name

    for name in "$@"; do
        if [[ -z "${!name:-}" ]]; then
            missing+=("$name")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        warn "missing values in .env: ${missing[*]}"
        next "complete .env and rerun this checkpoint"
        return 1
    fi

    ok ".env contains required values"
}

token_ready() {
    if [[ -z "${INFLUX_TOKEN:-}" || "${INFLUX_TOKEN:-}" == PASTE_* ]]; then
        warn "INFLUX_TOKEN is not configured yet"
        next "complete the InfluxDB UI setup, then paste the operator token in .env"
        return 1
    fi

    return 0
}

dataset_instructions() {
    cat <<'EOF'
Generate and install the dataset before starting a fresh runtime:

  cd ../urban-environmental-data-generator
  make generate
  cd ../urban-environmental-monitoring
  ./scripts/install_dataset.sh ../urban-environmental-data-generator/output/urban-environmental-dataset
EOF
}

check_dataset() {
    local missing=()
    local path
    local required_paths=(
        "data/dataset/manifest.json"
        "data/dataset/checksums.sha256"
        "data/dataset/postgres/grid_context.csv"
        "data/dataset/postgres/sensor_context.csv"
        "data/dataset/postgres/threshold_profile.csv"
        "data/dataset/influx/urban_raw.lp.gz"
        "data/dataset/influx/urban_hourly.lp.gz"
        "data/dataset/influx/urban_daily.lp.gz"
        "data/dataset/live/batch_00.lp"
        "data/dataset/live/batch_15.lp"
        "data/dataset/live/batch_30.lp"
        "data/dataset/live/batch_45.lp"
    )

    for path in "${required_paths[@]}"; do
        [[ -e "$path" ]] || missing+=("$path")
    done

    if (( ${#missing[@]} > 0 )); then
        warn "dataset is not installed or is incomplete"
        printf 'Missing paths:\n'
        printf '  - %s\n' "${missing[@]}"
        dataset_instructions
        return 1
    fi

    if ! (cd data/dataset && sha256sum -c checksums.sha256 >/dev/null); then
        warn "dataset checksum verification failed"
        dataset_instructions
        return 1
    fi

    ok "dataset installed and checksums valid"
}

docker_ready() {
    if ! command -v docker >/dev/null 2>&1; then
        warn "docker command not found"
        next "install Docker and rerun this checkpoint"
        return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        warn "docker compose is not available"
        next "install Docker Compose v2 and rerun this checkpoint"
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then
        warn "Docker daemon is not running or is not reachable"
        next "start Docker and rerun this checkpoint"
        return 1
    fi

    ok "Docker is available"
}

service_container_id() {
    docker compose ps -q "$1" 2>/dev/null || true
}

service_status() {
    local id="$1"
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || true
}

wait_for_service() {
    local service="$1"
    local timeout="${2:-120}"
    local started_at
    local id
    local status

    info "Waiting for $service"
    started_at="$(date +%s)"

    while true; do
        id="$(service_container_id "$service")"
        if [[ -n "$id" ]]; then
            status="$(service_status "$id")"
            if [[ "$status" == "healthy" || "$status" == "running" ]]; then
                ok "$service is $status"
                return 0
            fi

            if [[ "$status" == "unhealthy" || "$status" == "exited" ]]; then
                warn "$service is $status"
                docker compose logs --tail=40 "$service" || true
                return 1
            fi
        fi

        if (( $(date +%s) - started_at >= timeout )); then
            warn "timeout while waiting for $service"
            docker compose ps "$service" || true
            return 1
        fi

        sleep 3
    done
}

postgres_context_check() {
    info "Checking PostgreSQL static context"
    if docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f /dev/stdin < postgres/checks/context.sql; then
        ok "PostgreSQL context query completed"
        return 0
    fi

    warn "PostgreSQL context query failed"
    next "if this is a fresh stack, remove the PostgreSQL volume and rerun after installing the dataset"
    return 1
}

influx_exec() {
    docker compose exec -T influxdb influx "$@"
}

check_influx_access() {
    local output

    info "Checking InfluxDB token and organization"
    if ! output="$(influx_exec org list --host http://localhost:8086 --token "$INFLUX_TOKEN" 2>&1)"; then
        warn "InfluxDB token check failed"
        printf '%s\n' "$output"
        next "complete the InfluxDB UI setup and update INFLUX_TOKEN in .env"
        return 1
    fi

    if ! grep -Fq "$INFLUX_ORG" <<< "$output"; then
        warn "organization '$INFLUX_ORG' was not found"
        next "create/select organization '$INFLUX_ORG' in the InfluxDB UI, or update .env"
        return 1
    fi

    ok "InfluxDB organization and token are valid"
}

bucket_exists() {
    local bucket="$1"
    local output

    output="$(influx_exec bucket list \
        --host http://localhost:8086 \
        --org "$INFLUX_ORG" \
        --token "$INFLUX_TOKEN" 2>/dev/null || true)"

    awk 'NR > 1 {print $2}' <<< "$output" | grep -Fxq "$bucket"
}

check_buckets() {
    local missing=()
    local bucket

    info "Checking InfluxDB buckets"
    for bucket in urban_raw urban_hourly urban_daily urban_alerts; do
        if bucket_exists "$bucket"; then
            ok "bucket $bucket exists"
        else
            missing+=("$bucket")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        warn "missing InfluxDB buckets: ${missing[*]}"
        cat <<'EOF'
Create the buckets from the InfluxDB UI:

  urban_raw      retention 35d
  urban_hourly   retention 366d
  urban_daily    retention 1098d
  urban_alerts   retention 366d
EOF
        return 1
    fi
}

configure_postgres_secret() {
    local dsn

    info "Configuring InfluxDB secret POSTGRES_DSN"
    dsn="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}?sslmode=disable"

    if influx_exec secret update \
        --host http://localhost:8086 \
        --org "$INFLUX_ORG" \
        --token "$INFLUX_TOKEN" \
        --key POSTGRES_DSN \
        --value "$dsn" >/dev/null; then
        ok "InfluxDB secret POSTGRES_DSN configured"
        return 0
    fi

    warn "could not configure InfluxDB secret POSTGRES_DSN"
    next "check the token permissions and rerun make bootstrap-data"
    return 1
}

verify_flux_postgres() {
    info "Checking Flux to PostgreSQL access"
    if influx_exec query \
        --host http://localhost:8086 \
        --org "$INFLUX_ORG" \
        --token "$INFLUX_TOKEN" \
        --file /workspace/influx/spikes/postgres_threshold_test.flux >/dev/null; then
        ok "Flux can read PostgreSQL thresholds"
        return 0
    fi

    warn "Flux cannot read PostgreSQL thresholds"
    next "check POSTGRES_DSN secret and that PostgreSQL is running as service 'postgres'"
    return 1
}

task_exists() {
    local task="$1"
    local output

    output="$(influx_exec task list \
        --host http://localhost:8086 \
        --org "$INFLUX_ORG" \
        --token "$INFLUX_TOKEN" 2>/dev/null || true)"

    awk 'NR > 1 {print $2}' <<< "$output" | grep -Fxq "$task"
}

check_tasks() {
    local missing=()
    local task

    info "Checking InfluxDB Tasks"
    for task in raw_to_hourly hourly_to_daily hourly_to_alerts; do
        if task_exists "$task"; then
            ok "task $task exists"
        else
            missing+=("$task")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        warn "missing InfluxDB Tasks: ${missing[*]}"
        cat <<'EOF'
Create the Tasks from the InfluxDB UI by copying:

  influx/tasks/raw_to_hourly.flux
  influx/tasks/hourly_to_daily.flux
  influx/tasks/hourly_to_alerts.flux
EOF
        return 1
    fi
}

confirm_data_load() {
    if [[ "${YES:-0}" == "1" ]]; then
        ok "YES=1 received; continuing with historical load"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        warn "historical load was not started because this shell is non-interactive"
        next "rerun with YES=1 to load historical data"
        printf '      make bootstrap-data YES=1\n'
        return 1
    fi

    printf '\nThis will load historical Line Protocol data and backfill alerts.\n'
    printf 'Continue? [y/N] '
    local answer
    read -r answer
    case "$answer" in
        y|Y|yes|YES)
            return 0
            ;;
        *)
            warn "historical load skipped by user"
            next "rerun make bootstrap-data when you are ready"
            return 1
            ;;
    esac
}

print_count_query() {
    local label="$1"
    local query="$2"

    printf '\n%s\n' "$label"
    if ! influx_exec query \
        --host http://localhost:8086 \
        --org "$INFLUX_ORG" \
        --token "$INFLUX_TOKEN" \
        "$query"; then
        warn "could not read $label"
    fi
}

print_influx_counts() {
    info "InfluxDB data checkpoints"
    print_count_query "urban_raw points" \
        'from(bucket: "urban_raw") |> range(start: 0) |> filter(fn: (r) => r._measurement == "urban_telemetry") |> count() |> group() |> sum(column: "_value") |> keep(columns: ["_value"])'
    print_count_query "urban_hourly points" \
        'from(bucket: "urban_hourly") |> range(start: 0) |> filter(fn: (r) => r._measurement == "urban_telemetry") |> count() |> group() |> sum(column: "_value") |> keep(columns: ["_value"])'
    print_count_query "urban_daily points" \
        'from(bucket: "urban_daily") |> range(start: 0) |> filter(fn: (r) => r._measurement == "urban_telemetry") |> count() |> group() |> sum(column: "_value") |> keep(columns: ["_value"])'
    print_count_query "urban_alerts severity points" \
        'from(bucket: "urban_alerts") |> range(start: 0) |> filter(fn: (r) => r._measurement == "urban_alerts" and r._field == "severity_level") |> count() |> group() |> sum(column: "_value") |> keep(columns: ["_value"])'
}

create_kafka_topic() {
    info "Ensuring Kafka topic urban.telemetry"
    docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh \
        --bootstrap-server kafka:19092 \
        --create \
        --if-not-exists \
        --topic urban.telemetry \
        --partitions 1 \
        --replication-factor 1 \
        --config retention.ms=86400000
    ok "Kafka topic urban.telemetry is ready"
}

print_live_summary() {
    info "Continuous live producer"
    docker compose ps live-producer || true
    docker compose logs --tail=10 live-producer || true

    info "Kafka offsets"
    docker compose exec -T kafka /opt/kafka/bin/kafka-get-offsets.sh \
        --bootstrap-server kafka:19092 \
        --topic urban.telemetry || true

    info "Kafka consumer group urban-telegraf"
    docker compose exec -T kafka /opt/kafka/bin/kafka-consumer-groups.sh \
        --bootstrap-server kafka:19092 \
        --describe \
        --group urban-telegraf || true

    info "Recent Telegraf logs"
    docker compose logs --tail=30 telegraf || true
}

bootstrap_core() {
    info "Core bootstrap"
    ensure_env_file || return 0
    load_env
    check_required_env POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD INFLUX_ORG INFLUX_TOKEN GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD || return 0
    check_dataset || return 0
    docker_ready || return 0

    info "Validating Docker Compose file"
    docker compose config >/dev/null
    ok "Docker Compose configuration is valid"

    info "Starting PostgreSQL, InfluxDB and Grafana"
    docker compose up -d postgres influxdb grafana
    wait_for_service postgres 120 || return 1
    wait_for_service influxdb 120 || return 1
    wait_for_service grafana 60 || return 1
    postgres_context_check || true

    cat <<'EOF'

Core checkpoint completed.

Manual UI steps still expected:
  1. Open http://localhost:8086
  2. Complete the initial setup with organization polito
  3. Copy the operator token into .env as INFLUX_TOKEN
  4. Create/update buckets and retention policies
  5. Create the three InfluxDB Tasks from influx/tasks/*.flux

Then run:
  make bootstrap-data YES=1
EOF
}

bootstrap_data() {
    info "Data bootstrap"
    ensure_env_file || return 0
    load_env
    check_required_env POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD INFLUX_ORG INFLUX_TOKEN || return 0
    token_ready || return 0
    check_dataset || return 0
    docker_ready || return 0

    info "Ensuring core services are running"
    docker compose up -d postgres influxdb grafana
    wait_for_service postgres 120 || return 1
    wait_for_service influxdb 120 || return 1

    check_influx_access || return 0
    check_buckets || return 0
    configure_postgres_secret || return 0
    verify_flux_postgres || return 0
    check_tasks || return 0
    confirm_data_load || return 0

    ./scripts/load_historical.sh
    ./scripts/backfill_alerts.sh
    print_influx_counts || true

    cat <<'EOF'

Data checkpoint completed.

Next step:
  make bootstrap-live
EOF
}

bootstrap_live() {
    local producer_mode="continuous"
    local arg

    for arg in "$@"; do
        case "$arg" in
            --no-producer)
                producer_mode="none"
                ;;
            *)
                warn "unknown live option: $arg"
                usage
                return 2
                ;;
        esac
    done

    info "Live bootstrap"
    ensure_env_file || return 0
    load_env
    check_required_env INFLUX_ORG INFLUX_TOKEN || return 0
    token_ready || return 0
    check_dataset || return 0
    docker_ready || return 0

    info "Ensuring PostgreSQL and InfluxDB are running"
    docker compose up -d postgres influxdb
    wait_for_service postgres 120 || return 1
    wait_for_service influxdb 120 || return 1
    check_influx_access || return 0
    bucket_exists urban_raw || {
        warn "bucket urban_raw is missing"
        next "complete the InfluxDB bucket setup before starting live ingestion"
        return 0
    }

    info "Starting Kafka"
    docker compose up -d kafka
    wait_for_service kafka 180 || return 1
    create_kafka_topic

    info "Starting Telegraf"
    docker compose up -d telegraf
    wait_for_service telegraf 90 || true

    case "$producer_mode" in
        continuous)
            info "Starting continuous live producer"
            docker compose up -d live-producer
            ok "continuous producer is running at ${LIVE_INTERVAL_SECONDS:-60}s intervals"
            ;;
        none)
            ok "live producer skipped"
            ;;
    esac

    print_live_summary

    cat <<'EOF'

Live checkpoint completed.

The continuous producer emits one sample per active sensor every minute.

Use:
  make live-logs  # follow producer activity
  make stop-live  # stop new samples without stopping Kafka or Telegraf
  make status     # inspect services, counts and Kafka lag
EOF
}

case "$MODE" in
    core)
        bootstrap_core
        ;;
    data)
        bootstrap_data
        ;;
    live)
        bootstrap_live "$@"
        ;;
    -h|--help|help|"")
        usage
        ;;
    *)
        warn "unknown bootstrap mode: $MODE"
        usage
        exit 2
        ;;
esac

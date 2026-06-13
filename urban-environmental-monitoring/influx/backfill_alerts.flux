import "date"
import "sql"
import "influxdata/influxdb/secrets"

postgresDSN = secrets.get(key: "POSTGRES_DSN")
stopTime = date.truncate(t: now(), unit: 1h)
startTime = date.sub(d: 366d, from: stopTime)

thresholds = sql.from(
    driverName: "postgres",
    dataSourceName: postgresDSN,
    query: "SELECT metric, warning_threshold::double precision, critical_threshold::double precision FROM threshold_profile",
)
    |> group(columns: ["metric"])

hourly = from(bucket: "urban_hourly")
    |> range(start: startTime, stop: stopTime)
    |> filter(fn: (r) => r._measurement == "urban_telemetry")
    |> rename(columns: {_field: "metric", _value: "observed_value"})
    |> keep(columns: ["_time", "city", "grid_id", "cell_code", "borough", "zone_type", "metric", "observed_value"])
    |> group(columns: ["metric"])

alerts = join(tables: {hourly: hourly, threshold: thresholds}, on: ["metric"])
    |> map(fn: (r) => ({
        _time: r._time,
        city: r.city,
        grid_id: r.grid_id,
        cell_code: r.cell_code,
        borough: r.borough,
        zone_type: r.zone_type,
        metric: r.metric,
        observed_value: r.observed_value,
        threshold_value: if r.observed_value >= r.critical_threshold then r.critical_threshold else r.warning_threshold,
        severity_level: if r.observed_value >= r.critical_threshold then 2 else 1,
        is_alert: r.observed_value >= r.warning_threshold,
    }))
    |> filter(fn: (r) => r.is_alert)

observed = alerts
    |> map(fn: (r) => ({r with _measurement: "urban_alerts", _field: "observed_value", _value: r.observed_value}))
    |> keep(columns: ["_time", "_measurement", "_field", "_value", "city", "grid_id", "cell_code", "borough", "zone_type", "metric"])

threshold = alerts
    |> map(fn: (r) => ({r with _measurement: "urban_alerts", _field: "threshold_value", _value: r.threshold_value}))
    |> keep(columns: ["_time", "_measurement", "_field", "_value", "city", "grid_id", "cell_code", "borough", "zone_type", "metric"])

severity = alerts
    |> map(fn: (r) => ({r with _measurement: "urban_alerts", _field: "severity_level", _value: r.severity_level}))
    |> keep(columns: ["_time", "_measurement", "_field", "_value", "city", "grid_id", "cell_code", "borough", "zone_type", "metric"])

// observed_value and threshold_value are floats, while severity_level is an integer.
// Keep the integer semantics of severity_level and avoid a Flux union schema collision
// by writing the float fields and the integer field in separate pipelines.
union(tables: [observed, threshold])
    |> to(
        bucket: "urban_alerts",
        org: "polito",
        tagColumns: ["city", "grid_id", "cell_code", "borough", "zone_type", "metric"],
    )

severity
    |> to(
        bucket: "urban_alerts",
        org: "polito",
        tagColumns: ["city", "grid_id", "cell_code", "borough", "zone_type", "metric"],
    )

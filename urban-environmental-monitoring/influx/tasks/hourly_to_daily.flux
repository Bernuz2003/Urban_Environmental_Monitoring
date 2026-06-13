import "date"
import "timezone"

option task = {name: "hourly_to_daily", every: 1h, offset: 15m}
option location = timezone.location(name: "America/New_York")

stopTime = date.truncate(t: now(), unit: 1d)
startTime = date.sub(d: 3d, from: stopTime)

from(bucket: "urban_hourly")
    |> range(start: startTime, stop: stopTime)
    |> filter(fn: (r) => r._measurement == "urban_telemetry")
    |> group(columns: ["_field", "city", "grid_id", "cell_code", "borough", "zone_type"])
    |> aggregateWindow(every: 1d, fn: mean, createEmpty: false, timeSrc: "_start", location: location)
    |> map(fn: (r) => ({r with _measurement: "urban_telemetry"}))
    |> keep(columns: ["_time", "_measurement", "_field", "_value", "city", "grid_id", "cell_code", "borough", "zone_type"])
    |> to(
        bucket: "urban_daily",
        org: "polito",
        tagColumns: ["city", "grid_id", "cell_code", "borough", "zone_type"],
    )

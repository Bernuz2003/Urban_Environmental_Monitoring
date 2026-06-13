import "date"

option task = {name: "raw_to_hourly", every: 1m}

stopTime = date.truncate(t: now(), unit: 1h)
startTime = date.sub(d: 2h, from: stopTime)

from(bucket: "urban_raw")
    |> range(start: startTime, stop: stopTime)
    |> filter(fn: (r) => r._measurement == "urban_telemetry")
    |> group(columns: ["_field", "city", "grid_id", "cell_code", "borough", "zone_type"])
    |> aggregateWindow(every: 1h, fn: mean, createEmpty: false, timeSrc: "_start")
    |> map(fn: (r) => ({r with _measurement: "urban_telemetry"}))
    |> keep(columns: ["_time", "_measurement", "_field", "_value", "city", "grid_id", "cell_code", "borough", "zone_type"])
    |> to(
        bucket: "urban_hourly",
        org: "polito",
        tagColumns: ["city", "grid_id", "cell_code", "borough", "zone_type"],
    )

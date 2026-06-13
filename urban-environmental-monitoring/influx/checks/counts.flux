buckets = ["urban_raw", "urban_hourly", "urban_daily", "urban_alerts"]
// Run one bucket at a time by replacing the bucket name below.
from(bucket: "urban_raw")
  |> range(start: 0)
  |> filter(fn: (r) => r._measurement == "urban_telemetry")
  |> count()

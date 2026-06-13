from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import pandas as pd

from .config import (
    AGG_COLUMNS, AGG_TAG_COLUMNS, CITY, DAILY_CSV, GENERATOR_VERSION,
    GRID_CONTEXT_CSV, HOURLY_CSV, INFLUX_OUT, LIVE_OUT, OUTPUT_DIR,
    LINE_PROTOCOL_PRECISION, METRIC_COLUMNS, POSTGRES_OUT, RAW_COLUMNS, RAW_CSV, RAW_TAG_COLUMNS, SENSOR_CONTEXT_CSV,
    TELEMETRY_MEASUREMENT, THRESHOLD_PROFILE_CSV, TIMEZONE_NAME, WORK_DIR, GenerationConfig,
    ensure_directories,
)
from .line_protocol import csv_to_gzip_line_protocol
from .live_feed import generate_live_feed
from .synthetic_model import generate_zone_hourly, prepare_grid, prepare_sensors, synthesize_sensor_samples

MANIFEST_PATH = OUTPUT_DIR / "manifest.json"
CHECKSUMS_PATH = OUTPUT_DIR / "checksums.sha256"


def _write_chunk(path: Path, frame: pd.DataFrame, first: bool) -> bool:
    frame.to_csv(path, mode="w" if first else "a", header=first, index=False)
    return False


def _clear_outputs() -> None:
    shutil.rmtree(OUTPUT_DIR, ignore_errors=True)
    shutil.rmtree(WORK_DIR, ignore_errors=True)
    ensure_directories()


def load_context(config: GenerationConfig) -> tuple[pd.DataFrame, pd.DataFrame]:
    grid = prepare_grid(pd.read_csv(GRID_CONTEXT_CSV))
    if config.zone_limit is not None:
        grid = grid.head(config.zone_limit).copy()
        grid["_zone_index"] = range(len(grid))
    sensor_frame = pd.read_csv(SENSOR_CONTEXT_CSV)
    sensor_frame = sensor_frame[sensor_frame["grid_id"].isin(set(grid["grid_id"]))].copy()
    sensors = prepare_sensors(sensor_frame, grid)
    return grid, sensors


def _daily_from_hourly(frame: pd.DataFrame) -> pd.DataFrame:
    working = frame.copy()
    timestamp = pd.to_datetime(working["timestamp"], utc=True)
    working["timestamp"] = timestamp.dt.tz_convert(TIMEZONE_NAME).dt.normalize().dt.tz_convert("UTC")
    aggregations = {column: "first" for column in ["city", "cell_code", "borough", "zone_type"]}
    aggregations.update({metric: "mean" for metric in METRIC_COLUMNS})
    daily = working.groupby(["timestamp", "grid_id"], sort=True, as_index=False).agg(aggregations)
    daily["timestamp"] = pd.to_datetime(daily["timestamp"], utc=True).dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    for metric in METRIC_COLUMNS:
        decimals = 4 if metric == "traffic_density" else 3 if metric == "co" else 2
        daily[metric] = daily[metric].round(decimals)
    return daily[AGG_COLUMNS].sort_values(["timestamp", "grid_id"]).reset_index(drop=True)


def _next_local_midnight(timestamp: pd.Timestamp) -> pd.Timestamp:
    local = timestamp.tz_convert(TIMEZONE_NAME)
    return local if local == local.normalize() else local.normalize() + pd.DateOffset(days=1)


def _representative_daily_history(grid, start_local, end_local, history_start, seed, chunk_days):
    local_days = pd.date_range(start_local, end_local, freq="D", inclusive="left")
    for start_idx in range(0, len(local_days), chunk_days):
        days = local_days[start_idx:start_idx + chunk_days]
        if days.empty:
            continue
        wall_times = [pd.Timestamp(day.date()).replace(hour=hour) for day in days for hour in (3, 9, 15, 21)]
        samples = pd.DatetimeIndex(wall_times).tz_localize(
            TIMEZONE_NAME, ambiguous="infer", nonexistent="shift_forward"
        ).tz_convert("UTC")
        yield _daily_from_hourly(generate_zone_hourly(grid, samples, history_start, seed))


def generate_hourly_and_daily(grid: pd.DataFrame, config: GenerationConfig) -> tuple[int, int]:
    hourly_first = daily_first = True
    hourly_rows = daily_rows = 0
    history_start = config.daily_start
    exact_daily_start_local = _next_local_midnight(config.hourly_start)
    daily_start_local = config.daily_start.tz_convert(TIMEZONE_NAME)
    daily_end_local = config.daily_end.tz_convert(TIMEZONE_NAME)

    old_daily_end_local = min(exact_daily_start_local, daily_end_local)
    for daily in _representative_daily_history(
        grid, daily_start_local, old_daily_end_local, history_start, config.seed, config.chunk_days
    ):
        daily_first = _write_chunk(DAILY_CSV, daily, daily_first)
        daily_rows += len(daily)

    exact_daily_start_utc = exact_daily_start_local.tz_convert("UTC")
    if config.hourly_start < min(exact_daily_start_utc, config.reference_time):
        prefix_end = min(exact_daily_start_utc, config.reference_time)
        timestamps = pd.date_range(config.hourly_start, prefix_end, freq="h", inclusive="left")
        prefix = generate_zone_hourly(grid, timestamps, history_start, config.seed)
        hourly_first = _write_chunk(HOURLY_CSV, prefix[AGG_COLUMNS], hourly_first)
        hourly_rows += len(prefix)

    full_days_start = max(exact_daily_start_local, daily_start_local)
    if full_days_start < daily_end_local:
        local_days = pd.date_range(full_days_start, daily_end_local, freq="D", inclusive="both")
        for start_idx in range(0, len(local_days) - 1, config.chunk_days):
            end_idx = min(start_idx + config.chunk_days, len(local_days) - 1)
            chunk_start = local_days[start_idx].tz_convert("UTC")
            chunk_end = local_days[end_idx].tz_convert("UTC")
            timestamps = pd.date_range(chunk_start, chunk_end, freq="h", inclusive="left")
            base = generate_zone_hourly(grid, timestamps, history_start, config.seed)
            hourly_first = _write_chunk(HOURLY_CSV, base[AGG_COLUMNS], hourly_first)
            hourly_rows += len(base)
            daily = _daily_from_hourly(base)
            daily_first = _write_chunk(DAILY_CSV, daily, daily_first)
            daily_rows += len(daily)

    current_start = max(config.daily_end, config.hourly_start)
    if current_start < config.reference_time:
        timestamps = pd.date_range(current_start, config.reference_time, freq="h", inclusive="left")
        current_day = generate_zone_hourly(grid, timestamps, history_start, config.seed)
        hourly_first = _write_chunk(HOURLY_CSV, current_day[AGG_COLUMNS], hourly_first)
        hourly_rows += len(current_day)

    if hourly_first:
        pd.DataFrame(columns=AGG_COLUMNS).to_csv(HOURLY_CSV, index=False)
    if daily_first:
        pd.DataFrame(columns=AGG_COLUMNS).to_csv(DAILY_CSV, index=False)
    return hourly_rows, daily_rows


def generate_raw(grid: pd.DataFrame, sensors: pd.DataFrame, config: GenerationConfig) -> int:
    sample_times = pd.date_range(
        config.raw_start, config.reference_time,
        freq=f"{config.raw_interval_minutes}min", inclusive="left"
    )
    samples_per_chunk = max(1, min(config.chunk_days, 10) * 24 * (60 // config.raw_interval_minutes))
    first, total = True, 0
    for start_idx in range(0, len(sample_times), samples_per_chunk):
        chunk = sample_times[start_idx:start_idx + samples_per_chunk]
        frame = synthesize_sensor_samples(
            grid=grid, sensors=sensors, sample_times=chunk,
            history_start=config.daily_start, seed=config.seed, live_noise=False,
        )
        first = _write_chunk(RAW_CSV, frame, first)
        total += len(frame)
    if first:
        pd.DataFrame(columns=RAW_COLUMNS).to_csv(RAW_CSV, index=False)
    return total


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _run_raw_worker(config: GenerationConfig) -> int:
    with tempfile.NamedTemporaryFile(prefix="uem-raw-", suffix=".json", delete=False) as handle:
        result_path = Path(handle.name)
    command = [
        sys.executable, "-m", "uem_data_generator.worker", "--result-file", str(result_path),
        "--reference-time", config.reference_time.isoformat(), "--daily-days", str(config.daily_days),
        "--hourly-days", str(config.hourly_days), "--raw-days", str(config.raw_days),
        "--raw-interval-minutes", str(config.raw_interval_minutes), "--seed", str(config.seed),
        "--chunk-days", str(config.chunk_days),
    ]
    if config.zone_limit is not None:
        command += ["--zone-limit", str(config.zone_limit)]
    try:
        completed = subprocess.run(command, text=True, capture_output=True, check=False)
        if completed.returncode != 0:
            raise RuntimeError(completed.stderr or completed.stdout)
        return int(json.loads(result_path.read_text())["raw_rows"])
    finally:
        result_path.unlink(missing_ok=True)


def _copy_static_context(grid_ids: set[str]) -> None:
    grid = pd.read_csv(GRID_CONTEXT_CSV)
    sensors = pd.read_csv(SENSOR_CONTEXT_CSV)
    grid[grid["grid_id"].isin(grid_ids)].to_csv(POSTGRES_OUT / "grid_context.csv", index=False)
    sensors[sensors["grid_id"].isin(grid_ids)].to_csv(POSTGRES_OUT / "sensor_context.csv", index=False)
    shutil.copy2(THRESHOLD_PROFILE_CSV, POSTGRES_OUT / "threshold_profile.csv")


def build_dataset(config: GenerationConfig, *, keep_csv: bool = False) -> dict[str, object]:
    config.validate()
    _clear_outputs()
    grid, sensors = load_context(config)
    print(f"Generating {len(grid)} zones and {len(sensors)} sensors up to {config.reference_time}...")

    raw_rows = _run_raw_worker(config)
    print(f"urban_raw CSV:    {raw_rows:,} rows")
    hourly_rows, daily_rows = generate_hourly_and_daily(grid, config)
    print(f"urban_hourly CSV: {hourly_rows:,} rows")
    print(f"urban_daily CSV:  {daily_rows:,} rows")

    lp_files = {
        "urban_raw": (RAW_CSV, INFLUX_OUT / "urban_raw.lp.gz", RAW_TAG_COLUMNS),
        "urban_hourly": (HOURLY_CSV, INFLUX_OUT / "urban_hourly.lp.gz", AGG_TAG_COLUMNS),
        "urban_daily": (DAILY_CSV, INFLUX_OUT / "urban_daily.lp.gz", AGG_TAG_COLUMNS),
    }
    for name, (source, target, tags) in lp_files.items():
        rows = csv_to_gzip_line_protocol(
            source, target, measurement=TELEMETRY_MEASUREMENT, tags=tags, fields=METRIC_COLUMNS
        )
        print(f"{name} Line Protocol: {rows:,} points -> {target.name}")

    _copy_static_context(set(grid["grid_id"]))
    live_counts = generate_live_feed(grid, sensors, config)
    print(f"Live feed: {sum(live_counts.values()):,} template records in 4 batches")

    files = {}
    for path in sorted(OUTPUT_DIR.rglob("*")):
        if path.is_file() and path.name not in {"manifest.json", "checksums.sha256"}:
            files[str(path.relative_to(OUTPUT_DIR))] = {
                "bytes": path.stat().st_size,
                "sha256": _sha256(path),
            }
    mode = "full" if config.zone_limit is None and config.daily_days >= 1095 else "custom"
    manifest = {
        "dataset_id": f"synthetic_nyc_{config.reference_time.strftime('%Y%m%dT%H%M%SZ')}",
        "generator_version": GENERATOR_VERSION,
        "generation_mode": mode,
        "generated_at": config.generated_at,
        "reference_time": config.reference_time.isoformat().replace("+00:00", "Z"),
        "city": CITY,
        "line_protocol_timestamp_precision": LINE_PROTOCOL_PRECISION,
        "grid_cells": len(grid),
        "sensors": len(sensors),
        "raw_rows": raw_rows,
        "hourly_rows": hourly_rows,
        "daily_rows": daily_rows,
        "live_batch_rows": live_counts,
        "raw_start": config.raw_start.isoformat().replace("+00:00", "Z"),
        "hourly_start": config.hourly_start.isoformat().replace("+00:00", "Z"),
        "daily_start": config.daily_start.isoformat().replace("+00:00", "Z"),
        "daily_end": config.daily_end.isoformat().replace("+00:00", "Z"),
        "files": files,
        "notes": "Historical alerts are intentionally not generated. The runtime derives urban_alerts from urban_hourly and PostgreSQL thresholds.",
    }
    MANIFEST_PATH.write_text(json.dumps(manifest, indent=2) + "\n")
    with CHECKSUMS_PATH.open("w") as handle:
        for relative, metadata in sorted(files.items()):
            handle.write(f"{metadata['sha256']}  {relative}\n")
        handle.write(f"{_sha256(MANIFEST_PATH)}  manifest.json\n")

    if not keep_csv:
        shutil.rmtree(WORK_DIR, ignore_errors=True)
    print(f"Dataset bundle ready: {OUTPUT_DIR}")
    return manifest

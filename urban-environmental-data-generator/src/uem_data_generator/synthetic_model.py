from __future__ import annotations

"""Deterministic synthetic urban-environmental model.

The model is intentionally compact: a single latent hourly process is reused by
historical generation and the live producer. It produces visible but non-perfect
relationships between traffic, pollutants, weather, green space and noise.
"""

import numpy as np
import pandas as pd

from .config import AGG_COLUMNS, CITY, FIELD_RANGES, METRIC_COLUMNS, RAW_COLUMNS, TIMEZONE_NAME

ZONE_TRAFFIC_BASE = {
    "park": 0.12,
    "residential": 0.30,
    "mixed": 0.43,
    "commercial": 0.58,
    "industrial": 0.54,
}

ZONE_NOISE_OFFSET = {
    "park": -5.0,
    "residential": -1.5,
    "mixed": 1.5,
    "commercial": 4.0,
    "industrial": 3.0,
}

RAW_AMPLITUDE = {
    "pm25": 0.55,
    "pm10": 0.80,
    "no2": 0.95,
    "o3": 1.20,
    "co": 0.035,
    "noise_db": 0.60,
    "traffic_density": 0.010,
    "temperature_c": 0.18,
    "humidity_pct": 0.75,
    "wind_speed_ms": 0.14,
}


def gaussian(x: np.ndarray, center: float, width: float) -> np.ndarray:
    return np.exp(-0.5 * ((x - center) / width) ** 2)


def pseudo_normal(zone_index: np.ndarray, ordinal_hour: np.ndarray, seed: int, salt: float) -> np.ndarray:
    """Cheap deterministic noise with approximately normal-looking support."""
    x1 = np.sin(zone_index * 12.9898 + ordinal_hour * 78.233 + seed * 0.071 + salt) * 43758.5453
    x2 = np.sin(zone_index * 39.3467 + ordinal_hour * 11.135 + seed * 0.137 + salt * 1.7) * 24634.6345
    u1 = x1 - np.floor(x1)
    u2 = x2 - np.floor(x2)
    return (u1 + u2 - 1.0) * 1.9


def prepare_grid(grid: pd.DataFrame) -> pd.DataFrame:
    required = {
        "grid_id",
        "cell_code",
        "city",
        "borough",
        "zone_type",
        "green_space_pct",
        "road_density",
        "population_density_factor",
    }
    missing = sorted(required - set(grid.columns))
    if missing:
        raise ValueError(f"Grid context is missing columns: {missing}")
    result = grid.sort_values("grid_id").reset_index(drop=True).copy()
    result["_zone_index"] = np.arange(len(result), dtype=float)
    return result


def prepare_sensors(sensors: pd.DataFrame, grid: pd.DataFrame) -> pd.DataFrame:
    required = {"sensor_id", "grid_id", "sensor_type", "active"}
    missing = sorted(required - set(sensors.columns))
    if missing:
        raise ValueError(f"Sensor context is missing columns: {missing}")

    active = sensors[sensors["active"].astype(str).str.lower().isin({"true", "1", "yes"})].copy()
    context = active.merge(
        grid[["grid_id", "cell_code", "city", "borough", "zone_type", "_zone_index"]],
        on="grid_id",
        how="left",
        validate="many_to_one",
    )
    if context["city"].isna().any():
        raise ValueError("At least one sensor references an unknown grid_id.")

    context = context.sort_values(["grid_id", "sensor_id"]).reset_index(drop=True)
    context["_sensor_order"] = context.groupby("grid_id").cumcount()
    context["_sensor_count"] = context.groupby("grid_id")["sensor_id"].transform("size")
    # Centered inside each zone: one sensor has zero bias, two sensors have +/-0.5.
    context["_centered_bias"] = context["_sensor_order"] - (context["_sensor_count"] - 1) / 2.0
    return context


def generate_zone_hourly(
    grid: pd.DataFrame,
    timestamps: pd.DatetimeIndex,
    history_start: pd.Timestamp,
    seed: int,
) -> pd.DataFrame:
    """Generate one wide row per zone and completed UTC hour."""
    if timestamps.empty:
        return pd.DataFrame(columns=AGG_COLUMNS)
    if timestamps.tz is None:
        raise ValueError("timestamps must be timezone-aware")

    timestamps = timestamps.tz_convert("UTC")
    n_zones = len(grid)
    n_hours = len(timestamps)

    local = timestamps.tz_convert(TIMEZONE_NAME)
    hour = np.repeat(local.hour.to_numpy(dtype=float), n_zones)
    dayofyear = np.repeat(local.dayofyear.to_numpy(dtype=float), n_zones)
    weekday = np.repeat(local.weekday.to_numpy(dtype=int), n_zones)
    ordinal_hour = np.repeat((timestamps.asi8 // 3_600_000_000_000).astype(float), n_zones)
    elapsed_years = np.repeat(
        ((timestamps - history_start).total_seconds() / (365.25 * 24 * 3600)).to_numpy(dtype=float),
        n_zones,
    )

    zone_index = np.tile(grid["_zone_index"].to_numpy(dtype=float), n_hours)
    green = np.tile(grid["green_space_pct"].to_numpy(dtype=float), n_hours)
    road = np.tile(grid["road_density"].to_numpy(dtype=float), n_hours)
    population = np.tile(grid["population_density_factor"].to_numpy(dtype=float), n_hours)
    zone_type = np.tile(grid["zone_type"].to_numpy(dtype=str), n_hours)

    zone_base = np.array([ZONE_TRAFFIC_BASE.get(value, 0.35) for value in zone_type], dtype=float)
    zone_noise = np.array([ZONE_NOISE_OFFSET.get(value, 0.0) for value in zone_type], dtype=float)

    is_weekday = weekday < 5
    commute_peak = gaussian(hour, 8.0, 1.35) + gaussian(hour, 18.0, 1.55)
    midday_activity = gaussian(hour, 13.0, 3.2)
    night_quiet = np.where((hour <= 5) | (hour >= 23), -0.18, 0.0)
    night_indicator = ((hour <= 5) | (hour >= 22)).astype(float)
    evening_shoulder = ((hour >= 20) & (hour < 22)).astype(float)
    weekend_factor = np.where(is_weekday, 1.0, 0.72)

    winter_stagnation = (
        (((dayofyear >= 13) & (dayofyear <= 17)) | ((dayofyear >= 344) & (dayofyear <= 348)))
        * (1.0 + 0.35 * road)
    )
    summer_heatwave = ((dayofyear >= 188) & (dayofyear <= 201)) | ((dayofyear >= 218) & (dayofyear <= 228))
    traffic_disruption = (
        ((dayofyear.astype(int) + zone_index.astype(int) * 3) % 47 == 0)
        & (hour >= 7)
        & (hour <= 11)
        & ((road >= 0.58) | np.isin(zone_type, ["commercial", "industrial"]))
    )
    local_pollution = (
        ((dayofyear.astype(int) + zone_index.astype(int) * 11) % 181 == 37)
        & (hour >= 9)
        & (hour <= 15)
        & np.isin(zone_type, ["industrial", "commercial"])
    )

    noise_traffic = pseudo_normal(zone_index, ordinal_hour, seed, 3.1)
    noise_temp = pseudo_normal(zone_index, ordinal_hour, seed, 9.7)
    noise_pm = pseudo_normal(zone_index, ordinal_hour, seed, 19.3)
    noise_o3 = pseudo_normal(zone_index, ordinal_hour, seed, 29.9)
    noise_no2 = pseudo_normal(zone_index, ordinal_hour, seed, 41.7)
    noise_co = pseudo_normal(zone_index, ordinal_hour, seed, 53.9)
    noise_noise = pseudo_normal(zone_index, ordinal_hour, seed, 67.1)
    daily_ordinal = np.floor(ordinal_hour / 24.0)
    daily_weather = pseudo_normal(zone_index, daily_ordinal, seed, 71.3)

    traffic_density = (
        zone_base
        + 0.30 * commute_peak * weekend_factor
        + 0.10 * midday_activity
        + 0.16 * road
        + 0.018 * elapsed_years
        + 0.18 * traffic_disruption
        + night_quiet
        + 0.042 * noise_traffic
    )
    traffic_density = np.clip(traffic_density, 0.02, 0.98)

    seasonal_temperature = 12.0 + 13.5 * np.sin(2 * np.pi * (dayofyear - 109) / 365)
    daily_temperature = 4.2 * np.sin(2 * np.pi * (hour - 8) / 24)
    green_factor = green / 100.0
    temperature_c = (
        seasonal_temperature
        + daily_temperature
        + 0.35 * elapsed_years
        + 4.2 * summer_heatwave.astype(float)
        - 1.4 * green_factor
        + 1.55 * noise_temp
    )
    temperature_c = np.clip(temperature_c, -12.0, 41.0)

    humidity_pct = 64.0 - 0.62 * (temperature_c - 15.0) + 5.6 * pseudo_normal(zone_index, ordinal_hour, seed, 47.0)
    humidity_pct = np.clip(humidity_pct, 24.0, 96.0)

    wind_speed_ms = 0.8 + 2.4 * np.abs(np.sin(ordinal_hour * 0.037 + zone_index * 0.19 + seed))
    wind_speed_ms += 0.6 * gaussian(hour, 15.0, 5.0)
    wind_speed_ms -= 1.1 * winter_stagnation.astype(float)
    wind_speed_ms = np.clip(wind_speed_ms, 0.25, 12.0)

    low_wind_factor = np.clip((3.0 - wind_speed_ms) / 3.0, 0.0, 1.0)
    winter_factor = 0.5 + 0.5 * np.cos(2 * np.pi * (dayofyear - 15) / 365)
    hot_daylight = np.clip((temperature_c - 22.0) / 14.0, 0.0, 1.0) * gaussian(hour, 15.0, 3.5)

    pm25 = (
        8.0 + 15.0 * traffic_density + 6.5 * road + 5.8 * low_wind_factor + 4.0 * winter_factor
        + 9.0 * winter_stagnation.astype(float) + 7.5 * local_pollution.astype(float)
        + 0.45 * elapsed_years - 10.0 * green_factor + 5.5 * daily_weather + 4.0 * noise_pm
    )
    pm25 = np.clip(pm25, 2.0, 78.0)

    pm10 = (
        13.0 + 23.0 * traffic_density + 10.5 * road + 7.5 * low_wind_factor + 4.5 * winter_factor
        + 13.0 * winter_stagnation.astype(float) + 11.0 * local_pollution.astype(float)
        + 0.60 * elapsed_years - 13.0 * green_factor + 7.5 * daily_weather + 5.5 * noise_pm
    )
    pm10 = np.clip(pm10, 4.0, 118.0)

    no2 = (
        12.0 + 34.0 * traffic_density + 6.5 * road + 4.0 * population
        + 7.0 * winter_stagnation.astype(float) + 11.0 * traffic_disruption.astype(float)
        + 0.80 * elapsed_years - 3.0 * green_factor + 7.0 * noise_no2
    )
    no2 = np.clip(no2, 3.0, 118.0)

    o3 = (
        30.0 + 92.0 * hot_daylight
        + 60.0 * summer_heatwave.astype(float) * gaussian(hour, 15.0, 3.5)
        + 0.90 * elapsed_years + 8.0 * wind_speed_ms / 6.0
        - 12.0 * traffic_density + 8.0 * noise_o3
    )
    o3 = np.clip(o3, 5.0, 215.0)

    co = (
        0.25 + 2.3 * traffic_density + 0.42 * road + 0.35 * low_wind_factor
        + 0.42 * traffic_disruption.astype(float) + 9.5 * local_pollution.astype(float) + 0.50 * noise_co
    )
    co = np.clip(co, 0.05, 18.0)

    noise_db = (
        47.0 + 27.0 * traffic_density + 8.0 * road + zone_noise
        + 6.0 * traffic_disruption.astype(float) - 8.5 * green_factor
        - 8.0 * night_indicator - 3.0 * evening_shoulder + 3.5 * noise_noise
    )
    noise_db = np.clip(noise_db, 35.0, 92.0)

    return pd.DataFrame(
        {
            "timestamp": np.repeat(timestamps.strftime("%Y-%m-%dT%H:%M:%SZ").to_numpy(), n_zones),
            "city": CITY,
            "grid_id": np.tile(grid["grid_id"].to_numpy(dtype=str), n_hours),
            "cell_code": np.tile(grid["cell_code"].to_numpy(dtype=str), n_hours),
            "borough": np.tile(grid["borough"].to_numpy(dtype=str), n_hours),
            "zone_type": zone_type,
            "pm25": np.round(pm25, 2),
            "pm10": np.round(pm10, 2),
            "no2": np.round(no2, 2),
            "o3": np.round(o3, 2),
            "co": np.round(co, 3),
            "noise_db": np.round(noise_db, 2),
            "traffic_density": np.round(traffic_density, 4),
            "temperature_c": np.round(temperature_c, 2),
            "humidity_pct": np.round(humidity_pct, 2),
            "wind_speed_ms": np.round(wind_speed_ms, 2),
        },
        columns=AGG_COLUMNS,
    )


def synthesize_sensor_samples(
    grid: pd.DataFrame,
    sensors: pd.DataFrame,
    sample_times: pd.DatetimeIndex,
    history_start: pd.Timestamp,
    seed: int,
    live_noise: bool = False,
) -> pd.DataFrame:
    """Expand latent zone values into sensor rows.

    Historical quarter-hour perturbations are centered by construction, so their
    hourly average remains aligned with ``urban_hourly``. Optional live noise is
    deterministic for the timestamp and does not require persistent state.
    """
    if sample_times.empty:
        return pd.DataFrame(columns=RAW_COLUMNS)
    if sample_times.tz is None:
        raise ValueError("sample_times must be timezone-aware")

    sample_times = sample_times.tz_convert("UTC")
    latent_hours = pd.DatetimeIndex(sample_times.floor("h").unique()).tz_convert("UTC")
    latent = generate_zone_hourly(grid, latent_hours, history_start, seed)
    latent["_hour"] = pd.to_datetime(latent["timestamp"], utc=True)
    latent = latent.drop(columns=["timestamp"])

    n_samples = len(sample_times)
    frame = pd.DataFrame(
        {
            "_sample_time": np.repeat(sample_times, len(sensors)),
            "sensor_id": np.tile(sensors["sensor_id"].to_numpy(dtype=str), n_samples),
            "sensor_type": np.tile(sensors["sensor_type"].to_numpy(dtype=str), n_samples),
            "grid_id": np.tile(sensors["grid_id"].to_numpy(dtype=str), n_samples),
            "cell_code": np.tile(sensors["cell_code"].to_numpy(dtype=str), n_samples),
            "city": CITY,
            "borough": np.tile(sensors["borough"].to_numpy(dtype=str), n_samples),
            "zone_type": np.tile(sensors["zone_type"].to_numpy(dtype=str), n_samples),
            "_centered_bias": np.tile(sensors["_centered_bias"].to_numpy(dtype=float), n_samples),
        }
    )
    frame["_hour"] = frame["_sample_time"].dt.floor("h")
    frame = frame.merge(
        latent,
        on=["_hour", "grid_id", "cell_code", "city", "borough", "zone_type"],
        how="left",
        validate="many_to_one",
    )

    minute = frame["_sample_time"].dt.minute.to_numpy(dtype=float)
    intra_hour = np.sin(2.0 * np.pi * minute / 60.0)
    bias = frame["_centered_bias"].to_numpy(dtype=float)
    if live_noise:
        ordinal = frame["_sample_time"].astype("int64").to_numpy(dtype=float) / 1e9
        jitter = np.sin(ordinal * 0.017 + np.arange(len(frame)) * 0.13 + seed) * 0.35
    else:
        jitter = np.zeros(len(frame), dtype=float)

    for metric in METRIC_COLUMNS:
        amplitude = RAW_AMPLITUDE[metric]
        values = frame[metric].to_numpy(dtype=float) + amplitude * (intra_hour + bias + jitter)
        low, high = FIELD_RANGES[metric]
        decimals = 4 if metric == "traffic_density" else 3 if metric == "co" else 2
        frame[metric] = np.round(np.clip(values, low, high), decimals)

    frame["timestamp"] = frame["_sample_time"].dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    return frame[RAW_COLUMNS].sort_values(["timestamp", "grid_id", "sensor_id"]).reset_index(drop=True)

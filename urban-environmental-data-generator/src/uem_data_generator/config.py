from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Final

import pandas as pd

ROOT: Final[Path] = Path(__file__).resolve().parents[2]
REFERENCE_DIR: Final[Path] = ROOT / "data" / "reference"
WORK_DIR: Final[Path] = ROOT / "work" / "csv"
OUTPUT_DIR: Final[Path] = ROOT / "output" / "urban-environmental-dataset"
POSTGRES_OUT: Final[Path] = OUTPUT_DIR / "postgres"
INFLUX_OUT: Final[Path] = OUTPUT_DIR / "influx"
LIVE_OUT: Final[Path] = OUTPUT_DIR / "live"

GRID_CONTEXT_CSV: Final[Path] = REFERENCE_DIR / "grid_context.csv"
SENSOR_CONTEXT_CSV: Final[Path] = REFERENCE_DIR / "sensor_context.csv"
THRESHOLD_PROFILE_CSV: Final[Path] = REFERENCE_DIR / "threshold_profile.csv"
BOROUGHS_GEOJSON: Final[Path] = REFERENCE_DIR / "nyc_boroughs.geojson"

RAW_CSV: Final[Path] = WORK_DIR / "urban_raw.csv"
HOURLY_CSV: Final[Path] = WORK_DIR / "urban_hourly.csv"
DAILY_CSV: Final[Path] = WORK_DIR / "urban_daily.csv"

CITY: Final[str] = "New York"
TIMEZONE_NAME: Final[str] = "America/New_York"
TELEMETRY_MEASUREMENT: Final[str] = "urban_telemetry"
GENERATOR_VERSION: Final[str] = "1.0.1"
LINE_PROTOCOL_PRECISION: Final[str] = "us"

METRIC_COLUMNS: Final[list[str]] = [
    "pm25", "pm10", "no2", "o3", "co", "noise_db",
    "traffic_density", "temperature_c", "humidity_pct", "wind_speed_ms",
]
RAW_TAG_COLUMNS: Final[list[str]] = [
    "city", "grid_id", "cell_code", "borough", "zone_type", "sensor_id", "sensor_type",
]
AGG_TAG_COLUMNS: Final[list[str]] = ["city", "grid_id", "cell_code", "borough", "zone_type"]
RAW_COLUMNS: Final[list[str]] = ["timestamp", *RAW_TAG_COLUMNS, *METRIC_COLUMNS]
AGG_COLUMNS: Final[list[str]] = ["timestamp", *AGG_TAG_COLUMNS, *METRIC_COLUMNS]

FIELD_RANGES: Final[dict[str, tuple[float, float]]] = {
    "pm25": (0.0, 80.0), "pm10": (0.0, 120.0), "no2": (0.0, 120.0),
    "o3": (0.0, 220.0), "co": (0.0, 20.0), "noise_db": (30.0, 95.0),
    "traffic_density": (0.0, 1.0), "temperature_c": (-25.0, 45.0),
    "humidity_pct": (0.0, 100.0), "wind_speed_ms": (0.0, 20.0),
}

@dataclass(frozen=True)
class GenerationConfig:
    reference_time: pd.Timestamp
    daily_days: int = 1095
    hourly_days: int = 365
    raw_days: int = 30
    raw_interval_minutes: int = 15
    seed: int = 42
    chunk_days: int = 60
    zone_limit: int | None = None

    @classmethod
    def create(cls, reference_time: str | datetime | pd.Timestamp | None = None, **kwargs: object) -> "GenerationConfig":
        timestamp = pd.Timestamp.now(tz="UTC") if reference_time is None else pd.Timestamp(reference_time)
        if timestamp.tzinfo is None:
            timestamp = timestamp.tz_localize("UTC")
        else:
            timestamp = timestamp.tz_convert("UTC")
        return cls(reference_time=timestamp.floor("h"), **kwargs)

    def validate(self) -> None:
        if min(self.daily_days, self.hourly_days, self.raw_days) < 1:
            raise ValueError("All history windows must be positive.")
        if self.hourly_days > self.daily_days:
            raise ValueError("hourly_days cannot exceed daily_days.")
        if self.raw_days > self.hourly_days:
            raise ValueError("raw_days cannot exceed hourly_days.")
        if self.raw_interval_minutes <= 0 or 60 % self.raw_interval_minutes != 0:
            raise ValueError("raw_interval_minutes must be a positive divisor of 60.")
        if self.chunk_days < 1:
            raise ValueError("chunk_days must be positive.")
        if self.zone_limit is not None and self.zone_limit < 1:
            raise ValueError("zone_limit must be positive.")

    @property
    def raw_start(self) -> pd.Timestamp:
        return self.reference_time - pd.Timedelta(days=self.raw_days)

    @property
    def hourly_start(self) -> pd.Timestamp:
        return self.reference_time - pd.Timedelta(days=self.hourly_days)

    @property
    def current_local_day_start(self) -> pd.Timestamp:
        return self.reference_time.tz_convert(TIMEZONE_NAME).normalize()

    @property
    def daily_end(self) -> pd.Timestamp:
        return self.current_local_day_start.tz_convert("UTC")

    @property
    def daily_start(self) -> pd.Timestamp:
        return (self.current_local_day_start - pd.Timedelta(days=self.daily_days)).tz_convert("UTC")

    @property
    def generated_at(self) -> str:
        return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def ensure_directories() -> None:
    for directory in (WORK_DIR, OUTPUT_DIR, POSTGRES_OUT, INFLUX_OUT, LIVE_OUT):
        directory.mkdir(parents=True, exist_ok=True)

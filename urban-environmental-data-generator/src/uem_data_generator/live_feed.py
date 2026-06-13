from __future__ import annotations

import pandas as pd

from .config import LIVE_OUT, METRIC_COLUMNS, RAW_TAG_COLUMNS, THRESHOLD_PROFILE_CSV, GenerationConfig
from .line_protocol import frame_to_lines
from .synthetic_model import synthesize_sensor_samples


def generate_live_feed(grid: pd.DataFrame, sensors: pd.DataFrame, config: GenerationConfig) -> dict[str, int]:
    """Create four raw-data templates. Timestamps are added by the runtime replayer.

    A small set of zones is deliberately pushed above operational thresholds so
    that the runtime InfluxDB Task generates real alerts during the demo.
    """
    thresholds = pd.read_csv(THRESHOLD_PROFILE_CSV).set_index("metric")
    preferred = grid[grid["zone_type"].isin(["commercial", "industrial", "mixed"])]
    chosen = preferred.head(4)["grid_id"].tolist()
    if len(chosen) < 4:
        chosen += [value for value in grid["grid_id"].tolist() if value not in chosen][:4-len(chosen)]

    base_hour = config.reference_time - pd.Timedelta(hours=1)
    result: dict[str, int] = {}
    for minute in (0, 15, 30, 45):
        timestamp = base_hour + pd.Timedelta(minutes=minute)
        frame = synthesize_sensor_samples(
            grid=grid, sensors=sensors, sample_times=pd.DatetimeIndex([timestamp]),
            history_start=config.daily_start, seed=config.seed + 500, live_noise=True,
        )
        overrides = [
            (chosen[0], "pm25", float(thresholds.loc["pm25", "critical_threshold"]) + 8.0),
            (chosen[1], "no2", float(thresholds.loc["no2", "critical_threshold"]) + 9.0),
            (chosen[2], "o3", float(thresholds.loc["o3", "warning_threshold"]) + 12.0),
            (chosen[3], "noise_db", float(thresholds.loc["noise_db", "critical_threshold"]) + 3.0),
        ]
        for grid_id, metric, value in overrides:
            # Small variation across quarters while keeping the hourly mean above threshold.
            frame.loc[frame["grid_id"] == grid_id, metric] = value + (minute / 45.0)
        lines = frame_to_lines(
            frame, measurement="urban_telemetry", tags=RAW_TAG_COLUMNS,
            fields=METRIC_COLUMNS, include_timestamp=False,
        )
        output = LIVE_OUT / f"batch_{minute:02d}.lp"
        output.write_text("\n".join(lines) + "\n", encoding="utf-8")
        result[output.name] = len(lines)
    return result

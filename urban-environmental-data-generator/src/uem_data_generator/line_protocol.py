from __future__ import annotations

import gzip
from pathlib import Path

import pandas as pd

from .config import LINE_PROTOCOL_PRECISION


def escape_measurement(value: str) -> str:
    return value.replace("\\", "\\\\").replace(",", "\\,").replace(" ", "\\ ")


def escape_tag(value: object) -> str:
    return str(value).replace("\\", "\\\\").replace(",", "\\,").replace("=", "\\=").replace(" ", "\\ ")


def float_field(value: object) -> str:
    number = float(value)
    if pd.isna(number):
        raise ValueError("NaN cannot be written to InfluxDB.")
    return format(number, ".10g")


def frame_to_lines(
    frame: pd.DataFrame,
    *,
    measurement: str,
    tags: list[str],
    fields: list[str],
    include_timestamp: bool = True,
) -> list[str]:
    required = [*tags, *fields] + (["timestamp"] if include_timestamp else [])
    missing = [column for column in required if column not in frame.columns]
    if missing:
        raise ValueError(f"Missing columns for line protocol: {missing}")

    timestamps = None
    if include_timestamp:
        timestamps = (
            pd.to_datetime(frame["timestamp"], utc=True, errors="raise")
            .astype(f"datetime64[{LINE_PROTOCOL_PRECISION}, UTC]")
            .astype("int64")
        )

    result: list[str] = []
    columns = [*tags, *fields]
    for idx, values in enumerate(frame[columns].itertuples(index=False, name=None)):
        tag_values = values[:len(tags)]
        field_values = values[len(tags):]
        tag_set = ",".join(f"{key}={escape_tag(value)}" for key, value in zip(tags, tag_values, strict=True))
        field_set = ",".join(f"{key}={float_field(value)}" for key, value in zip(fields, field_values, strict=True))
        line = f"{escape_measurement(measurement)},{tag_set} {field_set}"
        if timestamps is not None:
            line += f" {int(timestamps.iloc[idx])}"
        result.append(line)
    return result


def csv_to_gzip_line_protocol(
    csv_path: Path,
    output_path: Path,
    *,
    measurement: str,
    tags: list[str],
    fields: list[str],
    chunksize: int = 50_000,
) -> int:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    rows = 0
    with gzip.open(output_path, "wt", encoding="utf-8", newline="\n") as target:
        for frame in pd.read_csv(csv_path, chunksize=chunksize):
            lines = frame_to_lines(frame, measurement=measurement, tags=tags, fields=fields)
            if lines:
                target.write("\n".join(lines) + "\n")
                rows += len(lines)
    return rows

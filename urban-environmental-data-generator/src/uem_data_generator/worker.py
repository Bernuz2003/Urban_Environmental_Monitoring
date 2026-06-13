from __future__ import annotations
import argparse, json
from pathlib import Path
from .config import GenerationConfig
from .generation import generate_raw, load_context

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--result-file", required=True)
    parser.add_argument("--reference-time")
    parser.add_argument("--daily-days", type=int, default=1095)
    parser.add_argument("--hourly-days", type=int, default=365)
    parser.add_argument("--raw-days", type=int, default=30)
    parser.add_argument("--raw-interval-minutes", type=int, default=15)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--chunk-days", type=int, default=60)
    parser.add_argument("--zone-limit", type=int)
    args = parser.parse_args()
    config = GenerationConfig.create(
        reference_time=args.reference_time, daily_days=args.daily_days,
        hourly_days=args.hourly_days, raw_days=args.raw_days,
        raw_interval_minutes=args.raw_interval_minutes, seed=args.seed,
        chunk_days=args.chunk_days, zone_limit=args.zone_limit,
    )
    config.validate()
    grid, sensors = load_context(config)
    Path(args.result_file).write_text(json.dumps({"raw_rows": generate_raw(grid, sensors, config)}))
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

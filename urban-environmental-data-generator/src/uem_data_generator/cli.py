from __future__ import annotations
import argparse
from .config import GenerationConfig
from .generation import build_dataset

def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="uem-generate", description="Generate the offline Urban Environmental Monitoring dataset")
    p.add_argument("--reference-time", help="UTC reference time; defaults to the current completed hour")
    p.add_argument("--daily-days", type=int, default=1095)
    p.add_argument("--hourly-days", type=int, default=365)
    p.add_argument("--raw-days", type=int, default=30)
    p.add_argument("--raw-interval-minutes", type=int, default=15)
    p.add_argument("--chunk-days", type=int, default=60)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--zone-limit", type=int)
    p.add_argument("--keep-csv", action="store_true")
    return p

def main() -> int:
    args = parser().parse_args()
    kwargs = dict(
        reference_time=args.reference_time, daily_days=args.daily_days,
        hourly_days=args.hourly_days, raw_days=args.raw_days,
        raw_interval_minutes=args.raw_interval_minutes, chunk_days=args.chunk_days,
        seed=args.seed, zone_limit=args.zone_limit,
    )
    build_dataset(GenerationConfig.create(**kwargs), keep_csv=args.keep_csv)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())

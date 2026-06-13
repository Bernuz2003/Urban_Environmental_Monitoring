#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="${1:-}"
if [[ -z "$SOURCE" || ! -d "$SOURCE" ]]; then
  echo "Usage: $0 /path/to/urban-environmental-dataset" >&2
  exit 2
fi
for dir in postgres influx live; do
  [[ -d "$SOURCE/$dir" ]] || { echo "Missing $SOURCE/$dir" >&2; exit 1; }
done
rm -rf "$ROOT/data/dataset/postgres"/* "$ROOT/data/dataset/influx"/* "$ROOT/data/dataset/live"/*
cp -a "$SOURCE/postgres/." "$ROOT/data/dataset/postgres/"
cp -a "$SOURCE/influx/." "$ROOT/data/dataset/influx/"
cp -a "$SOURCE/live/." "$ROOT/data/dataset/live/"
cp "$SOURCE/manifest.json" "$ROOT/data/dataset/manifest.json"
cp "$SOURCE/checksums.sha256" "$ROOT/data/dataset/checksums.sha256"
(
  cd "$ROOT/data/dataset"
  sha256sum -c checksums.sha256
)
echo "Dataset installed in $ROOT/data/dataset"

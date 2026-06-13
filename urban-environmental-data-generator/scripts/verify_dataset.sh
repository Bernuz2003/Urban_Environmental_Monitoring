#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATASET="${1:-$ROOT/output/urban-environmental-dataset}"
[[ -f "$DATASET/checksums.sha256" ]] || { echo "Missing checksums in $DATASET" >&2; exit 1; }
(cd "$DATASET" && sha256sum -c checksums.sha256)
echo "Dataset checksums are valid."

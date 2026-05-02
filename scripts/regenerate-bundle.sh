#!/usr/bin/env bash
# Regenerates ../vpn-unified-manager-bundle.sh from current sources (run from repo root or this dir).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
exec python3 "$ROOT/scripts/regenerate-bundle.py"

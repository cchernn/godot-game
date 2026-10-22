#!/usr/bin/env bash
# Runs Godot unit tests and FastAPI tests.
set -euo pipefail
cd "$(dirname "$0")/.."
# --import builds the class_name cache on a fresh checkout
scripts/godot.sh --headless --path . --import --quit >/dev/null 2>&1 || true
scripts/godot.sh --headless --path . --script res://tests/run_tests.gd
(cd services/api && uv run --quiet pytest -q)

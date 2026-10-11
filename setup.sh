#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Active Directory Alligator Labs — thin shim
#
# All orchestration logic now lives in setup.py (single source of truth).
# This wrapper just locates python3 and forwards every argument to it.
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if command -v python3 >/dev/null 2>&1; then
    PY=python3
elif command -v python >/dev/null 2>&1; then
    PY=python
else
    echo "ERROR: python3 not found. Install Python 3.8+ first:" >&2
    echo "  https://www.python.org/downloads/" >&2
    echo "  Debian/Ubuntu:  sudo apt install python3" >&2
    exit 1
fi

exec "$PY" "$SCRIPT_DIR/setup.py" "$@"

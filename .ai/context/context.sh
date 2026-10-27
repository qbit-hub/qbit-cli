#!/usr/bin/env bash
set -euo pipefail
script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if ! command -v python3 >/dev/null 2>&1; then
  printf '%s\n' 'Python 3.10+ is required for AI context lifecycle on POSIX hosts.' >&2
  exit 2
fi
if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1; then
  printf '%s\n' 'Python 3.10+ is required for AI context lifecycle on POSIX hosts.' >&2
  exit 2
fi
exec python3 "$script_dir/context.py" "${1:-start}"

#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$("$ROOT/scripts/build.sh")"

exec "$APP" "$@"

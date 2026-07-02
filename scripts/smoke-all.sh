#!/usr/bin/env bash
# Runs every smoke script in scripts/ and aggregates pass/fail.
# Single entry point for local verification and CI gating.
# Exits non-zero if any smoke fails. Usage: ./scripts/smoke-all.sh [repo-path]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${1:-$ROOT}"
LOGDIR="$(mktemp -d)"

# The core smoke uses a bare name; every other smoke matches *-smoke.sh.
smokes=()
[ -f "$ROOT/scripts/smoke.sh" ] && smokes+=("$ROOT/scripts/smoke.sh")
for s in "$ROOT"/scripts/*-smoke.sh; do
  [ -e "$s" ] || continue
  case "$(basename "$s")" in
    smoke-all.sh) continue ;;
  esac
  smokes+=("$s")
done

pass=0
fail=0
skip=0
failed=()
# SMOKE_SKIP is a space-separated list of smoke basenames to skip (e.g. GUI smokes
# under headless CI). Example: SMOKE_SKIP="launch-smoke.sh" ./scripts/smoke-all.sh
for s in "${smokes[@]}"; do
  name="$(basename "$s")"
  if [[ " ${SMOKE_SKIP:-} " == *" $name "* ]]; then
    printf 'SKIP  %s\n' "$name"
    skip=$((skip + 1))
    continue
  fi
  log="$LOGDIR/$name.log"
  # Pass the repo path positionally; smokes that ignore $1 are unaffected.
  if "$s" "$REPO" >"$log" 2>&1; then
    printf 'PASS  %s\n' "$name"
    pass=$((pass + 1))
  else
    code=$?
    printf 'FAIL  %s (exit %d)\n' "$name" "$code"
    fail=$((fail + 1))
    failed+=("$name")
  fi
done

echo ""
echo "smoke-all: $pass passed, $fail failed (of $((pass + fail)))"
if [ "$fail" -ne 0 ]; then
  echo ""
  echo "=== failing smoke logs (tail) ==="
  for name in "${failed[@]}"; do
    echo "--- $name ---"
    tail -20 "$LOGDIR/$name.log"
  done
  exit 1
fi
echo "all smokes green"

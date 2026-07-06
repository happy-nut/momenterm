#!/usr/bin/env bash
# Runs every smoke script in scripts/ and aggregates pass/fail.
# Single entry point for local verification and CI gating.
# Exits non-zero if any smoke fails. Usage: ./scripts/smoke-all.sh [repo-path]
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${1:-$ROOT}"
LOGDIR="$(mktemp -d)"
SMOKE_TIMEOUT_SECONDS="${SMOKE_TIMEOUT_SECONDS:-900}"
SMOKE_FAIL_FAST="${SMOKE_FAIL_FAST:-0}"

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
run_smoke_with_timeout() {
  local script="$1"
  local repo="$2"
  local log="$3"
  local timeout_seconds="$4"
  "$script" "$repo" >"$log" 2>&1 &
  local pid=$!
  local started=$SECONDS
  while kill -0 "$pid" >/dev/null 2>&1; do
    if (( SECONDS - started >= timeout_seconds )); then
      {
        echo ""
        echo "smoke timed out after ${timeout_seconds}s"
      } >>"$log"
      kill "$pid" >/dev/null 2>&1 || true
      sleep 2
      kill -9 "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 1
  done
  wait "$pid"
}

print_failure_summary() {
  echo ""
  echo "=== failing smoke logs (tail) ==="
  for name in "${failed[@]}"; do
    echo "--- $name ---"
    tail -20 "$LOGDIR/$name.log"
  done
}

for s in "${smokes[@]}"; do
  name="$(basename "$s")"
  if [[ " ${SMOKE_SKIP:-} " == *" $name "* ]]; then
    printf 'SKIP  %s\n' "$name"
    skip=$((skip + 1))
    continue
  fi
  log="$LOGDIR/$name.log"
  # Pass the repo path positionally; smokes that ignore $1 are unaffected.
  if run_smoke_with_timeout "$s" "$REPO" "$log" "$SMOKE_TIMEOUT_SECONDS"; then
    printf 'PASS  %s\n' "$name"
    pass=$((pass + 1))
  else
    code=$?
    printf 'FAIL  %s (exit %d)\n' "$name" "$code"
    fail=$((fail + 1))
    failed+=("$name")
    if [[ "$SMOKE_FAIL_FAST" == "1" ]]; then
      break
    fi
  fi
done

echo ""
echo "smoke-all: $pass passed, $fail failed (of $((pass + fail)))"
if [ "$fail" -ne 0 ]; then
  print_failure_summary
  exit 1
fi
echo "all smokes green"

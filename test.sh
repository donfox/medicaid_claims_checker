#!/usr/bin/env bash
# Copyright (c) 2024-2026 Don Fox. All rights reserved.
#
# Runs the frontend use-case tests (phoenix_web/test/use_cases/): every
# mock_data file uploaded through the real Upload and Rules pages and
# evaluated by the real rule engine.
#
#   ./test.sh            every use case
#   ./test.sh R5 N7      only these use cases
#
# Starts its own engine on a spare port and stops it afterwards, so an
# engine or app you already have running (./start.sh) is left alone. Needs
# Postgres, like `mix test`.
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$ROOT_DIR/logs"
ENGINE_LOG="$LOG_DIR/test_engine.log"
ENGINE_PORT="${TEST_ENGINE_PORT:-8092}"
ENGINE_PID=""

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  sed -n '4,13p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

stop_engine() {
  if [[ -n "$ENGINE_PID" ]] && kill -0 "$ENGINE_PID" 2>/dev/null; then
    kill "$ENGINE_PID" 2>/dev/null || true
    wait "$ENGINE_PID" 2>/dev/null || true
  fi
}
trap stop_engine EXIT

if nc -z 127.0.0.1 "$ENGINE_PORT" 2>/dev/null; then
  echo "Port $ENGINE_PORT is in use. Choose another: TEST_ENGINE_PORT=8093 ./test.sh" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
echo "Building the rule engine..."
(cd "$ROOT_DIR/haskell_engine" && stack build 2>&1 | grep -E "^(Error|.*error)" || true)

# The tests can make more than the engine's default 1000 requests a minute.
export RULE_ENGINE_SECRET="${RULE_ENGINE_SECRET:-dev-secret-change-in-production}"
(cd "$ROOT_DIR/haskell_engine" &&
  ENGINE_PORT="$ENGINE_PORT" ENGINE_RATE_LIMIT=100000 exec stack exec medicaid-claims-dsl-server) >"$ENGINE_LOG" 2>&1 &
ENGINE_PID=$!

for _ in $(seq 1 60); do
  nc -z 127.0.0.1 "$ENGINE_PORT" 2>/dev/null && break
  if ! kill -0 "$ENGINE_PID" 2>/dev/null; then
    echo "The engine did not start; see $ENGINE_LOG" >&2
    exit 1
  fi
  sleep 0.5
done
echo "Test engine running on port $ENGINE_PORT (log: $ENGINE_LOG)"

ONLY=(--only use_case)
if [[ $# -gt 0 ]]; then
  ONLY=()
  for id in "$@"; do ONLY+=(--only "use_case:$id"); done
fi

cd "$ROOT_DIR/phoenix_web"
RULE_ENGINE_URL="http://127.0.0.1:$ENGINE_PORT" mix test "${ONLY[@]}" test/use_cases

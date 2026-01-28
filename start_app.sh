#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$ROOT_DIR/logs"
BACKEND_LOG="$LOG_DIR/backend.log"
FRONTEND_LOG="$LOG_DIR/frontend.log"
BACKEND_PID=""
FRONTEND_PID=""
RUN_INSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      RUN_INSTALL=1
      shift
      ;;
    -h|--help)
      echo "Usage: ./start_app.sh [--install]"
      echo "  --install   Fetch/build dependencies before starting services"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$LOG_DIR"

cleanup() {
  echo "Stopping services..."
  [[ -n "$BACKEND_PID" ]] && kill "$BACKEND_PID" 2>/dev/null || true
  [[ -n "$FRONTEND_PID" ]] && kill "$FRONTEND_PID" 2>/dev/null || true
}
trap cleanup EXIT

ensure_backend_deps() {
  cd "$ROOT_DIR/haskell_engine"
  echo "Ensuring Haskell dependencies (stack build --only-dependencies --fast)..."
  stack build --only-dependencies --fast
}

ensure_frontend_deps() {
  cd "$ROOT_DIR/phoenix_web"
  echo "Ensuring Phoenix dependencies (mix deps.get)..."
  mix deps.get
}

start_backend() {
  cd "$ROOT_DIR/haskell_engine"
  echo "Starting Haskell backend on port 8080... (logs: $BACKEND_LOG)"
  stack run >>"$BACKEND_LOG" 2>&1 &
  BACKEND_PID=$!
}

start_frontend() {
  cd "$ROOT_DIR/phoenix_web"
  echo "Starting Phoenix frontend on port 4000... (logs: $FRONTEND_LOG)"
  mix phx.server >>"$FRONTEND_LOG" 2>&1 &
  FRONTEND_PID=$!
}

if [[ "$RUN_INSTALL" -eq 1 ]]; then
  ensure_backend_deps
  ensure_frontend_deps
fi

start_backend
start_frontend

echo "Haskell backend PID: $BACKEND_PID"
echo "Phoenix frontend PID: $FRONTEND_PID"
echo "Services are starting. Tail logs with:"
echo "  tail -f $BACKEND_LOG"
echo "  tail -f $FRONTEND_LOG"

echo "Press Ctrl+C to stop both services."
wait

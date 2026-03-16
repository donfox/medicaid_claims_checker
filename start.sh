#!/usr/bin/env bash
# Copyright (c) 2024-2026 Don Fox. All rights reserved.
#
# Starts all three services that make up the Medicaid Claims Checker system:
#   1. Haskell rule engine      (port 8080)
#   2. Phoenix frontend/API     (port 4000)
#   3. X12Translator            (port 4001)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X12_DIR="/Users/donfox1/Work/X12Translator"
LOG_DIR="$ROOT_DIR/logs"
BACKEND_LOG="$LOG_DIR/backend.log"
FRONTEND_LOG="$LOG_DIR/frontend.log"
X12_LOG="$LOG_DIR/x12translator.log"
BACKEND_PID=""
FRONTEND_PID=""
X12_PID=""
RUN_INSTALL=0
RUN_BACKEND=0
RUN_FRONTEND=0
RUN_X12=0
FOREGROUND=0

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --install)
      RUN_INSTALL=1
      shift
      ;;
    --backend)
      RUN_BACKEND=1
      shift
      ;;
    --frontend)
      RUN_FRONTEND=1
      shift
      ;;
    --x12)
      RUN_X12=1
      shift
      ;;
    --foreground|-f)
      FOREGROUND=1
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: ./start.sh [OPTIONS]

Start the Medicaid Claims Checker system (all three services)

SERVICES:
  Haskell rule engine      http://localhost:8080
  Phoenix frontend/API     http://localhost:4000
  X12Translator            http://localhost:4001

OPTIONS:
  --install      Install/update dependencies before starting
  --backend      Start only the Haskell backend (port 8080)
  --frontend     Start only the Phoenix frontend (port 4000)
  --x12          Start only the X12Translator (port 4001)
  --foreground   Run in foreground (no background logging)
  -h, --help     Show this help message

Any ports in use will be freed automatically before starting.

EXAMPLES:
  ./start.sh                    # Start all three services
  ./start.sh --install          # Install deps and start all
  ./start.sh --backend          # Start only backend
  ./start.sh --frontend --x12   # Start Phoenix + X12Translator only
  ./start.sh --frontend -f      # Start only frontend in foreground

LOGS:
  Backend:        $BACKEND_LOG
  Frontend:       $FRONTEND_LOG
  X12Translator:  $X12_LOG
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      echo "Run './start.sh --help' for usage information"
      exit 1
      ;;
  esac
done

# If no service specified, run all three
if [[ $RUN_BACKEND -eq 0 ]] && [[ $RUN_FRONTEND -eq 0 ]] && [[ $RUN_X12 -eq 0 ]]; then
  RUN_BACKEND=1
  RUN_FRONTEND=1
  RUN_X12=1
fi

# Create log directory
mkdir -p "$LOG_DIR"

# Cleanup function
cleanup() {
  echo ""
  echo "Stopping services..."
  [[ -n "$BACKEND_PID" ]] && kill "$BACKEND_PID" 2>/dev/null && echo "  Stopped Haskell backend (PID $BACKEND_PID)" || true
  [[ -n "$FRONTEND_PID" ]] && kill "$FRONTEND_PID" 2>/dev/null && echo "  Stopped Phoenix frontend (PID $FRONTEND_PID)" || true
  [[ -n "$X12_PID" ]] && kill "$X12_PID" 2>/dev/null && echo "  Stopped X12Translator (PID $X12_PID)" || true
}
trap cleanup EXIT INT TERM

# Kill any process on a given port
free_port() {
  local port="$1"
  local service_name="$2"
  local pids

  pids="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    echo "Port $port ($service_name) in use — killing existing listener(s)..."
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && kill -9 "$pid" 2>/dev/null || true
    done <<< "$pids"
    sleep 1
  fi
}

# Dependency installation
ensure_backend_deps() {
  cd "$ROOT_DIR/haskell_engine"
  echo "Installing Haskell dependencies..."
  stack build --only-dependencies --fast
}

ensure_frontend_deps() {
  cd "$ROOT_DIR/phoenix_web"
  echo "Installing Phoenix dependencies..."
  mix deps.get
}

ensure_x12_deps() {
  cd "$X12_DIR"
  echo "Installing X12Translator dependencies..."
  mix deps.get
}

# Run migrations
run_migrations() {
  echo "Running migrations..."
  cd "$ROOT_DIR/phoenix_web" && mix ecto.migrate --quiet 2>/dev/null || true
  cd "$X12_DIR" && mix ecto.migrate --quiet 2>/dev/null || true
}

# Service starters
start_backend() {
  cd "$ROOT_DIR/haskell_engine"
  if [[ $FOREGROUND -eq 1 ]]; then
    echo "Starting Haskell backend on port 8080 (foreground)..."
    exec stack run
  else
    echo "Starting Haskell backend on port 8080..."
    stack run >>"$BACKEND_LOG" 2>&1 &
    BACKEND_PID=$!
  fi
}

start_frontend() {
  cd "$ROOT_DIR/phoenix_web"
  if [[ $FOREGROUND -eq 1 ]]; then
    echo "Starting Phoenix frontend on port 4000 (foreground)..."
    exec mix phx.server
  else
    echo "Starting Phoenix frontend on port 4000..."
    mix phx.server >>"$FRONTEND_LOG" 2>&1 &
    FRONTEND_PID=$!
  fi
}

start_x12() {
  cd "$X12_DIR"
  if [[ $FOREGROUND -eq 1 ]]; then
    echo "Starting X12Translator on port 4001 (foreground)..."
    PORT=4001 exec mix phx.server
  else
    echo "Starting X12Translator on port 4001..."
    PORT=4001 mix phx.server >>"$X12_LOG" 2>&1 &
    X12_PID=$!
  fi
}

# Install dependencies if requested
if [[ $RUN_INSTALL -eq 1 ]]; then
  [[ $RUN_BACKEND -eq 1 ]] && ensure_backend_deps
  [[ $RUN_FRONTEND -eq 1 ]] && ensure_frontend_deps
  [[ $RUN_X12 -eq 1 ]] && ensure_x12_deps
fi

# Free ports automatically
[[ $RUN_BACKEND -eq 1 ]] && free_port 8080 "Haskell backend"
[[ $RUN_FRONTEND -eq 1 ]] && free_port 4000 "Phoenix frontend"
[[ $RUN_X12 -eq 1 ]] && free_port 4001 "X12Translator"

# Run migrations
run_migrations

# Start services
[[ $RUN_BACKEND -eq 1 ]] && start_backend
[[ $RUN_FRONTEND -eq 1 ]] && start_frontend
[[ $RUN_X12 -eq 1 ]] && start_x12

# Show status for background mode
if [[ $FOREGROUND -eq 0 ]]; then
  echo ""
  echo "=========================================="
  echo "  Medicaid Claims Checker System - Running"
  echo "=========================================="
  echo ""
  echo "Services:"
  [[ -n "$BACKEND_PID" ]] && echo "  • Haskell backend:   PID $BACKEND_PID  →  http://localhost:8080"
  [[ -n "$FRONTEND_PID" ]] && echo "  • Phoenix frontend:  PID $FRONTEND_PID  →  http://localhost:4000"
  [[ -n "$X12_PID" ]] && echo "  • X12Translator:     PID $X12_PID  →  http://localhost:4001"
  echo ""
  echo "Logs:"
  [[ -n "$BACKEND_PID" ]] && echo "  • tail -f $BACKEND_LOG"
  [[ -n "$FRONTEND_PID" ]] && echo "  • tail -f $FRONTEND_LOG"
  [[ -n "$X12_PID" ]] && echo "  • tail -f $X12_LOG"
  echo ""
  echo "Press Ctrl+C to stop all services."
  echo ""
  wait
fi

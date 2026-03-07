#!/usr/bin/env bash
# Copyright (c) 2024-2026 Don Fox. All rights reserved.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$ROOT_DIR/logs"
BACKEND_LOG="$LOG_DIR/backend.log"
FRONTEND_LOG="$LOG_DIR/frontend.log"
BACKEND_PID=""
FRONTEND_PID=""
RUN_INSTALL=0
RUN_BACKEND=0
RUN_FRONTEND=0
FOREGROUND=0
FORCE_KILL_PORTS=0

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
    --foreground|-f)
      FOREGROUND=1
      shift
      ;;
    --force-kill-ports)
      FORCE_KILL_PORTS=1
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: ./start.sh [OPTIONS]

Start the Medicaid Claims Checker DSL services (Haskell backend + Phoenix frontend)

OPTIONS:
  --install      Install/update dependencies before starting
  --backend      Start only the Haskell backend (port 8080)
  --frontend     Start only the Phoenix frontend (port 4000)
  --foreground   Run in foreground (no background logging)
  --force-kill-ports  Kill existing listeners on required ports before starting
  -h, --help     Show this help message

EXAMPLES:
  ./start.sh                    # Start both services in background
  ./start.sh --install          # Install deps and start both
  ./start.sh --backend          # Start only backend
  ./start.sh --frontend -f      # Start only frontend in foreground
  ./start.sh --force-kill-ports # Kill conflicting port listeners then start
  ./start.sh --backend --frontend --install  # Explicit: both with install

LOGS:
  Backend:  $BACKEND_LOG
  Frontend: $FRONTEND_LOG
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

# If no service specified, run both
if [[ $RUN_BACKEND -eq 0 ]] && [[ $RUN_FRONTEND -eq 0 ]]; then
  RUN_BACKEND=1
  RUN_FRONTEND=1
fi

# Create log directory
mkdir -p "$LOG_DIR"

# Cleanup function
cleanup() {
  echo ""
  echo "Stopping services..."
  [[ -n "$BACKEND_PID" ]] && kill "$BACKEND_PID" 2>/dev/null && echo "  Stopped backend (PID $BACKEND_PID)" || true
  [[ -n "$FRONTEND_PID" ]] && kill "$FRONTEND_PID" 2>/dev/null && echo "  Stopped frontend (PID $FRONTEND_PID)" || true
}
trap cleanup EXIT INT TERM

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

check_port_available() {
  local port="$1"
  local service_name="$2"
  local pids
  local pid

  pids="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)"
  if [[ -n "$pids" ]] && [[ $FORCE_KILL_PORTS -eq 1 ]]; then
    echo "Port $port is in use. Stopping existing listener(s)..."
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    done <<< "$pids"
    sleep 1
    pids="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)"
  fi

  if [[ -n "$pids" ]]; then
    pid="$(echo "$pids" | head -n 1)"
    local process_info
    process_info="$(ps -p "$pid" -o command= 2>/dev/null || echo "unknown process")"
    echo ""
    echo "ERROR: Port $port is already in use ($service_name cannot start)."
    echo "  PID: $pid"
    echo "  Process: $process_info"
    echo ""
    echo "Stop the conflicting process and retry."
    echo "Example: kill $pid"
    exit 1
  fi
}

# Service starters
start_backend() {
  cd "$ROOT_DIR/haskell_engine"
  if [[ $FOREGROUND -eq 1 ]]; then
    echo "Starting Haskell backend on port 8080 (foreground)..."
    exec stack run
  else
    echo "Starting Haskell backend on port 8080... (logs: $BACKEND_LOG)"
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
    echo "Starting Phoenix frontend on port 4000... (logs: $FRONTEND_LOG)"
    mix phx.server >>"$FRONTEND_LOG" 2>&1 &
    FRONTEND_PID=$!
  fi
}

# Install dependencies if requested
if [[ $RUN_INSTALL -eq 1 ]]; then
  [[ $RUN_BACKEND -eq 1 ]] && ensure_backend_deps
  [[ $RUN_FRONTEND -eq 1 ]] && ensure_frontend_deps
fi

# Pre-flight port checks
[[ $RUN_BACKEND -eq 1 ]] && check_port_available 8080 "Haskell backend"
[[ $RUN_FRONTEND -eq 1 ]] && check_port_available 4000 "Phoenix frontend"

# Start services
[[ $RUN_BACKEND -eq 1 ]] && start_backend
[[ $RUN_FRONTEND -eq 1 ]] && start_frontend

# Show status for background mode
if [[ $FOREGROUND -eq 0 ]]; then
  echo ""
  echo "======================================"
  echo "  Medicaid Claims Checker DSL - Running"
  echo "======================================"
  echo ""
  echo "Services:"
  [[ -n "$BACKEND_PID" ]] && echo "  • Backend API:  PID $BACKEND_PID"
  [[ -n "$FRONTEND_PID" ]] && echo "  • Frontend UI:  PID $FRONTEND_PID"
  echo ""
  if [[ -n "$FRONTEND_PID" ]]; then
    echo "Frontend URLs:"
    echo "  • UI:      http://localhost:4000"
    echo "  • Health:  http://localhost:4000/api/health"
    echo ""
  fi
  if [[ -n "$BACKEND_PID" ]]; then
    echo "Backend URLs:"
    echo "  • API:     http://localhost:8080"
    echo "  • Health:  http://localhost:8080/api/health"
  fi
  echo ""
  echo "Logs:"
  [[ -n "$BACKEND_PID" ]] && echo "  • tail -f $BACKEND_LOG"
  [[ -n "$FRONTEND_PID" ]] && echo "  • tail -f $FRONTEND_LOG"
  echo ""
  echo "Press Ctrl+C to stop services."
  echo ""
  wait
fi

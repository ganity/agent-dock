#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM

  if [[ -n "${frontend_pid:-}" ]] && kill -0 "$frontend_pid" 2>/dev/null; then
    kill "$frontend_pid" 2>/dev/null || true
    wait "$frontend_pid" 2>/dev/null || true
  fi

  if [[ -n "${daemon_pid:-}" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi

  exit "$exit_code"
}

trap cleanup EXIT INT TERM

echo "[agent-dock] starting daemon on 0.0.0.0:4123"
cargo run -p agent-dock-daemon &
daemon_pid=$!

echo "[agent-dock] starting frontend on 0.0.0.0:4950"
(
  cd frontend
  npm run dev -- --host 0.0.0.0 --port 4950
) &
frontend_pid=$!

wait -n "$daemon_pid" "$frontend_pid"

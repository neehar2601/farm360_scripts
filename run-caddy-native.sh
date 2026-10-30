#!/usr/bin/env bash
# Run Caddy (reverse proxy) natively — no Docker.
#   ./docker/run-caddy-native.sh           download (first run) + start in background
#   ./docker/run-caddy-native.sh --stop    stop it
#   ./docker/run-caddy-native.sh --reload  apply Caddyfile changes without downtime
# Public entrypoint: http://<server-ip>/   (port 80; admin portal on :8081)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="$ROOT/.bin"
CADDY="$BIN_DIR/caddy"
CADDYFILE="$ROOT/docker/Caddyfile"
LOGS_DIR="$ROOT/.logs"
PID_FILE="$LOGS_DIR/caddy.pid"
mkdir -p "$BIN_DIR" "$LOGS_DIR"

is_running() { [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; }

case "${1:-}" in
  --stop)
    if is_running; then kill "$(cat "$PID_FILE")"; rm -f "$PID_FILE"; echo "✅ Caddy stopped"; else echo "Caddy is not running"; fi
    exit 0 ;;
  --reload)
    "$CADDY" reload --config "$CADDYFILE" --adapter caddyfile; exit 0 ;;
esac

if is_running; then echo "Caddy already running (PID $(cat "$PID_FILE")). Use --reload or --stop."; exit 0; fi

# 1) Get the Caddy binary (single static file, no root/package manager needed)
if [ ! -x "$CADDY" ]; then
  case "$(uname -m)" in
    x86_64|amd64)  ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "❌ Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
  echo "⬇️  Downloading Caddy ($ARCH)…"
  curl -fsSL "https://caddyserver.com/api/download?os=linux&arch=${ARCH}" -o "$CADDY"
  chmod +x "$CADDY"
fi

# 2) Allow binding to port 80 without running Caddy as root
if ! getcap "$CADDY" 2>/dev/null | grep -q cap_net_bind_service; then
  echo "🔑 Granting port-80 permission (needs sudo once)…"
  sudo setcap cap_net_bind_service=+ep "$CADDY"
fi

# 3) Validate, then start detached
"$CADDY" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null
setsid "$CADDY" run --config "$CADDYFILE" --adapter caddyfile >"$LOGS_DIR/caddy.log" 2>&1 &
echo $! > "$PID_FILE"
sleep 1
if is_running; then
  echo "✅ Caddy running (PID $(cat "$PID_FILE"))  logs: .logs/caddy.log"
  echo "   App:   http://<server-ip>/"
  echo "   Admin: http://<server-ip>:8081/"
else
  echo "❌ Caddy failed to start — see .logs/caddy.log"; exit 1
fi

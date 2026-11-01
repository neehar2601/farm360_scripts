#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  farm360 — Full Stack Startup Script
#  Usage:  ./start.sh                    start all services (exits, runs in bg)
#          ./start.sh --stop             stop all background services
#          ./start.sh --restart          stop + start all services
#          ./start.sh --skip-migrations  skip migration check
#          ./start.sh --prod             use `npm start` instead of `npm run dev`
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Resolve script location so it works from anywhere ─────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Paths ──────────────────────────────────────────────────────────────────────
DB_DIR="$SCRIPT_DIR/farm360_db"
AUTH_DIR="$SCRIPT_DIR/farm360_backend/auth-service"
FARM_DIR="$SCRIPT_DIR/farm360_backend/farm-service"
WORKER_DIR="$SCRIPT_DIR/farm360_backend/worker-service"
SP_DIR="$SCRIPT_DIR/farm360_backend/sp-service"
FRONTEND_DIR="$SCRIPT_DIR/farm360_frontend"
ADMIN_DIR="$SCRIPT_DIR/farm360_admin"
LOGS_DIR="$SCRIPT_DIR/.logs"
PID_FILE="$LOGS_DIR/farm360.pids"

# ── Ports ──────────────────────────────────────────────────────────────────────
AUTH_PORT=4000
FARM_PORT=4001
WORKER_PORT=4002
SP_PORT=4003
FRONTEND_PORT=5173
ADMIN_PORT=5174

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ── Flags ──────────────────────────────────────────────────────────────────────
SKIP_MIGRATIONS=false
PROD_MODE=false
STOP_MODE=false
RESTART_MODE=false
START_CADDY=true
for arg in "$@"; do
  case "$arg" in
    --skip-migrations) SKIP_MIGRATIONS=true ;;
    --prod)            PROD_MODE=true ;;
    --stop)            STOP_MODE=true ;;
    --restart)         RESTART_MODE=true ;;
    --no-caddy)        START_CADDY=false ;;
  esac
done

NPM_CMD="npm run dev"
$PROD_MODE && NPM_CMD="npm start"

# ── Helpers ────────────────────────────────────────────────────────────────────
log()     { echo -e "${CYAN}[farm360]${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}  ✅  $*${RESET}"; }
warn()    { echo -e "${YELLOW}  ⚠️   $*${RESET}"; }
error()   { echo -e "${RED}${BOLD}  ❌  $*${RESET}"; }
section() { echo -e "\n${BLUE}${BOLD}━━━  $*  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"; }

# ── Stop all services (reads PID file + kills by port as fallback) ─────────────
stop_all() {
  local silent="${1:-false}"
  $silent || echo -e "\n${YELLOW}${BOLD}⛔  Stopping all farm360 services…${RESET}"

  # Kill saved PIDs (and their entire process groups)
  if [ -f "$PID_FILE" ]; then
    while IFS= read -r pid; do
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        $silent || echo -e "  ${DIM}Killing PID $pid${RESET}"
        kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
      fi
    done < "$PID_FILE"
    rm -f "$PID_FILE"
  fi

  # Stop Caddy reverse proxy if running
  if [ -f "$SCRIPT_DIR/docker/run-caddy-native.sh" ]; then
    "$SCRIPT_DIR/docker/run-caddy-native.sh" --stop >/dev/null 2>&1 || true
  fi

  # Fallback: kill anything still on our ports (including parent nodemon)
  for port in "$AUTH_PORT" "$FARM_PORT" "$WORKER_PORT" "$SP_PORT" "$FRONTEND_PORT" "$ADMIN_PORT"; do
    local pids_on_port
    pids_on_port=$(lsof -ti ":${port}" 2>/dev/null || true)
    if [ -n "$pids_on_port" ]; then
      $silent || echo -e "  ${DIM}Killing leftover process(es) on :${port}${RESET}"
      for p in $pids_on_port; do
        local ppid
        ppid=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ' || true)
        [ -n "$ppid" ] && [ "$ppid" -gt 1 ] && kill -9 "$ppid" 2>/dev/null || true
        kill -9 "$p" 2>/dev/null || true
      done
    fi
  done

  sleep 1
  $silent || echo -e "${GREEN}✅  All services stopped.${RESET}\n"
}

# ── Handle --stop ──────────────────────────────────────────────────────────────
if $STOP_MODE; then
  stop_all false
  exit 0
fi

# ── Handle --restart (stop silently then fall through to normal start) ─────────
if $RESTART_MODE; then
  echo -e "\n${YELLOW}${BOLD}🔄  Restarting all services…${RESET}"
  stop_all true
  echo -e "${GREEN}  ✅  Old services stopped — starting fresh…${RESET}\n"
fi

# ── Check if a port is already in use ─────────────────────────────────────────
port_in_use() {
  local port="$1"
  ss -tlnp 2>/dev/null | grep -q ":${port} " || \
  lsof -i ":${port}" -sTCP:LISTEN -t 2>/dev/null | grep -q . 2>/dev/null
}

# ── Wait for a service to respond on a port (up to 30s) ───────────────────────
wait_for_port() {
  local name="$1"
  local port="$2"
  local max_wait=30
  local count=0
  printf "     ${DIM}Waiting for %s on :%s " "$name" "$port"
  while ! curl -sf "http://localhost:${port}/health" >/dev/null 2>&1; do
    sleep 1
    count=$((count + 1))
    printf "."
    if [ "$count" -ge "$max_wait" ]; then
      echo ""
      error "$name did not start within ${max_wait}s — check ${LOGS_DIR}/${name}.log"
      return 1
    fi
  done
  echo -e "${RESET}"
  success "$name is up  →  http://localhost:${port}"
}

# ── Start a service in the background, save PID, log to file ──────────────────
start_service() {
  local name="$1"
  local dir="$2"
  local cmd="$3"
  local logfile="${LOGS_DIR}/${name}.log"

  log "Starting ${BOLD}${name}${RESET} …"
  mkdir -p "$LOGS_DIR"

  # Rotate log (keep last run)
  [ -f "$logfile" ] && mv "$logfile" "${logfile}.prev" 2>/dev/null || true

  # setsid detaches the child from this terminal so it survives script exit
  setsid bash -c "cd '$dir' && exec $cmd" >"$logfile" 2>&1 &
  local pid=$!
  echo "$pid" >> "$PID_FILE"
}

# ── Banner ─────────────────────────────────────────────────────────────────────
echo -e ""
echo -e "${GREEN}${BOLD}  ███████╗ █████╗ ██████╗ ███╗   ███╗ ██████╗  ██████╗  ██████╗ ${RESET}"
echo -e "${GREEN}${BOLD}  ██╔════╝██╔══██╗██╔══██╗████╗ ████║╚════██╗██╔════╝ ██╔═████╗${RESET}"
echo -e "${GREEN}${BOLD}  █████╗  ███████║██████╔╝██╔████╔██║ █████╔╝███████╗ ██║██╔██║${RESET}"
echo -e "${GREEN}${BOLD}  ██╔══╝  ██╔══██║██╔══██╗██║╚██╔╝██║ ╚═══██╗██╔═══██╗████╔╝██║${RESET}"
echo -e "${GREEN}${BOLD}  ██║     ██║  ██║██║  ██║██║ ╚═╝ ██║██████╔╝╚██████╔╝╚██████╔╝${RESET}"
echo -e "${GREEN}${BOLD}  ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝╚═════╝  ╚═════╝  ╚═════╝ ${RESET}"
echo ""
echo -e "  ${DIM}Full Stack Startup  │  $(date '+%Y-%m-%d %H:%M:%S')${RESET}"
echo -e "  ${DIM}Mode: $($PROD_MODE && echo 'Production (npm start)' || echo 'Development (nodemon)')${RESET}"
$RESTART_MODE && echo -e "  ${YELLOW}${BOLD}↺  Restarted (old services were stopped)${RESET}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 1 — Preflight checks
# ══════════════════════════════════════════════════════════════════════════════
section "PREFLIGHT CHECKS"

# Node.js
if ! command -v node &>/dev/null; then
  error "Node.js is not installed. Please install Node.js >= 18."; exit 1
fi
NODE_VER=$(node --version)
success "Node.js $NODE_VER"

# PostgreSQL connectivity check using DB_DIR env
DB_HOST="${DB_HOST:-localhost}"
DB_PORT_PG="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-farm360}"
DB_USER="${DB_USER:-farm360}"
DB_PASSWORD="${DB_PASSWORD:-farmsync@360}"

if command -v psql &>/dev/null; then
  if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT_PG" -U "$DB_USER" -d "$DB_NAME" -c '\q' >/dev/null 2>&1; then
    success "PostgreSQL reachable at ${DB_HOST}:${DB_PORT_PG}/${DB_NAME}"
  else
    error "Cannot connect to PostgreSQL at ${DB_HOST}:${DB_PORT_PG}/${DB_NAME}"
    error "Make sure PostgreSQL is running and credentials are correct."
    exit 1
  fi
else
  warn "psql not in PATH — skipping DB reachability check"
fi

# Port conflict detection
echo ""
CONFLICTS=false
for svc_info in "${AUTH_PORT}:auth-service" "${FARM_PORT}:farm-service" "${WORKER_PORT}:worker-service" "${SP_PORT}:sp-service" "${FRONTEND_PORT}:frontend"; do
  svc_port="${svc_info%%:*}"
  svc_name="${svc_info##*:}"
  if port_in_use "$svc_port"; then
    warn "Port ${BOLD}:${svc_port}${RESET}${YELLOW} is already in use — ${svc_name} may fail to start"
    CONFLICTS=true
  fi
done
$CONFLICTS || success "All ports are free (:${AUTH_PORT}, :${FARM_PORT}, :${WORKER_PORT}, :${SP_PORT}, :${FRONTEND_PORT})"

# Service-provider DB (isolated from the farmer DB). Created once via
# farm360_backend/sp-service/scripts/setup-db.sh (needs a postgres superuser).
SP_DB_NAME="${SP_DB_NAME:-farm360_sp}"
SP_DB_READY=false
if command -v psql &>/dev/null; then
  if PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT_PG" -U "$DB_USER" -d "$SP_DB_NAME" -c '\q' >/dev/null 2>&1; then
    SP_DB_READY=true
    success "Service-provider DB reachable (${SP_DB_NAME})"
  else
    warn "Database '${SP_DB_NAME}' not found — sp-service will be skipped"
    warn "Create it once with: ${BOLD}./farm360_db/sp/setup-db.sh${RESET}"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 2 — Database migrations
# ══════════════════════════════════════════════════════════════════════════════
section "DATABASE MIGRATIONS"

if $SKIP_MIGRATIONS; then
  warn "--skip-migrations flag set — skipping migration check"
else
  if [ ! -f "$DB_DIR/run_migrations.js" ]; then
    error "Migration runner not found at $DB_DIR/run_migrations.js"; exit 1
  fi

  log "Checking and applying migrations …"

  MIGRATION_LOG="${LOGS_DIR}/migrations.log"
  mkdir -p "$LOGS_DIR"

  # Run migration status + apply, capturing output to log only
  (cd "$DB_DIR" && node run_migrations.js --status 2>&1 || true) >> "$MIGRATION_LOG"
  MIGRATION_OUTPUT=$(cd "$DB_DIR" && node run_migrations.js 2>&1 || true)
  echo "$MIGRATION_OUTPUT" >> "$MIGRATION_LOG"

  if echo "$MIGRATION_OUTPUT" | grep -qE "❌|FAILED|Fatal error"; then
    error "Migration failed — check ${MIGRATION_LOG}"
    exit 1
  fi

  success "Database schema is up to date"

  if $SP_DB_READY; then
    SP_MIGRATION_OUTPUT=$(cd "$DB_DIR/sp" && node migrate.js 2>&1 || true)
    echo "$SP_MIGRATION_OUTPUT" >> "$MIGRATION_LOG"
    if echo "$SP_MIGRATION_OUTPUT" | grep -qE "❌|FAILED|Fatal error"; then
      error "Service-provider migration failed — check ${MIGRATION_LOG}"
      exit 1
    fi
    success "Service-provider schema is up to date"
  fi
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 3 — Start backend services (sequentially so each is healthy before next)
# ══════════════════════════════════════════════════════════════════════════════
section "STARTING BACKEND SERVICES"

# Clear old PID file before writing new ones
rm -f "$PID_FILE"

# Auth service (must be first — other services may validate tokens via auth)
start_service "auth-service"   "$AUTH_DIR"   "$NPM_CMD"
wait_for_port  "auth-service"   "$AUTH_PORT"

# Farm service
start_service "farm-service"   "$FARM_DIR"   "$NPM_CMD"
wait_for_port  "farm-service"   "$FARM_PORT"

# Worker service
start_service "worker-service" "$WORKER_DIR" "$NPM_CMD"
wait_for_port  "worker-service" "$WORKER_PORT"

# Service-provider service (own DB + own identity; non-fatal if DB not set up yet)
if $SP_DB_READY; then
  start_service "sp-service" "$SP_DIR" "$NPM_CMD"
  wait_for_port  "sp-service" "$SP_PORT" || warn "sp-service failed to start — other services are unaffected"
else
  warn "Skipping sp-service (database not set up)"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 4 — Start frontend (last, after all APIs are healthy)
# ══════════════════════════════════════════════════════════════════════════════
section "STARTING FRONTEND"

start_service "frontend" "$FRONTEND_DIR" "npm run dev"

# Vite doesn't expose /health — poll root instead
printf "     ${DIM}Waiting for frontend on :${FRONTEND_PORT} "
count=0
while ! curl -sf "http://localhost:${FRONTEND_PORT}" >/dev/null 2>&1; do
  sleep 1
  count=$((count + 1))
  printf "."
  if [ "$count" -ge 30 ]; then
    echo -e "${RESET}"
    warn "Frontend did not respond within 30s — it may still be compiling"
    warn "Check logs: ${LOGS_DIR}/frontend.log"
    break
  fi
done
echo -e "${RESET}"
success "Frontend is up  →  http://localhost:${FRONTEND_PORT}"

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 5 — Start admin portal
# ══════════════════════════════════════════════════════════════════════════════
section "STARTING ADMIN PORTAL"

start_service "admin" "$ADMIN_DIR" "npm run dev"

printf "     ${DIM}Waiting for admin portal on :${ADMIN_PORT} "
count=0
while ! curl -sf "http://localhost:${ADMIN_PORT}" >/dev/null 2>&1; do
  sleep 1
  count=$((count + 1))
  printf "."
  if [ "$count" -ge 30 ]; then
    echo -e "${RESET}"
    warn "Admin portal did not respond within 30s — it may still be compiling"
    warn "Check logs: ${LOGS_DIR}/admin.log"
    break
  fi
done
echo -e "${RESET}"
success "Admin portal is up  →  http://localhost:${ADMIN_PORT}"

# ══════════════════════════════════════════════════════════════════════════════
#  STEP 6 — Start Caddy reverse proxy (ports 80 & 8081)
# ══════════════════════════════════════════════════════════════════════════════
section "REVERSE PROXY (CADDY)"

CADDY_RUNNING=false
if $START_CADDY; then
  if [ -x "$SCRIPT_DIR/docker/run-caddy-native.sh" ]; then
    "$SCRIPT_DIR/docker/run-caddy-native.sh" && CADDY_RUNNING=true || warn "Caddy failed to start; services remain accessible on localhost ports."
  else
    warn "docker/run-caddy-native.sh not executable or not found"
  fi
else
  warn "Skipping Caddy (--no-caddy flag specified)"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  ALL SYSTEMS GO — script exits here, services keep running in the background
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}${BOLD}┌─────────────────────────────────────────────────────────┐${RESET}"
echo -e "${GREEN}${BOLD}│           🌱  farm360 is fully running!  🌱             │${RESET}"
echo -e "${GREEN}${BOLD}├─────────────────────────────────────────────────────────┤${RESET}"
if $CADDY_RUNNING; then
echo -e "${GREEN}${BOLD}│${RESET}  ${BOLD}Public Gateways (Caddy):${RESET}                               ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}│${RESET}    App           →  ${CYAN}http://localhost/${RESET} (port 80)           ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}│${RESET}    Admin Portal  →  ${CYAN}http://localhost:8081/${RESET}                ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}│${RESET}                                                         ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}│${RESET}  ${DIM}Internal Services (bound to 127.0.0.1):${RESET}                ${GREEN}${BOLD}│${RESET}"
fi
echo -e "${GREEN}${BOLD}│${RESET}    Auth Service  →  ${DIM}http://127.0.0.1:${AUTH_PORT}${RESET}                  ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}│${RESET}    Farm Service  →  ${DIM}http://127.0.0.1:${FARM_PORT}${RESET}                  ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}│${RESET}    Worker Service→  ${DIM}http://127.0.0.1:${WORKER_PORT}${RESET}                  ${GREEN}${BOLD}│${RESET}"
$SP_DB_READY && echo -e "${GREEN}${BOLD}│${RESET}    SP Service    →  ${DIM}http://127.0.0.1:${SP_PORT}${RESET}                  ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}│${RESET}    Frontend      →  ${DIM}http://127.0.0.1:${FRONTEND_PORT}${RESET}                  ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}│${RESET}    Admin Portal  →  ${DIM}http://127.0.0.1:${ADMIN_PORT}${RESET}                  ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}│${RESET}                                                         ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}│${RESET}  Logs  →  ${DIM}.logs/<service>.log${RESET}                           ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}│${RESET}  PIDs  →  ${DIM}.logs/farm360.pids${RESET}                            ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}│${RESET}                                                         ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}│${RESET}  ${DIM}./start.sh --stop     stop all services + Caddy${RESET}        ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}│${RESET}  ${DIM}./start.sh --restart  restart all services + Caddy${RESET}     ${GREEN}${BOLD}│${RESET}"
echo -e "${GREEN}${BOLD}└─────────────────────────────────────────────────────────┘${RESET}"
echo ""

# Script exits here — services are detached and keep running independently.

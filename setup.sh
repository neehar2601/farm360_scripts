#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  farm360 — Environment setup, then launches start.sh
#  Usage:  ./setup.sh              full setup, then run start.sh
#          ./setup.sh --no-start   setup only
#          ./setup.sh [other flags are passed on to start.sh, e.g. --prod]
#  Supports Debian/Ubuntu (apt), Fedora/RHEL (dnf), Arch (pacman).
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_MAJOR="${NODE_MAJOR:-20}"

DB_HOST="${DB_HOST:-localhost}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-farm360}"
DB_USER="${DB_USER:-farm360}"
DB_PASSWORD="${DB_PASSWORD:-farmsync@360}"
SP_DB_NAME="${SP_DB_NAME:-farm360_sp}"

NODE_PROJECTS=(
  farm360_db
  farm360_backend/auth-service
  farm360_backend/farm-service
  farm360_backend/worker-service
  farm360_backend/sp-service
  farm360_frontend
  farm360_admin
)

START=true
PASS_ARGS=()
for a in "$@"; do
  [ "$a" = "--no-start" ] && START=false || PASS_ARGS+=("$a")
done

step() { echo -e "\n\033[1;34m━━━ $* ━━━\033[0m"; }
ok()   { echo -e "\033[1;32m  ✅ $*\033[0m"; }
warn() { echo -e "\033[1;33m  ⚠️  $*\033[0m"; }
die()  { echo -e "\033[1;31m  ❌ $*\033[0m"; exit 1; }

SUDO=""
[ "$(id -u)" -ne 0 ] && { command -v sudo >/dev/null || die "Need root or sudo"; SUDO="sudo"; }

# Run a command as the postgres OS user (works as root or via sudo)
as_postgres() {
  if [ "$(id -u)" -eq 0 ]; then runuser -u postgres -- "$@"; else sudo -u postgres "$@"; fi
}
# Run a command as the invoking (non-root) user, so files aren't root-owned
as_user() {
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    sudo -u "$SUDO_USER" -H env "PATH=$PATH" "$@"
  else
    "$@"
  fi
}

if   command -v apt-get >/dev/null; then PM=apt
elif command -v dnf     >/dev/null; then PM=dnf
elif command -v pacman  >/dev/null; then PM=pacman
else die "Unsupported package manager"; fi

# ── 1. System packages ────────────────────────────────────────────────────────
step "System packages"
case "$PM" in
  apt)
    $SUDO apt-get update -y
    $SUDO apt-get install -y curl ca-certificates gnupg lsof iproute2 build-essential \
      postgresql postgresql-contrib ;;
  dnf)
    $SUDO dnf install -y curl ca-certificates lsof iproute gcc-c++ make \
      postgresql-server postgresql-contrib
    [ -d /var/lib/pgsql/data/base ] || $SUDO postgresql-setup --initdb ;;
  pacman)
    $SUDO pacman -Sy --noconfirm --needed curl lsof iproute2 base-devel postgresql
    [ -d /var/lib/postgres/data/base ] || as_postgres initdb -D /var/lib/postgres/data ;;
esac
ok "System packages installed"

# ── 2. Node.js ────────────────────────────────────────────────────────────────
step "Node.js (>= 18, target ${NODE_MAJOR}.x)"
CUR_MAJOR=0
command -v node >/dev/null && CUR_MAJOR="$(node -v | sed 's/^v//;s/\..*//')"
if [ "$CUR_MAJOR" -ge 18 ] && command -v npm >/dev/null; then
  ok "Node.js $(node -v) / npm $(npm -v) already installed"
else
  case "$PM" in
    apt) curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | $SUDO -E bash -
         $SUDO apt-get install -y nodejs ;;
    dnf) curl -fsSL "https://rpm.nodesource.com/setup_${NODE_MAJOR}.x" | $SUDO -E bash -
         $SUDO dnf install -y nodejs ;;
    pacman) $SUDO pacman -S --noconfirm --needed nodejs npm ;;
  esac
  ok "Installed Node.js $(node -v) / npm $(npm -v)"
fi

# ── 3. PostgreSQL service + databases ─────────────────────────────────────────
step "PostgreSQL"
$SUDO systemctl enable --now postgresql 2>/dev/null || $SUDO service postgresql start || \
  warn "Could not start PostgreSQL automatically — start it manually"

for _ in $(seq 1 15); do
  as_postgres psql -tAc "SELECT 1" >/dev/null 2>&1 && break
  sleep 1
done
pg() { as_postgres psql -v ON_ERROR_STOP=1 "$@"; }

if pg -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
  pg -c "ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';" >/dev/null
  ok "Role ${DB_USER} exists (password synced)"
else
  pg -c "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';" >/dev/null
  ok "Created role ${DB_USER}"
fi
for db in "$DB_NAME" "$SP_DB_NAME"; do
  if pg -tAc "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1; then
    ok "Database ${db} exists"
  else
    pg -c "CREATE DATABASE ${db} OWNER ${DB_USER};" >/dev/null
    ok "Created database ${db}"
  fi
done

# ── 3b. Ownership + layout fixes ──────────────────────────────────────────────
step "Project ownership & layout"
OWNER="${SUDO_USER:-$(id -un)}"
for p in "$ROOT"/farm360_* "$ROOT"/Farm360-databse "$ROOT/start.sh"; do
  [ -e "$p" ] || continue
  if [ -n "$(find "$p" -maxdepth 3 ! -user "$OWNER" -print -quit 2>/dev/null)" ]; then
    $SUDO chown -R "$OWNER":"$OWNER" "$p"
    ok "Fixed ownership: $(basename "$p")"
  fi
done
# start.sh expects farm360_db; accept the renamed folder from some downloads
if [ ! -e "$ROOT/farm360_db" ] && [ -d "$ROOT/Farm360-databse" ]; then
  as_user ln -s "$ROOT/Farm360-databse" "$ROOT/farm360_db"
  ok "Linked farm360_db -> Farm360-databse"
fi
[ -d "$ROOT/farm360_db" ] || warn "farm360_db not found — migrations will fail"
[ -d "$ROOT/farm360_backend/auth-service" ] || warn "Backend services not found under $ROOT/farm360_backend"

# ── 4. .env files ─────────────────────────────────────────────────────────────
step ".env files"
for dir in farm360_db farm360_backend/auth-service farm360_backend/farm-service \
           farm360_backend/worker-service farm360_backend/sp-service; do
  if [ -f "$ROOT/$dir/.env" ]; then
    ok "$dir/.env present"
  elif [ -f "$ROOT/$dir/.env.example" ]; then
    as_user cp "$ROOT/$dir/.env.example" "$ROOT/$dir/.env"
    warn "Created $dir/.env from .env.example — review the values"
  else
    warn "$dir has no .env or .env.example"
  fi
done

# ── 5. npm dependencies ───────────────────────────────────────────────────────
step "npm dependencies"
for proj in "${NODE_PROJECTS[@]}"; do
  [ -f "$ROOT/$proj/package.json" ] || { warn "Skipping $proj (no package.json)"; continue; }
  echo "  📦 $proj"
  if [ -f "$ROOT/$proj/package-lock.json" ]; then
    (cd "$ROOT/$proj" && as_user npm ci --no-audit --no-fund) || (cd "$ROOT/$proj" && as_user npm install --no-audit --no-fund)
  else
    (cd "$ROOT/$proj" && as_user npm install --no-audit --no-fund)
  fi
done
ok "Dependencies installed"

# ── 6. Launch ─────────────────────────────────────────────────────────────────
if $START; then
  step "Running start.sh"
  as_user chmod +x "$ROOT/start.sh"
  exec_cmd=("$ROOT/start.sh" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"})
  if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    exec sudo -u "$SUDO_USER" -H env "PATH=$PATH" "${exec_cmd[@]}"
  fi
  exec "${exec_cmd[@]}"
else
  ok "Setup complete. Run ./start.sh when ready."
fi

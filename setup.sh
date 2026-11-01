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
# Wait for the user (skipped when not running in a terminal)
pause() { if [ -t 0 ]; then read -r -p "  $1 " _; else warn "Non-interactive shell — continuing without pausing"; fi; }

if   command -v apt-get >/dev/null; then PM=apt
elif command -v dnf     >/dev/null; then PM=dnf
elif command -v pacman  >/dev/null; then PM=pacman
else die "Unsupported package manager"; fi

# ── 1. System packages ────────────────────────────────────────────────────────
step "System packages"
case "$PM" in
  apt)
    $SUDO apt-get update -y
    $SUDO apt-get install -y curl ca-certificates gnupg lsof iproute2 build-essential ;;
  dnf)
    $SUDO dnf install -y curl ca-certificates lsof iproute gcc-c++ make ;;
  pacman)
    $SUDO pacman -Sy --noconfirm --needed curl lsof iproute2 base-devel ;;
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

# ── 3. PostgreSQL (install only; user creates role + databases) ───────────────
step "PostgreSQL"
if command -v psql >/dev/null; then
  ok "PostgreSQL client found: $(psql --version)"
else
  case "$PM" in
    apt) $SUDO apt-get install -y postgresql postgresql-contrib ;;
    dnf) $SUDO dnf install -y postgresql-server postgresql-contrib
         [ -d /var/lib/pgsql/data/base ] || $SUDO postgresql-setup --initdb ;;
    pacman) $SUDO pacman -S --noconfirm --needed postgresql
            [ -d /var/lib/postgres/data/base ] || as_postgres initdb -D /var/lib/postgres/data ;;
  esac
  ok "Installed $(psql --version)"
fi

$SUDO systemctl enable --now postgresql 2>/dev/null || $SUDO service postgresql start 2>/dev/null || \
  warn "Could not start PostgreSQL automatically — start it manually"

cat <<EOF

$(echo -e "\033[1;36m")  ▶ MANUAL STEP — create the PostgreSQL user and databases$(echo -e "\033[0m")

  Open a NEW terminal and run:

    sudo -u postgres psql

  Then paste (choose your own user/password/DB names):

    CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD 'your_password';
    CREATE DATABASE ${DB_NAME}    OWNER ${DB_USER};   -- farmer / worker / auth data
    CREATE DATABASE ${SP_DB_NAME} OWNER ${DB_USER};   -- service-provider data
    \\q

  Verify the login works:

    PGPASSWORD='your_password' psql -h localhost -U ${DB_USER} -d ${DB_NAME} -c '\\q'

  Note: start.sh reads DB_HOST / DB_PORT / DB_NAME / DB_USER / DB_PASSWORD /
  SP_DB_NAME from your shell (defaults: ${DB_NAME} / ${DB_USER} / farmsync@360).
  If you pick different values, export them before running start.sh, e.g.

    export DB_NAME=mydb DB_USER=myuser DB_PASSWORD='your_password'

EOF
pause "Press Enter once the user and databases are created…"

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
ENV_DIRS=(farm360_db farm360_backend/auth-service farm360_backend/farm-service \
          farm360_backend/worker-service farm360_backend/sp-service)
for dir in "${ENV_DIRS[@]}"; do
  if [ -f "$ROOT/$dir/.env" ]; then
    ok "$dir/.env present"
  elif [ -f "$ROOT/$dir/.env.example" ]; then
    as_user cp "$ROOT/$dir/.env.example" "$ROOT/$dir/.env"
    warn "Created $dir/.env from .env.example"
  else
    warn "$dir has no .env or .env.example — create one manually"
  fi
done

echo -e "\n\033[1;36m  ▶ MANUAL STEP — update the DB settings in these .env files:\033[0m"
for dir in "${ENV_DIRS[@]}"; do echo "    $ROOT/$dir/.env"; done
cat <<EOF

  Set in each file (match what you created in PostgreSQL):

    DB_HOST=localhost
    DB_PORT=5432
    DB_NAME=<database>        (sp-service uses ${SP_DB_NAME})
    DB_USER=<your db user>
    DB_PASSWORD=<your password>

  Example:  nano $ROOT/farm360_backend/auth-service/.env

EOF
pause "Press Enter once the .env files are updated…"

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

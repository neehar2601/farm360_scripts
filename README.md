# FarmSight 360 — Platform Documentation & Setup Guide

Welcome to **FarmSight 360**, a comprehensive multi-tenant agricultural management, shared workforce directory, and service-provider marketplace platform.

FarmSight 360 uses a **Decentralized 4-Database-per-Service Architecture** where each backend microservice exclusively owns its PostgreSQL database (`farm360_auth`, `farm360_farm`, `farm360_worker`, `farm360_sp`) with zero cross-database SQL joins. Cross-service communication occurs strictly over token-authenticated internal HTTP APIs (`X-Internal-Token`), and the entire platform is exposed through a unified **Caddy Reverse Proxy** (`:80` for Farmer/SP portal, `:8081` for Super Admin portal).

---

## 🏛 Ecosystem & 4-Database Decentralized Architecture

```text
                             ┌────────────────────────────┐
                             │    Caddy Reverse Proxy     │
                             │  :80 (App)  /  :8081 (Adm) │
                             └─────────────┬──────────────┘
                                           │
               ┌───────────────────────────┼───────────────────────────┐
               │                           │                           │
               ▼                           ▼                           ▼
  ┌─────────────────────────┐ ┌─────────────────────────┐ ┌─────────────────────────┐
  │    farm360_frontend     │ │      farm360_admin      │ │ Third-Party / Webhooks  │
  │       (Port 5173)       │ │       (Port 5174)       │ │ Razorpay / UPI Gateways │
  └────────────┬────────────┘ └────────────┬────────────┘ └────────────┬────────────┘
               │                           │                           │
 ══════════════╪═══════════════════════════╪═══════════════════════════╪══════════════
               │                           │                           │
               ▼                           ▼                           ▼
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                 BACKEND MICROSERVICES CLUSTER (Internal HTTP Mesh)                  │
│            (Protected via X-Internal-Token; /farm/internal/* blocked @ :80)         │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                     │
│  ┌────────────────┐   ┌────────────────┐   ┌────────────────┐   ┌────────────────┐  │
│  │  auth-service  │◄─►│  farm-service  │◄─►│ worker-service │   │   sp-service   │  │
│  │  (Port 4000)   │   │  (Port 4001)   │   │  (Port 4002)   │   │  (Port 4003)   │  │
│  └───────┬────────┘   └───────┬────────┘   └───────┬────────┘   └───────┬────────┘  │
│          │                    ▲                    │                    │           │
│          │                    └────────────────────┼────────────────────┘           │
│          │                       Internal HTTP Sync (X-Internal-Token)              │
└──────────┼────────────────────┬────────────────────┼────────────────────┼───────────┘
           │                    │                    │                    │
           ▼                    ▼                    ▼                    ▼
  ┌────────────────┐   ┌────────────────┐   ┌────────────────┐   ┌────────────────┐
  │ `farm360_auth` │   │ `farm360_farm` │   │`farm360_worker`│   │  `farm360_sp`  │
  │ (Postgres 5432)│   │ (Postgres 5432)│   │ (Postgres 5432)│   │ (Postgres 5432)│
  ├────────────────┤   ├────────────────┤   ├────────────────┤   ├────────────────┤
  │ • users        │   │ • farms        │   │ • workers      │   │ • sp_users     │
  │ • refresh_     │   │ • crops        │   │   (universal)  │   │ • sp_services  │
  │   tokens       │   │ • crop_harvests│   │ • worker_      │   │ • sp_capacity  │
  │ • password_    │   │ • crop_segreg. │   │   balances     │   │ • sp_blocked_  │
  │   reset_tokens │   │ • crop_sales   │   │ • worker_      │   │   dates        │
  │                │   │ • inventory_*  │   │   attendance   │   │ • sp_bookings  │
  │                │   │ • service_     │   │ • worker_txs   │   │ • sp_invoices* │
  │                │   │   payments     │   │ • farm_workers │   │ • sp_payments  │
  └────────────────┘   └────────────────┘   └────────────────┘   └────────────────┘
```

---

## 🗄️ Key Decentralized Data Design Principles

1. **4 Isolated PostgreSQL Databases**:
   - **`farm360_auth` (`auth-service :4000`)**: Owns `users`, `refresh_tokens`, and `password_reset_tokens`.
   - **`farm360_farm` (`farm-service :4001`)**: Owns `farms`, `crops`, `crop_harvests`, `crop_segregations`, `crop_sales`, `inventory_categories`, `inventory_items`, `inventory_transactions`, and `service_payments`.
   - **`farm360_worker` (`worker-service :4002`)**: Owns universal `workers` (shared across farms/users with unique `worker_code` like `W-687B3AD3`), per-farm `worker_balances` (custom daily wage, role, loan & deposit balance, `is_active`), `worker_attendance`, `worker_transactions`, and the `farm_workers` read view.
   - **`farm360_sp` (`sp-service :4003`)**: Owns `sp_users`, `sp_services`, `sp_capacity`, `sp_blocked_dates`, `sp_bookings`, `sp_invoices`, `sp_invoice_items`, `sp_invoice_events`, `sp_payments`, and `sp_refresh_tokens`.
2. **Composite `(user_id, farm_id)` Ownership**:
   - Every farm-scoped table in `farm360_farm` and `farm360_worker` stamps both `user_id` and `farm_id` via PostgreSQL triggers, enabling `O(1)` user-level queries and cascading tenant purges without cross-DB joins.
3. **Universal Shared Workforce**:
   - Workers are global identities (`workers`) linked to individual farms via `worker_balances`. Multiple farm owners can search the shared directory (by phone, `worker_code`, or location) and link the same worker to their farm with completely isolated wages, loans, and attendance ledgers.

---

## 🚀 Environment Setup Guide (Standalone vs. Docker)

You can run the full FarmSight 360 stack either **natively (Standalone)** on Linux/macOS/EC2 or via **Docker Compose**.

### Option A: Standalone (Native Local / EC2) Setup

#### 1. Prerequisites
- **Node.js** v18+ or v20+ LTS & **npm** v9+
- **PostgreSQL** v14+ running on `localhost:5432`
- **Caddy** v2+ (optional, for single-origin reverse proxy on `:80` and `:8081`)

#### 2. One-Time Automated Setup (`./setup.sh`)
```bash
# 1. Run the interactive setup script (installs npm packages, generates .env files)
./setup.sh

# 2. Create the PostgreSQL role and all 4 databases (prompts for postgres sudo if needed)
./farm360_db/setup-db.sh

# 3. Apply all migrations across farm360_auth, farm360_farm, farm360_worker, and farm360_sp
cd farm360_db && node run_migrations.js && cd ..
```

*(Optional)* If migrating from an older single-DB `farm360` installation, copy existing rows into the 4 new databases idempotently:
```bash
node farm360_db/migrate_legacy_data.js
```

#### 3. Start All Services (`./start.sh`)
```bash
./start.sh               # Checks all 4 DBs, applies pending migrations, starts 4 services + frontend
./start.sh --status      # Check health & PIDs of all running services
./start.sh --restart     # Restart all services cleanly
./start.sh --stop        # Stop all services
```

#### 4. Start Caddy Reverse Proxy (Optional, for `:80` & `:8081`)
```bash
./docker/run-caddy-native.sh
```

---

### Option B: Docker Compose Setup

Docker Compose runs the 4 backend microservices, migration runner, frontend, admin console, and Caddy reverse proxy in containers while connecting to your PostgreSQL instance (either on the host via `db-proxy` or an external RDS/Postgres host).

#### 1. Prepare Environment File
```bash
# Copy the Docker environment template
cp .env.docker.example .env
```

Edit `.env` and set your secrets (`JWT_SECRET`, `REFRESH_TOKEN_SECRET`, `SUPER_ADMIN_SECRET`, `INTERNAL_SERVICE_TOKEN`, `SP_JWT_SECRET`, `SP_REFRESH_TOKEN_SECRET`) and database credentials:
```env
DB_HOST=db-proxy
DB_PORT=5432
DB_USER=farm360
DB_PASSWORD=your_db_password
AUTH_DB_NAME=farm360_auth
FARM_DB_NAME=farm360_farm
WORKER_DB_NAME=farm360_worker
SP_DB_NAME=farm360_sp
```

#### 2. Ensure the 4 Databases Exist in PostgreSQL
If using host PostgreSQL, run once on the host:
```bash
./farm360_db/setup-db.sh
```

#### 3. Build and Launch Containers
```bash
# Build images, run the one-shot 4-DB migration container, and start all services + Caddy
docker compose up -d --build

# View logs
docker compose logs -f

# Check container health
docker compose ps

# Stop stack
docker compose down
```

---

## 🌐 Access URLs & Documentation Index

| Component | Via Caddy Proxy (Recommended) | Direct Local Port | Database | Documentation |
|---|---|---|---|---|
| **Farmer & SP Web App** (`farm360_frontend`) | `http://localhost` (`:80`) | `http://localhost:5173` | — | [farm360_frontend/README.md](./farm360_frontend/README.md) |
| **Super Admin Console** (`farm360_admin`) | `http://localhost:8081` (`:8081`) | `http://localhost:5174` | — | [farm360_admin/README.md](./farm360_admin/README.md) |
| **Backend Master Guide** (`farm360_backend`) | — | — | All 4 DBs | [farm360_backend/README.md](./farm360_backend/README.md) |
| **Auth Service** (`auth-service`) | `http://localhost/auth/*`, `/admin/*` | `http://localhost:4000` | `farm360_auth` | [farm360_backend/auth-service/README.md](./farm360_backend/auth-service/README.md) |
| **Farm Service** (`farm-service`) | `http://localhost/farm/*` | `http://localhost:4001` | `farm360_farm` | [farm360_backend/farm-service/README.md](./farm360_backend/farm-service/README.md) |
| **Worker Service** (`worker-service`) | `http://localhost/workers*`, `/attendance*`, `/finance*` | `http://localhost:4002` | `farm360_worker` | [farm360_backend/worker-service/README.md](./farm360_backend/worker-service/README.md) |
| **SP Service** (`sp-service`) | `http://localhost/api/sp/*` | `http://localhost:4003` | `farm360_sp` | [farm360_backend/sp-service/README.md](./farm360_backend/sp-service/README.md) |
| **4-Database Migrations** (`farm360_db`) | — | `localhost:5432` | All 4 DBs | [farm360_db/README.md](./farm360_db/README.md) |
| **SP Database Guide** (`farm360_db/sp`) | — | `localhost:5432` | `farm360_sp` | [farm360_db/sp/README.md](./farm360_db/sp/README.md) |
| **Centralized Docs Hub** (`docs`) | — | — | — | [docs/README.md](./docs/README.md) |

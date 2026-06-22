# Infra — single-VPS Docker Swarm stack

Production-ready PostgreSQL, Redis, monitoring, and backups for a single VPS. One command to install, one command to redeploy, one dashboard for every app.

```bash
curl -fsSL https://raw.githubusercontent.com/oyenet1/postgres-vps-setup/master/install.sh | sudo bash -s -- -s 22
```

Replace `22` with your real SSH port.

## What's included

| Service | Default port | Purpose |
|---|---|---|
| **PostgreSQL 17** (PostGIS + pgvector + pg_cron) | `5432` (host-only), `5544` (external) | Database |
| **PgBouncer** | `6543` (TLS optional) | Connection pool — apps connect here |
| **pgAdmin** | `5050` (host-only) | Browser DB admin UI |
| **Redis** (master + replica + 3-node Sentinel + HAProxy) | `6379` | Cache, queues, sessions |
| **Backups** | — | Local + optional Cloudflare R2 (always 2 latest kept per DB) |
| **Prometheus** | `9090` (host-only) | Metrics |
| **Grafana** | `3030` (host-only) | Dashboards (auto-provisioned) |
| **Loki + Alloy** | `3100` (host-only) | Log aggregation from every container |
| **Alertmanager** | `9093` (host-only) | Email alerts |

Single-node Docker Swarm. Always-included monitoring (no opt-in flag). Custom-built Postgres image with all the extensions baked in.

## Quick start

### Install (clean VPS)

```bash
# Replace 22 with your SSH port
curl -fsSL https://raw.githubusercontent.com/oyenet1/postgres-vps-setup/master/install.sh | sudo bash -s -- -s 22
```

The script will:
1. Clone this repo to `/opt/infra`
2. Install Docker if missing
3. Initialize Docker Swarm
4. Create `.env` with auto-generated strong passwords
5. Build the custom Postgres image (PostGIS + pgvector + pg_cron)
6. Build the backup image (postgres + rclone)
7. Open the firewall ports
8. Deploy the full stack
9. Print connection URLs and credentials

### Manual install

```bash
git clone https://github.com/oyenet1/postgres-vps-setup.git /opt/infra
cd /opt/infra
sudo ./setup.sh -s 22
```

### Re-run (re-render + redeploy, keep `.env`)

```bash
cd /opt/infra
sudo ./setup.sh -s 22
```

The script is **idempotent** and **never overwrites `.env`**. Missing values get filled; existing values are preserved.

### Render configs only (no deploy)

```bash
cd /opt/infra
sudo ./setup.sh --no-start
```

## Connection URLs

### PostgreSQL via PgBouncer (use this for apps)

PgBouncer on `6543` is the recommended endpoint. Pooled, fast, and supports **any database and any login role** you create in pgAdmin — no PgBouncer config edit needed.

| Where your app runs | URL |
|---|---|
| Same VPS (not Docker) | `postgres://postgres:PASS@127.0.0.1:6543/mydb` |
| Same VPS (Docker, not in Swarm) | `postgres://postgres:PASS@HOST_IP:6543/mydb` |
| Same Docker Swarm (`infra` overlay) | `postgres://postgres:PASS@pgbouncer:6432/mydb` |
| External / internet | `postgres://postgres:PASS@YOUR_VPS_IP:6543/mydb` |

**Multiple apps / databases / roles:**

```
postgres://app1_user:PASS@YOUR_VPS_IP:6543/app1
postgres://app2_user:PASS@YOUR_VPS_IP:6543/app2
postgres://app3_user:PASS@YOUR_VPS_IP:6543/app3
```

Just `CREATE DATABASE` and `CREATE ROLE` first in pgAdmin or psql. PgBouncer picks up new roles automatically via the `pgbouncer_auth` user — it queries `pg_authid` at login time.

### PostgreSQL direct (admin only)

Skips PgBouncer. Use for migrations, pgAdmin, or admin tasks.

| Where | URL |
|---|---|
| Same VPS | `postgres://postgres:PASS@127.0.0.1:5432/mydb` |
| Same Docker Swarm | `postgres://postgres:PASS@postgres:5432/mydb` |
| External | `postgres://postgres:PASS@YOUR_VPS_IP:5544/mydb` |

### Redis

| Where | URL |
|---|---|
| Same VPS | `redis://:PASS@127.0.0.1:6379/0` |
| Same Docker Swarm | `redis://:PASS@redis-proxy:6379/0` |
| External | `redis://:PASS@YOUR_VPS_IP:6379/0` |

Change `0` to any DB index (`0`–`15`) for separate namespaces:
```
redis://:PASS@127.0.0.1:6379/0   # default / cache
redis://:PASS@127.0.0.1:6379/1   # sessions
redis://:PASS@127.0.0.1:6379/2   # queues
```

## Framework examples

**Node.js (Knex):**
```js
const knex = require('knex')({
  client: 'pg',
  connection: 'postgres://postgres:PASS@YOUR_VPS_IP:6543/mydb'
});
```

**Node.js (Redis ioredis):**
```js
new Redis({ host: 'YOUR_VPS_IP', port: 6379, password: 'PASS', db: 1 });
```

**Python (Django):**
```python
DATABASES = {
  'default': {
    'ENGINE': 'django.db.backends.postgresql',
    'NAME': 'mydb', 'USER': 'postgres',
    'PASSWORD': 'PASS', 'HOST': 'YOUR_VPS_IP', 'PORT': '6543',
  }
}
CACHES = {
  'default': {
    'BACKEND': 'django_redis.cache.RedisCache',
    'LOCATION': 'redis://:PASS@YOUR_VPS_IP:6379/1',
  }
}
```

**Ruby on Rails:**
```yaml
production:
  adapter: postgresql
  database: myapp
  username: postgres
  password: PASS
  host: YOUR_VPS_IP
  port: 6543
  pool: 25
```

**Go (pgx):**
```go
connStr := "postgres://postgres:PASS@YOUR_VPS_IP:6543/mydb?pool_max_conns=25"
```

**Inside Docker Compose (same Swarm):**
```yaml
services:
  app:
    image: myapp
    environment:
      DATABASE_URL: postgres://postgres:PASS@pgbouncer:6432/mydb
      REDIS_URL: redis://:PASS@redis-proxy:6379/0
    networks:
      - infra
networks:
  infra:
    external: true
```

Note: your app container must be on the `infra` overlay network to use service names (`pgbouncer`, `redis-proxy`).

## Create a database

The fastest way — via psql on the VPS:
```bash
docker run --rm --network infra postgres:17-alpine \
  psql -h postgres -U postgres -c "CREATE DATABASE myapp;"
```

Or via pgAdmin (browser UI at `http://YOUR_VPS_IP:5050` — connect with the host-only port `5432`).

Then connect:
```
postgres://postgres:PASSWORD@YOUR_VPS_IP:6543/myapp
```

Repeat for each app.

## Extensions on new databases

The init script (`initdb/01-bootstrap.sql`) installs all supported extensions into `postgres` and the `template1` template database.

**What this means for you:**

- **New databases you create via pgAdmin, `CREATE DATABASE`, or any client inherit extensions automatically** — they're cloned from `template1` by default, so postgis, vector, pg_cron, etc. are pre-enabled.
- **No need to run `CREATE EXTENSION ...` per database.**
- **App-side auto-bootstrap:** apps that follow the metrics contract below also run `CREATE EXTENSION IF NOT EXISTS` for required extensions on startup.

**Available extensions:** postgis, postgis_topology, vector (pgvector), pg_cron, pg_stat_statements, pg_trgm, unaccent, btree_gin, btree_gist, hstore, ltree, citext, pgcrypto, uuid-ossp.

If an extension is missing in the image (e.g. you override `POSTGRES_IMAGE` with a plain `postgres` without postgis), the init script logs a NOTICE and continues — the database still works, just without that extension.

## Monitoring

Always included. Open `http://YOUR_VPS_IP:3030` (login: `admin` / `GRAFANA_PASSWORD` from `.env`).

**Pre-built dashboards (auto-provisioned, no setup):**

| Dashboard | What it shows |
|---|---|
| **Infrastructure Overview** | Host CPU/memory/disk, postgres connections, redis activity, app up/down status |
| **App Performance & Errors** | Per-app view: request rate, 4xx/5xx counts, latency percentiles, per-endpoint table, errors/stack-traces log panel, full log stream |

**Built-in alerts** (in `monitoring/alert.rules.yml`):
- `PostgresExporterDown`, `RedisExporterDown`, `NodeExporterDown`, `AppDown` — service-down (critical)
- `PostgresHighConnections` — DB capacity (warning)
- `HostDiskAlmostFull` (< 10% free), `HostHighCpu` (> 90%), `HostHighMemory` (> 90%) — host resources (warning)

To receive email alerts, set these in `.env` and re-run `./setup.sh`:
```env
ALERT_EMAIL_TO=you@example.com
SMTP_SMARTHOST=smtp.gmail.com:587
SMTP_USER=your-sender@gmail.com
SMTP_PASSWORD=your-app-password
```

## Adding your app to monitoring (3 steps)

The infra stack can monitor any app that exposes Prometheus metrics. The **App Performance & Errors** dashboard is templated — pick the app from the `$service` dropdown, all panels update.

### 1. Make the app reachable from the `infra` stack

In the app's `docker-swarm.yml`, join the `infra` overlay network:
```yaml
networks:
  - external: true
    name: infra_infra
```

### 2. Drop a target file in `monitoring/targets/<appname>.json`

```json
[
  {
    "targets": ["<stack>_<service>:<port>"],
    "labels": {
      "job": "apps",
      "service": "<app-name>",
      "env": "production",
      "metrics_path": "/v1/metrics",
      "scheme": "http"
    }
  }
]
```

A starter is at `monitoring/targets/lodgestatus.json` (gitignored, edit or delete freely).

### 3. Reload Prometheus (no service restart)

```bash
curl -X POST http://YOUR_VPS_IP:9090/-/reload
```

The app is now monitored. Open Grafana → **App Performance & Errors** → pick it from the `$service` dropdown.

### App metrics contract

Your app must expose these two Prometheus metrics:

```
# Counter: one increment per request
http_requests_total{method, path, status}

# Histogram: observation per request (in seconds)
http_request_duration_seconds{method, path, status}
```

**Required labels:**
- `method` — HTTP method (`GET`, `POST`, etc.)
- `path` — normalized route (e.g. `/v1/users/:id`, not `/v1/users/12345`)
- `status` — HTTP status code as a string (`"200"`, `"404"`, `"500"`)

**Node.js / Hono example:**
```js
import { Counter, Histogram, Registry, collectDefaultMetrics } from "prom-client";

const metricsRegistry = new Registry();
collectDefaultMetrics({ register: metricsRegistry });

const httpRequestDurationSeconds = new Histogram({
  name: "http_request_duration_seconds",
  help: "HTTP request duration in seconds",
  labelNames: ["method", "path", "status"],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  registers: [metricsRegistry],
});
const httpRequestsTotal = new Counter({
  name: "http_requests_total",
  help: "Total HTTP requests",
  labelNames: ["method", "path", "status"],
  registers: [metricsRegistry],
});

export function metricsMiddleware(c, next) {
  const method = c.req.method;
  const path = c.req.path;
  const endTimer = httpRequestDurationSeconds.startTimer({ method, path });
  return next().finally(() => {
    const status = String(c.res.status || 200);
    endTimer({ status });
    httpRequestsTotal.inc({ method, path, status });
  });
}
```

**Python / FastAPI example:**
```python
from prometheus_client import Counter, Histogram

REQUESTS = Counter("http_requests_total", "Total HTTP requests", ["method", "path", "status"])
DURATION = Histogram("http_request_duration_seconds", "Request duration",
                     ["method", "path", "status"],
                     buckets=[0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10])

@app.middleware("http")
async def metrics_middleware(request, call_next):
    method = request.method
    path = request.url.path
    with DURATION.labels(method=method, path=path).time():
        response = await call_next(request)
    REQUESTS.labels(method=method, path=path, status=str(response.status_code)).inc()
    return response
```

### App Performance & Errors dashboard

The dashboard has **4 filter dropdowns** at the top + the standard Grafana **time range picker** at the top right:

| Filter | Source | Notes |
|---|---|---|
| **Service** | `label_values(http_requests_total, service)` | All apps on the network. Multi-select. |
| **Method** | `label_values(..., method)` | GET, POST, PUT, etc. Multi-select. |
| **Endpoint** | `label_values(..., path)` | All route templates. Multi-select. |
| **Status** | `label_values(..., status)` | 200, 201, 4xx, 5xx. Multi-select. |
| **Time range** | Grafana picker | Top right. Default: last 1h. Quick: 5m / 15m / 1h / 6h / 24h / 7d. |

**All 8 panels respect the active filters:**

| Panel | PromQL | Shows |
|---|---|---|
| Service Status | `up{job="apps"}` | 1 = up, 0 = down (one row per service) |
| Request Rate by Status | `rate(http_requests_total)` | Stacked line per status code |
| 4xx Errors / min | `rate(..., status=~"4..")` | 4xx rate, last 5 min |
| 5xx Errors / min | `rate(..., status=~"5..")` | 5xx rate, last 5 min |
| Endpoints (table) | `histogram_quantile(0.70/0.90/0.95)` + counters | Per-endpoint: visits, 400 count, 500 count, p70/p90/p95/avg in ms |
| Latency Percentiles | `histogram_quantile(0.50/0.90/0.95/0.99)` | p50, p90, p95, p99 over time |
| Errors / Stack Traces | Loki regex on `error\|exception\|stack\|trace\|fatal\|panic` | Log lines containing errors |
| All logs | Loki `{service="$service"}` | Full log stream |

**Example workflows:**
- "Show me only 5xx errors for lodgestatus in the last 15min" → Status: 5xx, Service: lodgestatus, Time: 15m
- "How's POST /v1/login doing?" → Method: POST, Endpoint: /v1/login
- "Compare lodgestatus vs otherapp" → Service: lodgestatus + otherapp (multi-select)

### Why this is safe without auth

- The app's metrics endpoint should be on the overlay network only (no `mode: host` port publish for `/v1/metrics`).
- Only the prometheus container inside the `infra` stack can reach it.
- The app's `/v1/metrics` should have auth disabled (or accept requests from the overlay without a token). If you need bearer auth per-app, see the [Prometheus file_sd docs](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config).

## Environment variables

Edit `/opt/infra/.env` (gitignored, never committed):

```env
# Auto-generated on first run
POSTGRES_PASSWORD=...          # admin password for postgres user
PGBOUNCER_AUTH_PASSWORD=...    # lets pgbouncer auth new roles (don't change!)
PGADMIN_PASSWORD=...           # pgAdmin login
REDIS_PASSWORD=...             # Redis auth
GRAFANA_PASSWORD=...           # Grafana admin login

# Network
PGBOUNCER_PORT=6543            # public pgbouncer port
POSTGRES_PORT=5432             # public postgres port (host-only by default)
POSTGRES_PORT_DIRECT=5544      # direct external postgres port (bypasses pgbouncer)
PGBOUNCER_TLS_ENABLED=false    # set true to enable self-signed TLS on pgbouncer

# Backups
BACKUP_INTERVAL_SECONDS=43200  # 12h
BACKUP_RETENTION=2             # local backups kept per DB
R2_BACKUP_ENABLED=false        # set true to upload to Cloudflare R2
R2_ACCESS_KEY_ID=...
R2_SECRET_ACCESS_KEY=...
R2_BUCKET=...
R2_PREFIX=infra/

# Image
POSTGRES_IMAGE=infra/postgres:latest  # default custom build; override to use a registry image

# Email alerts
ALERT_EMAIL_TO=
ALERT_FROM=alerts@example.com
SMTP_SMARTHOST=smtp.gmail.com:587
SMTP_USER=
SMTP_PASSWORD=

# Monitoring
GRAFANA_PORT=3030
PROMETHEUS_PORT=9090
PROMETHEUS_RETENTION=15d
LOKI_PORT=3100
ALERTMANAGER_PORT=9093
```

**`.env` is sacred.** `setup.sh` only adds missing keys or fills placeholders (`change_me_*`, `password`, `admin`, `admin123`). Existing values are never overwritten.

After editing:
```bash
cd /opt/infra
sudo ./setup.sh -s 22
```

## Ports

| Service | Default | Purpose |
|---|---|---|
| PgBouncer | `0.0.0.0:6543` | Main app endpoint for Postgres (TLS optional) |
| PostgreSQL | `127.0.0.1:5432` | Local admin only (host-only) |
| PostgreSQL direct | `0.0.0.0:5544` | Direct PostgreSQL access (no SSL, scram-sha-256) |
| pgAdmin | `127.0.0.1:5050` | Browser UI |
| Redis | `127.0.0.1:6379` | Local Redis (host-only) |
| Prometheus | `127.0.0.1:9090` | Metrics (host-only) |
| Grafana | `127.0.0.1:3030` | Dashboards (host-only) |
| Alertmanager | `127.0.0.1:9093` | Alerts (host-only) |
| Loki | `127.0.0.1:3100` | Logs (host-only) |

## Backups

Runs every `BACKUP_INTERVAL_SECONDS` (default 12h). Each run creates one timestamped folder per database:

```
backups/
  20260621_235900/
    postgres.sql.gz
    myapp.sql.gz
    analytics.sql.gz
```

Only the **2 latest backups per database** are kept (local + R2). Older ones auto-delete.

**Force a backup now:**
```bash
docker exec $(docker ps --filter name=infra_backup --format='{{.Names}}' | head -1) /bin/sh /scripts/backup.sh
```

**Restore:**
```bash
gunzip -c backups/20260621_235900/myapp.sql.gz | \
  docker run --rm -i --network infra postgres:17-alpine \
  psql -h postgres -U postgres -d myapp
```

## Cross-Swarm service names

To use `postgres`, `pgbouncer`, `redis-proxy` as names from other Swarms (so your apps on a different VPS can connect), install Tailscale on every VPS. See `docs/TAILSCALE.md`.

## Common operations

```bash
docker stack ps infra                       # show all services and their state
docker service logs infra_pgbouncer -f      # tail pgbouncer logs
docker service update --force infra_pgbouncer  # restart pgbouncer
docker stack rm infra                       # tear it all down
sudo ./setup.sh -s 22                       # re-render + redeploy
```

## Passwords & security model

There are **two** PostgreSQL users you need to know about:

| User | Password env var | What it does |
|---|---|---|
| `postgres` | `POSTGRES_PASSWORD` | Superuser. Used for pgAdmin, migrations, creating DBs and roles. |
| `pgbouncer_auth` | `PGBOUNCER_AUTH_PASSWORD` | Non-superuser. Only runs `pgbouncer.get_auth()` to look up other users' passwords. Cannot read your data, cannot create DBs, cannot do anything else. |

This is by design — if pgbouncer's credentials are ever compromised, the attacker gets a useless restricted account, not superuser.

The `pgbouncer_auth` role is **automatically created** on every fresh volume init (via `initdb/02-pgbouncer-auth.sh`), so you never need to create it manually.

## Files & layout

```
infra/
├── docker-compose.yml              # full stack (postgres, redis, monitoring, etc.)
├── setup.sh                        # main deploy script
├── install.sh                      # bootstrap (clones repo, runs setup)
├── .env                            # gitignored; auto-generated passwords
├── .env.example                    # template
├── postgres_config/                # postgres + pg_hba + ssl certs (if enabled)
├── pgbouncer/                      # pgbouncer.ini + certs (if TLS)
├── initdb/                         # 01-bootstrap.sql (extensions) + 02-pgbouncer-auth.sh
├── monitoring/
│   ├── prometheus.yml              # scrape configs (built-in + file_sd for apps)
│   ├── alert.rules.yml             # alert rules
│   ├── loki.yml                    # log storage
│   ├── alloy/config.alloy          # log collector
│   └── targets/                    # *.json — one per app (gitignored)
├── grafana/
│   ├── dashboards/                 # auto-provisioned JSON dashboards
│   └── provisioning/               # datasources + dashboard providers
├── templates/backup.sh             # backup logic
├── Dockerfile.postgres             # postgis + pgvector + pg_cron image
├── Dockerfile.backup               # postgres + rclone image
└── docs/
    ├── TAILSCALE.md                # cross-Swarm service discovery
    ├── PRD-infrastructure-stack.md # full architecture doc
    └── ONBOARDING-PROJECTS.md      # detailed project onboarding guide
```

## Notes

- All passwords are auto-generated and stored in `.env` (gitignored).
- Single-node Swarm by default; add workers with `docker swarm join`.
- For multi-node, `postgres_data` and `backup_data` need shared storage (NFS/EFS).
- `pg_hba.conf` accepts connections from `0.0.0.0/0` with scram-sha-256 (no SSL) on the direct Postgres port `5544` — for admin use only. For app traffic, use `6543` (PgBouncer) on the overlay network.

## Troubleshooting

**"password authentication failed for user 'pgbouncer_auth'"** on a fresh install:

The role is auto-created by `initdb/02-pgbouncer-auth.sh` on fresh volume init. If you redeployed without nuking the volume and the role was never created, create it manually:

```bash
cd /opt/infra
set -a; source .env; set +a
docker exec -i $(docker ps -q -f name=infra_postgres) \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PGBOUNCER_AUTH_USER:-pgbouncer_auth}') THEN
    CREATE ROLE ${PGBOUNCER_AUTH_USER:-pgbouncer_auth} LOGIN PASSWORD '${PGBOUNCER_AUTH_PASSWORD}';
  ELSE
    ALTER ROLE ${PGBOUNCER_AUTH_USER:-pgbouncer_auth} LOGIN PASSWORD '${PGBOUNCER_AUTH_PASSWORD}';
  END IF;
END
\$\$;
GRANT USAGE ON SCHEMA pgbouncer TO ${PGBOUNCER_AUTH_USER:-pgbouncer_auth};
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(TEXT) TO ${PGBOUNCER_AUTH_USER:-pgbouncer_auth};
SQL
docker service update --force infra_pgbouncer
```

**PgBouncer "cached error: password authentication failed":**

Either the role doesn't exist in postgres (see above), or the password in `userlist.txt` doesn't match what postgres has. The userlist is regenerated by `setup.sh`. The Postgres role password is set by the init script on first volume init. If you changed `PGBOUNCER_AUTH_PASSWORD` in `.env` after the first deploy, run the manual SQL above.

**Alloy won't start with "illegal character U+0023 '#'":**

HCL parser doesn't accept `#` comments inside `rule { }` blocks. Already fixed in this repo — use `//` line comments and put them at the top of the file.

**Prometheus "file_sd ... does not exist" warning:**

Harmless. The `monitoring/targets/` directory is empty until you drop a `.json` for your first app.

**Permission denied on `server-key.pem`:**

The key is mounted with `mode: 0444` (world-readable) — non-root container users (postgres, pgbouncer) can't read `0400`. If you get this error, redeploy with the current compose file.

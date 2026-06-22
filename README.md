# Infra

```bash
curl -fsSL https://raw.githubusercontent.com/oyenet1/postgres-vps-setup/master/install.sh | sudo bash -s -- -s 22
```

Single-VPS Docker Swarm stack for shared application infrastructure:

- **PostgreSQL 17** with PostGIS, pgvector, pg_cron, and 11 other extensions
- **PgBouncer** on public host port `6543`
- **pgAdmin** on `127.0.0.1:5050`
- **Redis** master, replica, 3-node Sentinel, and HAProxy write proxy
- **Backups** to local disk + optional Cloudflare R2 (always 2 latest kept per DB)
- **Cross-Swarm** service discovery via Tailscale (see `docs/TAILSCALE.md`)
- **Monitoring**: Prometheus, Grafana, Loki, Alloy, Alertmanager, exporters (always included)

Replace `22` with your real SSH port. The script will:
1. Clone this repo to `/opt/infra`
2. Install Docker if missing
3. Initialize Docker Swarm
4. Create `.env` with auto-generated strong passwords
5. Build the custom Postgres image (PostGIS + pgvector + pg_cron)
6. Build the backup image
7. Open the PgBouncer firewall port
8. Deploy the full stack
9. Configure the PgBouncer auth role
10. Verify everything is reachable

## Manual install

If you'd rather clone yourself:

```bash
git clone https://github.com/oyenet1/postgres-vps-setup.git infra
cd infra
sudo ./setup.sh -s 22
```

## Common options

```bash
sudo ./setup.sh -s 22            # deploy (monitoring always included)
sudo ./setup.sh --no-start       # render config files only, no deploy
```

## After install

Postgres direct (admin only):
```
127.0.0.1:5432
```

PgBouncer (apps connect here):
```
postgres://postgres:PASSWORD@YOUR_VPS_IP:6543/DATABASE
```

Redis:
```
redis://:PASSWORD@127.0.0.1:6379
```

pgAdmin:
```
http://127.0.0.1:5050
```

## Connection URLs by use case

### Postgres via PgBouncer (recommended for all apps)

PgBouncer connection pooling is on port `6543`. Just change the database name in the URL.

| Where your app runs | URL |
|---|---|
| Same VPS (not Docker) | `postgres://postgres:PASS@127.0.0.1:6543/mydb` |
| Same VPS (Docker container, bridge network) | `postgres://postgres:PASS@HOST_IP:6543/mydb` |
| Same Docker Swarm (overlay network) | `postgres://postgres:PASS@pgbouncer:6432/mydb` |
| External / internet | `postgres://postgres:PASS@YOUR_VPS_IP:6543/mydb` |

Using the same stack with **multiple databases and roles**? PgBouncer routes by database name automatically and authenticates new login roles from Postgres:

```
postgres://app1_user:PASS@YOUR_VPS_IP:6543/app1
postgres://app2_user:PASS@YOUR_VPS_IP:6543/app2
postgres://app3_user:PASS@YOUR_VPS_IP:6543/app3
```

Just create each database and login role first (see below). No PgBouncer config edit or reload is needed.

### Postgres direct (admin tools only)

Skips PgBouncer. Use for migrations, pgAdmin, or admin tasks.

| Where | URL |
|---|---|
| Same VPS (not Docker) | `postgres://postgres:PASS@127.0.0.1:5432/mydb` |
| Same Docker Swarm | `postgres://postgres:PASS@postgres:5432/mydb` |

### Redis

| Where | URL |
|---|---|
| Same VPS (not Docker) | `redis://:PASS@127.0.0.1:6379/0` |
| Same Docker Swarm | `redis://:PASS@redis-proxy:6379/0` |
| External | `redis://:PASS@YOUR_VPS_IP:6379/0` |

Change `0` to any DB index (`0`–`15`) for separate Redis namespaces:

```
redis://:PASS@127.0.0.1:6379/0    # default / cache
redis://:PASS@127.0.0.1:6379/1    # sessions
redis://:PASS@127.0.0.1:6379/2    # queues
```

### Quick reference — common frameworks

**Node.js (Knex):**
```js
// pools through PgBouncer automatically
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
  database: mydb
  username: postgres
  password: PASS
  host: YOUR_VPS_IP
  port: 6543
  pool: 25
```

**Go (database/sql + pgx):**
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

Note: your app container must be on the `infra` overlay network to use service names (`pgbouncer`, `redis-proxy`). For external compose files, declare `networks: { infra: { external: true } }`.

## Monitoring

Always included. No extra flags needed. Comes with:
- **Grafana** (`http://YOUR_VPS_IP:3030`, admin / auto-generated password)
- **Prometheus** (metrics from postgres, pgbouncer, redis, node)
- **Loki** (log aggregation from all containers)
- **Alloy** (log collector)
- **Alertmanager** (email alerts on disk space, DB down, replica lag)

Pre-built dashboards:
- **Postgres** — queries, connections, cache hit ratio, replication lag
- **PgBouncer** — pool usage, client/server wait times
- **Redis** — memory, hit rate, connected clients, replication
- **Node** — CPU, RAM, disk, network
- **Docker** — container resource usage
- **Loki Logs** — all container logs in one place

## Create a database

```bash
docker run --rm --network infra postgres:17-alpine \
  psql -h postgres -U postgres -c "CREATE DATABASE myapp;"
```

Then connect:

```
postgres://postgres:PASSWORD@YOUR_VPS_IP:6543/myapp
```

Repeat for each app: `CREATE DATABASE app2;` → `postgres://.../app2`

## Environment

Edit `.env` to customize:

```env
POSTGRES_PASSWORD=...           # auto-generated on first run
PGADMIN_PASSWORD=...            # auto-generated
REDIS_PASSWORD=...              # auto-generated
GRAFANA_PASSWORD=...            # auto-generated

PGBOUNCER_PORT=6543
PGBOUNCER_BIND_ADDR=0.0.0.0     # apps reach PgBouncer on this port
PGBOUNCER_AUTH_USER=pgbouncer_auth
PGBOUNCER_AUTH_PASSWORD=...     # auto-generated; lets PgBouncer auth future roles

R2_BACKUP_ENABLED=false         # set true to upload to Cloudflare R2
R2_ACCESS_KEY_ID=...
R2_SECRET_ACCESS_KEY=...
R2_BUCKET=...

```

After editing, re-render and redeploy:
```bash
sudo ./setup.sh --no-start      # regenerate configs
./scripts/deploy.sh             # creates/validates the infra network, then deploys
```

If you deploy manually without the wrapper, create the swarm-scoped network first:

```bash
docker network create --driver overlay --attachable infra 2>/dev/null || true
./setup.sh --no-start
docker stack deploy -c docker-compose.yml infra
./scripts/configure-pgbouncer-auth.sh
```

## Ports

| Service | Default | Purpose |
|---|---|---|
| PgBouncer | `0.0.0.0:6543` | Main app endpoint for Postgres (TLS optional) |
| PostgreSQL | `127.0.0.1:5432` | Local admin only |
| PostgreSQL (direct) | `0.0.0.0:5544` | Direct PostgreSQL access (bypasses PgBouncer) |
| pgAdmin | `127.0.0.1:5050` | Browser UI |
| Redis | `127.0.0.1:6379` | Local Redis |
| Prometheus | `127.0.0.1:9090` | Monitoring only |
| Grafana | `127.0.0.1:3030` | Monitoring only |
| Alertmanager | `127.0.0.1:9093` | Monitoring only |
| Loki | `127.0.0.1:3100` | Monitoring only |

## Common operations

```bash
docker stack ps infra                    # show all services and their state
docker service logs infra_pgbouncer -f   # tail PgBouncer logs
docker service update --force infra_pgbouncer   # restart pgbouncer
docker stack rm infra                    # tear it all down
```

## Backups

Run every `BACKUP_INTERVAL_SECONDS` (default 12h). Each run creates one timestamped folder per database:

```
backups/
  20260621_235900/
    postgres.sql.gz
    myapp.sql.gz
    analytics.sql.gz
```

Only the 2 latest backups are kept per database (local + R2). Older ones auto-delete.

Force a backup now:
```bash
docker exec $(docker ps --filter name=infra_backup --format='{{.Names}}' | head -1) /bin/sh /scripts/backup.sh
```

Restore:
```bash
gunzip -c backups/20260621_235900/myapp.sql.gz | \
  docker run --rm -i --network infra postgres:17-alpine \
  psql -h postgres -U postgres -d myapp
```

## Cross-Swarm service names

To use `postgres`, `pgbouncer`, `redis-proxy` as names from other Swarms, install Tailscale on every VPS. See `docs/TAILSCALE.md`.

## Monitoring your apps (Prometheus + Grafana)

The infra stack ships with Prometheus, Grafana, Loki, and Alloy. Adding a new app to monitoring is a 3-step process that takes about 5 minutes:

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

A starter is included at `monitoring/targets/lodgestatus.json` (gitignored, so feel free to edit or delete).

### 3. Reload Prometheus (no service restart)

```bash
curl -X POST http://YOUR_VPS_IP:9090/-/reload
```

### Done. The app is now monitored.

Open Grafana at `http://YOUR_VPS_IP:3030` (login: `admin` / `GRAFANA_PASSWORD` from `infra/.env`).

**Pre-built dashboards** (auto-provisioned, no setup needed):

| Dashboard | What it shows |
|---|---|
| **Infrastructure Overview** | Host CPU/memory/disk, postgres connections, redis activity, app up/down status |
| **App Performance & Errors** | Per-app view: request rate, 4xx/5xx counts, latency percentiles, per-endpoint table, errors/stack-traces, full logs |

The **App Performance & Errors** dashboard has filter dropdowns at the top — pick one app or filter by method/path/status to drill in. Time range is the standard Grafana picker at the top-right (default: last 1 hour).

### Filtering on the App Performance & Errors dashboard

| Filter | Source | Notes |
|---|---|---|
| **Service** | `label_values(http_requests_total, service)` | All apps on the network. Multi-select. |
| **Method** | `label_values(..., method)` | GET, POST, PUT, etc. Multi-select. |
| **Endpoint** | `label_values(..., path)` | All route templates. Multi-select. |
| **Status** | `label_values(..., status)` | 200, 201, 4xx, 5xx. Multi-select. |
| **Time range** | Grafana picker | Top right. Default: last 1h. |

All panels (request rate, error counts, latency percentiles, endpoint table, log streams) respect the active filters.

### Why this is safe without auth

- The app's metrics endpoint should be on the overlay network only (no `mode: host` port publish for `/v1/metrics`).
- Only the prometheus container inside the `infra` stack can reach it.
- The app's `/v1/metrics` should have auth disabled (or accept requests from the overlay without a token). If you need bearer auth, see the [Prometheus file_sd docs](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#file_sd_config) for adding `bearer_token_file` per job.

### App metrics contract

The **App Performance & Errors** dashboard works for any app that exposes these Prometheus metrics. Adopt this in your app's metrics middleware:

```
# Counter: one increment per request
http_requests_total{method, path, status}

# Histogram: observation per request
http_request_duration_seconds{method, path, status}  (in seconds)
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

### Panel reference

| Panel | PromQL source | What it shows |
|---|---|---|
| Service Status | `up{job="apps"}` | 1 = up, 0 = down (one row per service) |
| Request Rate by Status | `rate(http_requests_total)` | Stacked line per status code |
| 4xx Errors / min | `rate(..., status=~"4..")` | 4xx rate, last 5 min |
| 5xx Errors / min | `rate(..., status=~"5..")` | 5xx rate, last 5 min |
| Endpoints (table) | `histogram_quantile(0.70/0.90/0.95)` + counters | Per-endpoint: visits, 400 count, 500 count, p70/p90/p95/avg in ms |
| Latency Percentiles | `histogram_quantile(0.50/0.90/0.95/0.99)` | p50, p90, p95, p99 over time |
| Errors / Stack Traces | Loki `{service="$service"} \|~ "(?i)(error|...)"` | Log lines containing errors |
| All logs | Loki `{service="$service"}` | Full log stream for the selected service |

### Adding more apps (recap)

1. Join the `infra` network
2. Drop a JSON in `monitoring/targets/`
3. `curl -X POST http://YOUR_VPS_IP:9090/-/reload`
4. Done — the app appears in every dashboard and the `$service` dropdown.
| Errors / Stack Traces | Loki `{service="$service"} \|~ "(?i)(error|exception|...)"` | Log lines containing errors |
| All logs | Loki `{service="$service"}` | Full log stream for the selected service |

The `$service` template variable is populated from the `service` label on `http_requests_total{job="apps"}`. It auto-updates as you add apps via `monitoring/targets/*.json`.

## Clean up Docker

Remove everything except running containers:
```bash
docker system prune -a --volumes -f
```

## Notes

- All passwords are auto-generated and stored in `.env` (gitignored)
- Single-node Swarm by default; add workers with `docker swarm join`
- For multi-node, `postgres_data` and `backup_data` need shared storage (NFS/EFS)
- Built-in extensions: postgis, postgis_topology, vector (pgvector), pg_cron, pg_stat_statements, pg_trgm, unaccent, btree_gin, btree_gist, hstore, ltree, citext, pgcrypto, uuid-ossp

## Extensions on new databases

The init script (`initdb/01-bootstrap.sql`) installs all supported extensions into both the default `postgres` database and the `template1` template database.

**What this means for you:**

- **New databases created via pgAdmin, `CREATE DATABASE`, or any client inherit extensions automatically** — they're cloned from `template1` by default, so postgis, vector, pg_cron, etc. are pre-enabled.
- **No need to run `CREATE EXTENSION ...` manually per database.**
- **App-side auto-bootstrap:** the lodgestatus server also runs `CREATE EXTENSION IF NOT EXISTS` for its required extensions on startup, so any database it connects to is guaranteed to have them (assuming the DB user has `CREATE EXTENSION` privilege). For databases the app never touches, the `template1` inheritance is what keeps them ready.

If an extension package is missing in the image (e.g. you switch to a plain `postgres` image without postgis), the init script logs a NOTICE and continues — the database still works, just without that extension.

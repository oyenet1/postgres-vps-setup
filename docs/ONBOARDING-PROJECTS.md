# Onboarding a Project to Shared Infrastructure

This guide is for **application developers** deploying a new Swarm stack that uses the shared **`infrastructure`** stack (Postgres, PgBouncer, Redis, monitoring).

Read this when starting any new SaaS project on the same server/cluster.

---

## Quick reference

| What | Value |
|------|-------|
| Shared network name | `infrastructure` |
| Infrastructure stack | `docker stack deploy -c docker-compose.yml infrastructure` |
| Database (runtime) | `pgbouncer:6543/<your_db_name>` |
| Database (migrations / create DB) | `postgres:5432/<your_db_name>` |
| Redis (runtime) | `redis-proxy:6379` |
| pgAdmin (browser) | host port `${PGADMIN_PORT:-5050}` |
| Grafana (browser) | host port `${GRAFANA_PORT:-3005}` |
| Prometheus (browser) | host port `${PROMETHEUS_PORT:-9090}` |

---

## Step 1 — Join the `infrastructure` network

In your app's `docker-compose.yml` (Swarm stack file):

```yaml
networks:
  infrastructure:
    external: true
    name: infrastructure

services:
  app:
    image: your-registry/your-app:${TAG}
    networks:
      - infrastructure
    deploy:
      replicas: 1
      restart_policy:
        condition: on-failure
```

Deploy:

```bash
docker stack deploy -c docker-compose.yml yourproject
```

Your app container can now reach all infrastructure services by **short DNS names** (`pgbouncer`, `redis-proxy`, `postgres`) because the infrastructure stack registers network aliases on the shared overlay.

---

## Step 2 — Create your database (one time)

1. Open **pgAdmin** (host port from infrastructure `.env`, default `5050`).
2. Connect to server `postgres` (already configured in infrastructure stack).
3. Create database: `yourproject_db` (pick a clear name, e.g. `lodgestatus_db`, `dukapos_db`).
4. Create a dedicated Postgres **role** for the app (recommended — do not reuse the superuser).

**No changes needed** in PgBouncer or backup config. New databases are routed and backed up automatically.

---

## Step 3 — Configure app environment

```bash
# Runtime — always through PgBouncer
DATABASE_URL=postgres://your_user:your_pass@pgbouncer:6543/yourproject_db

# Redis — always through HAProxy proxy
REDIS_URL=redis://:REDIS_PASSWORD@redis-proxy:6379

# Optional: app port for health/metrics (match your app)
APP_PORT=8001
METRICS_PORT=8001
```

Example service block:

```yaml
services:
  app:
    environment:
      DATABASE_URL: postgres://your_user:your_pass@pgbouncer:6543/yourproject_db
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis-proxy:6379
    healthcheck:
      test: ["CMD-SHELL", "curl -f http://localhost:8001/health || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
```

### Migrations / DDL

Run migrations against **Postgres directly** (not PgBouncer transaction pool):

```bash
DATABASE_URL=postgres://your_user:your_pass@postgres:5432/yourproject_db
```

Use this for `CREATE TABLE`, extensions, and one-off admin tasks.

---

## Step 4 — Add your app to Prometheus (metrics)

Infrastructure Prometheus lives in the **`infrastructure`** stack. To scrape your app, add a job in the **infrastructure repo**:

**File:** `monitoring/prometheus/prometheus.yml`

```yaml
scrape_configs:
  # ... existing jobs ...

  - job_name: 'yourproject'
    metrics_path: '/metrics'          # or /health/metrics — match your app
    scrape_interval: 15s
    static_configs:
      - targets: ['yourproject_app:8001']
        labels:
          project: yourproject
          environment: production
```

**Swarm DNS note:** If your stack is named `yourproject` and the service is `app`, the hostname on the shared network is **`yourproject_app`**.

Redeploy infrastructure after editing:

```bash
docker stack deploy -c docker-compose.yml infrastructure
```

### If your metrics endpoint requires auth

Use Prometheus `authorization` or a bearer token file (see infrastructure `monitoring/prometheus/` for examples):

```yaml
  - job_name: 'yourproject'
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/secrets/yourproject_metrics_token
    static_configs:
      - targets: ['yourproject_app:8001']
```

Mount the secret in the Prometheus service definition in infrastructure `docker-compose.yml`.

### What your app should expose

Minimum recommended metrics endpoint:

- `GET /health` — liveness (for Swarm healthcheck + optional probe)
- `GET /metrics` — Prometheus format (request count, latency, errors, pool stats)

---

## Step 5 — Add Grafana dashboards

Grafana is provisioned from the infrastructure repo.

### Option A — Drop a JSON dashboard (recommended)

1. Create dashboard JSON in your **app repo** (optional), then copy or symlink into infrastructure:

```
monitoring/grafana/dashboards/yourproject/
└── yourproject-overview.json
```

2. Ensure provisioning picks it up — **File:** `monitoring/grafana/provisioning/dashboards/dashboards.yml`:

```yaml
apiVersion: 1
providers:
  - name: infrastructure
    folder: Infrastructure
    options:
      path: /var/lib/grafana/dashboards/infrastructure

  - name: projects
    folder: Projects
    options:
      path: /var/lib/grafana/dashboards/projects
```

3. Mount the folder in infrastructure `docker-compose.yml` (grafana service):

```yaml
volumes:
  - ./monitoring/grafana/dashboards/projects:/var/lib/grafana/dashboards/projects:ro
```

4. Redeploy infrastructure stack.

### Option B — Build in Grafana UI

1. Open Grafana → create dashboard → save.
2. Export JSON → commit to `monitoring/grafana/dashboards/projects/yourproject/`.
3. Re-provision on next deploy so it survives restarts.

### Dashboard tips

- Use Prometheus labels: `project="yourproject"`.
- Link to shared infra panels (Postgres, Redis) — already in Infrastructure folder.
- Include: request rate, error rate, p95 latency, DB pool usage, Redis hit rate.

---

## Step 6 — Add alerts for your project

Alerts are defined in **infrastructure** Prometheus rule files.

**File:** `monitoring/prometheus/alert_rules.yml`

Add a group for your project:

```yaml
  - name: yourproject_alerts
    interval: 30s
    rules:
      - alert: YourProjectDown
        expr: up{job="yourproject"} == 0
        for: 2m
        labels:
          severity: critical
          project: yourproject
        annotations:
          summary: "YourProject app is down"
          description: "Prometheus cannot scrape yourproject_app:8001"

      - alert: YourProjectHighErrorRate
        expr: |
          sum(rate(http_requests_total{job="yourproject",status=~"5.."}[5m]))
          /
          sum(rate(http_requests_total{job="yourproject"}[5m]))
          > 0.05
        for: 5m
        labels:
          severity: warning
          project: yourproject
        annotations:
          summary: "YourProject error rate above 5%"

      - alert: YourProjectHighLatency
        expr: histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{job="yourproject"}[5m])) by (le)) > 2
        for: 5m
        labels:
          severity: warning
          project: yourproject
        annotations:
          summary: "YourProject p95 latency above 2s"
```

Adjust metric names to match what your app exports.

### Alert routing (email)

Alertmanager is configured in `monitoring/alertmanager/alertmanager.yml`. By default all alerts email `${ALERT_TO}`.

Optional: route by project label:

```yaml
route:
  routes:
    - match:
        project: yourproject
      receiver: yourproject-email

receivers:
  - name: yourproject-email
    email_configs:
      - to: 'yourteam@example.com'
        send_resolved: true
```

Redeploy infrastructure after rule changes.

---

## Step 7 — Logs (Loki via Alloy)

**You do not configure logging in your app stack.** Alloy runs globally on each Swarm node, reads Docker container logs via `/var/run/docker.sock`, and ships them to Loki.

### Find your logs in Grafana

1. Open Grafana → Explore → datasource **Loki**.
2. Query by container name:

```logql
{container_name=~"yourproject.*"}
```

Or by Swarm service:

```logql
{service_name="yourproject_app"}
```

### Structured JSON logs (recommended)

Log as JSON from your app so Loki queries are easier:

```json
{"level":"error","project":"yourproject","msg":"payment failed","order_id":"123"}
```

Query:

```logql
{container_name=~"yourproject.*"} | json | level="error"
```

### Optional — request infrastructure team add a Loki alert

Example rule (infrastructure `alert_rules.yml`):

```yaml
      - alert: YourProjectErrorSpike
        expr: sum(count_over_time({container_name=~"yourproject.*"} | json | level="error" [5m])) > 50
        for: 5m
        labels:
          severity: warning
          project: yourproject
        annotations:
          summary: "YourProject error log spike"
```

*(Requires Loki ruler if enabled; otherwise use Grafana alert rules on Loki queries.)*

---

## Step 8 — Checklist before going live

- [ ] Stack joins `infrastructure` network (`external: true`, `name: infrastructure`)
- [ ] Database created in pgAdmin; migrations run against `postgres:5432`
- [ ] Runtime uses `pgbouncer:6543/<db>` and `redis-proxy:6379`
- [ ] Healthcheck configured on app service
- [ ] Prometheus scrape job added (`yourproject_app:<port>`)
- [ ] Grafana dashboard added under `dashboards/projects/yourproject/`
- [ ] Alert rules added (`YourProjectDown`, error rate, latency)
- [ ] Test alert fires to email (temporarily stop app or break `/metrics`)
- [ ] Logs visible in Grafana Explore (Loki)
- [ ] Secrets not committed to git (use Swarm secrets or `.env` on server only)

---

## Connection from outside Docker (host / CI)

If the app runs on the **host** (not in Swarm), use localhost ports bound by infrastructure:

| Service | Host address |
|---------|--------------|
| PgBouncer | `127.0.0.1:6543` |
| Redis proxy | `127.0.0.1:6380` |
| Postgres (if exposed) | `127.0.0.1:5434` |

Inside Swarm containers, always use internal names (`pgbouncer`, `redis-proxy`).

---

## Getting help

| Issue | Where to look |
|-------|---------------|
| DB connection refused | On `infrastructure` network? Using `pgbouncer:6543` not `postgres:5432` for runtime? |
| New DB not working via PgBouncer | DB must exist in Postgres first; check user/password |
| Prometheus shows `DOWN` | DNS target must be `yourstack_yourservice:port`; check `/metrics` path |
| No logs in Loki | Container running? Alloy global service healthy? |
| Alerts not emailing | Check Alertmanager config + SMTP env in infrastructure `.env` |

Infrastructure PRD: `docs/PRD-infrastructure-stack.md`

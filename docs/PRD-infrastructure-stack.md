# PRD: Shared Infrastructure Stack

**Version:** 1.3  
**Status:** Ready for implementation  
**Project:** infrastructure (repo: dbsetup)  
**Stack name:** `infrastructure`  
**Network name:** `infrastructure`  
**Target:** Docker Swarm (single-node initially, multi-node ready)

---

## 1. Summary

Build a **single, shared Docker Swarm stack named `infrastructure`** that provides database, cache, and observability for **all current and future SaaS applications**.

Any project deploys its own Swarm stack, joins the shared overlay network **`infrastructure`**, and reaches Postgres, Redis, and monitoring by **stable short hostnames** (`pgbouncer`, `redis-proxy`, `postgres`).

**Core promises (must be true):**

> **Database:** Create a new PostgreSQL database in pgAdmin. Every app immediately connects via `pgbouncer:6543/<new_db_name>` — no PgBouncer config changes.

> **Backup:** That same database is included in the next scheduled R2 backup (1am + 12pm) — no backup config changes.

> **Monitoring:** Developer follows `docs/ONBOARDING-PROJECTS.md` to add Prometheus scrape, Grafana dashboard, and alerts — clear, repeatable steps.

---

## 2. Naming (use everywhere)

| Concept | Name | Notes |
|---------|------|-------|
| Swarm stack | `infrastructure` | `docker stack deploy -c docker-compose.yml infrastructure` |
| Overlay network | `infrastructure` | Explicit `name: infrastructure` — other projects join this |
| Repo folder | `dbsetup/` | Can stay; stack/network name is `infrastructure` |
| Developer guide | `docs/ONBOARDING-PROJECTS.md` | How to connect + monitoring + alerts |

**Other projects join the network:**

```yaml
networks:
  infrastructure:
    external: true
    name: infrastructure
```

---

## 3. Goals

1. **One Postgres/PostGIS instance** serving many application databases.
2. **PgBouncer as the only app-facing database endpoint** — wildcard routing for all DBs.
3. **pgAdmin** for database administration.
4. **Redis HA**: master + replica + Sentinel (×3) + HAProxy `redis-proxy`.
5. **Full observability**: Prometheus, Grafana, Alloy, Loki, Alertmanager, exporters.
6. **Swarm-native**: overlay network, stack deploy, secrets, healthchecks.
7. **Shared network `infrastructure`**: any project stack attaches externally — easy to reach services.
8. **Stable DNS aliases** on the network so projects use `pgbouncer`, not `infrastructure_pgbouncer`.
9. **Automatic R2 backups** of all databases twice daily (1am + 12pm).
10. **Developer onboarding doc** for metrics, dashboards, logs, and alerts per project.

---

## 4. Non-Goals

- Per-app Postgres or Redis instances.
- Kubernetes.
- Auto-create databases when an app starts.
- Multi-region replication.
- Plain `docker compose up` as primary production path (Swarm also supported).

---

## 5. Architecture

### 5.1 Network — `infrastructure`

| Property | Value |
|----------|-------|
| **Name** | `infrastructure` |
| Driver | `overlay` |
| Attachable | `true` |
| Owner | Created by `infrastructure` stack |

**Stack network definition:**

```yaml
networks:
  infrastructure:
    name: infrastructure
    driver: overlay
    attachable: true
```

**External project stacks:**

```yaml
networks:
  infrastructure:
    external: true
    name: infrastructure
```

### 5.2 DNS aliases (required)

Register **short aliases** on the `infrastructure` network so all projects use the same hostnames regardless of stack name:

| Alias | Service | Port |
|-------|---------|------|
| `postgres` | postgres | 5432 |
| `pgbouncer` | pgbouncer | 6543 |
| `redis-proxy` | redis-proxy | 6379 |
| `redis-master` | redis-master | 6379 |
| `prometheus` | prometheus | 9090 |
| `grafana` | grafana | 3000 |
| `loki` | loki | 3100 |
| `alertmanager` | alertmanager | 9093 |

Example per service:

```yaml
services:
  pgbouncer:
    networks:
      infrastructure:
        aliases:
          - pgbouncer
```

Without aliases, cross-stack DNS would require `infrastructure_pgbouncer` — aliases keep connections simple.

### 5.3 Service topology

```
┌─────────────────────────────────────────────────────────────────┐
│  network: infrastructure (overlay, attachable)                  │
│  stack:   infrastructure                                        │
│                                                                 │
│  DATA PLANE                                                     │
│  ├── postgres (PostGIS 17)          ← admin / DDL / backups     │
│  ├── pgbouncer                      ← ALL app runtime DB traffic│
│  ├── pgadmin                        ← web UI                      │
│  ├── backup                         ← all DBs → gzip → R2       │
│                                                                 │
│  REDIS HA                                                       │
│  ├── redis-master / redis-replica                               │
│  ├── redis-sentinel (×3)                                        │
│  └── redis-proxy (HAProxy)          ← apps connect HERE         │
│                                                                 │
│  OBSERVABILITY                                                  │
│  ├── prometheus / grafana / alertmanager                        │
│  ├── loki / alloy (global)                                      │
│  └── postgres_exporter / redis_exporter / node_exporter / cadvisor│
└─────────────────────────────────────────────────────────────────┘
         ▲                    ▲                    ▲
         │  join external     │                    │
   stack: myapp           stack: lodgestatus    stack: ...
   network: infrastructure (external: true)
```

### 5.4 Connection rules

| Consumer | Host | Port |
|----------|------|------|
| **Apps (runtime DB)** | `pgbouncer` | 6543 |
| **Apps (Redis)** | `redis-proxy` | 6379 |
| **pgAdmin / migrations / backup** | `postgres` | 5432 |
| **Prometheus scrapes app** | `{stack}_{service}` | app metrics port |

### 5.5 Complete service list

**Yes — PgBouncer is included.** It is the mandatory app-facing database gateway.

#### Data plane

| Service | Purpose | Replicas |
|---------|---------|----------|
| **postgres** | PostGIS 17 PostgreSQL — all SaaS databases | 1 |
| **pgbouncer** | Connection pooler — **all app DB traffic** | 1 |
| **pgadmin** | Web UI — create DBs, users, run SQL | 1 |
| **backup** | All DBs → gzip → Cloudflare R2 (1am + 12pm) | 1 |

#### Redis HA

| Service | Purpose | Replicas |
|---------|---------|----------|
| **redis-master** | Primary Redis node | 1 |
| **redis-replica** | Read replica + failover candidate | 1 |
| **redis-sentinel** | Monitors master, triggers failover | 3 |
| **redis-proxy** | HAProxy — **apps connect here** | 1 |

#### Observability

| Service | Purpose | Replicas |
|---------|---------|----------|
| **prometheus** | Metrics collection + alert evaluation | 1 |
| **grafana** | Dashboards (infra + per-project) | 1 |
| **alertmanager** | Email / alert routing | 1 |
| **loki** | Log storage | 1 |
| **alloy** | Ships Docker container logs → Loki | global |
| **postgres_exporter** | Postgres metrics | 1 |
| **redis_exporter** | Redis metrics | 1 |
| **node_exporter** | Host CPU/RAM/disk metrics | global |
| **cadvisor** | Container resource metrics | global |

**Total: 18 services** in the infrastructure stack (excluding future app stacks).

---

## 6. PgBouncer — automatic multi-database routing

```ini
[databases]
* = host=postgres port=5432
```

New DB in pgAdmin → immediately available at `pgbouncer:6543/<dbname>`. No reload.

Pool: `transaction` mode, `scram-sha-256`, `MAX_CLIENT_CONN=10000`, `DEFAULT_POOL_SIZE=100`.

---

## 7. PostgreSQL / PostGIS — extensions enabled by default

### 7.1 Image

Build from **`Dockerfile.postgres`** (extends `postgis/postgis:17-3.5`):

- Base: PostGIS 3.5 on PostgreSQL 17
- Added via apt: **`pgvector`**, **`pg_cron`**
- `shared_preload_libraries`: `pg_cron`, `pg_stat_statements`

Do **not** use plain `postgis/postgis` without the Dockerfile — vector and pg_cron are not in the official image.

### 7.2 Extension policy

**All supported extensions must be installed and enabled by default** on:

1. The initial database (`postgres` / `POSTGRES_DB`)
2. **`template1`** — so every **new database** created in pgAdmin automatically has the same extensions (no manual `CREATE EXTENSION` per project)

Init script: `ini.sql` (mounted to `/docker-entrypoint-initdb.d/`).

If an extension package is missing, init logs a NOTICE and continues (non-fatal).

### 7.3 Extension catalogue (must enable all that are available)

#### Geospatial / PostGIS / location search

| Extension | Purpose |
|-----------|---------|
| `postgis` | Core GIS — points, polygons, spatial queries |
| `postgis_topology` | Topology-based geometry |
| `postgis_raster` | Raster grid data |
| `postgis_sfcgal` | Advanced 3D / SFCGAL geometry |
| `postgis_tiger_geocoder` | US address geocoding (TIGER data) |
| `address_standardizer` | Parse/normalize street addresses |
| `address_standardizer_data_us` | US address standardizer rules data |
| `cube` | Multidimensional cubes (used with earthdistance) |
| `earthdistance` | Great-circle distance / location proximity search |

#### Text search & fuzzy matching

| Extension | Purpose |
|-----------|---------|
| `pg_trgm` | Trigram similarity — fuzzy text / LIKE search |
| `unaccent` | Strip accents for search |
| `fuzzystrmatch` | Soundex, metaphone, Levenshtein |
| `btree_gin` | GIN index support for btree-equivalent ops |
| `btree_gist` | GiST index support for btree-equivalent ops |

#### AI / vector

| Extension | Purpose |
|-----------|---------|
| `vector` | pgvector — embedding similarity search (AI/RAG) |

#### Scheduling

| Extension | Purpose |
|-----------|---------|
| `pg_cron` | Run SQL jobs on a schedule inside Postgres |

#### Performance & observability

| Extension | Purpose |
|-----------|---------|
| `pg_stat_statements` | Query performance statistics |
| `pg_prewarm` | Preload relation data into buffer cache |

#### Data types & utilities

| Extension | Purpose |
|-----------|---------|
| `hstore` | Key-value store column type |
| `ltree` | Hierarchical tree labels |
| `citext` | Case-insensitive text |
| `intarray` | 1D integer array ops |
| `pgcrypto` | Cryptographic functions |
| `uuid-ossp` | UUID generation |
| `tablefunc` | Crosstab / connectby table functions |
| `isn` | ISBN, EAN, ISMN types |
| `seg` | Line segment type |

### 7.4 New database behaviour

When developer creates `myapp_db` in pgAdmin:

- Extensions already present (from `template1`) — **ready for PostGIS, vector search, location queries, pg_trgm, etc.**
- App connects via `pgbouncer:6543/myapp_db` — no extension setup needed

### 7.5 Storage & deploy

- Volume: `postgres_data_v17`
- `replicas: 1`, pinned to manager or `node.labels.db=true`
- Optional host bind: `127.0.0.1:${POSTGRES_HOST_PORT:-5434}:5432`

---

## 8. pgAdmin

- Connect to `postgres:5432`
- Host port: `${PGADMIN_PORT:-5050}:80`
- Volume: `pgadmin_data`

---

## 9. Redis HA cluster

**Implement exactly as specified below** (same pattern as production dukapos stack). Reference file: `docs/reference-redis-ha.compose.yml`.

### 9.1 Overview

| Service | Replicas | Purpose |
|---------|----------|---------|
| `redis-master` | 1 | Primary write node (AOF persistence) |
| `redis-replica` | 1 | Read replica + failover candidate |
| `redis-sentinel` | 3 | Quorum failover monitoring |
| `redis-proxy` | 1 | HAProxy — **only endpoint apps use** |
| `redis_exporter` | 1 | Prometheus metrics (scrapes `redis-proxy`) |

### 9.2 App connection (mandatory)

```bash
REDIS_URL=redis://:${REDIS_PASSWORD}@redis-proxy:6379
REDIS_SENTINEL_MASTER_NAME=infrastructure-master
REDIS_SENTINEL_URL=redis-sentinel://redis-sentinel:26379   # optional, Sentinel-aware clients
```

Apps on external stacks join network `infrastructure` and use hostname **`redis-proxy`** (network alias).

### 9.3 Environment variables

```bash
REDIS_PASSWORD=                          # required — same password on master, replica, sentinel
REDIS_MASTER_PORT=6379                   # host bind 127.0.0.1 only
REDIS_PROXY_PORT=6380                    # host bind 127.0.0.1 — apps on host use this
REDIS_SENTINEL_PORT=26379                # host bind 127.0.0.1
REDIS_SENTINEL_MASTER_NAME=infrastructure-master
REDIS_EXPORTER_PORT=9121
```

### 9.4 Global logging (all Redis services)

```yaml
x-logging: &default-logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "3"
```

Each Redis service: `logging: *default-logging`

### 9.5 Service definitions (copy into `docker-compose.yml`)

Network is **`infrastructure`** (not `possible_net`). Sentinel master name is **`infrastructure-master`**.

#### redis-master

- Image: `redis:7-alpine`
- Command: `redis-server --appendonly yes --requirepass ${REDIS_PASSWORD} --masterauth ${REDIS_PASSWORD}`
- Volume: `redis_master_data:/data`
- Port: `127.0.0.1:${REDIS_MASTER_PORT:-6379}:6379`
- Healthcheck: `redis-cli -a ${REDIS_PASSWORD} --no-auth-warning ping`
- Deploy: `replicas: 1`, placement `node.role == manager`
- Network alias: `redis-master`

#### redis-replica

- Image: `redis:7-alpine`
- Command: `--replicaof redis-master 6379 --requirepass ... --masterauth ... --replica-read-only yes --appendonly yes`
- Volume: `redis_replica_data:/data`
- No host port (internal only)
- Deploy: `replicas: 1`
- Network alias: `redis-replica`

#### redis-sentinel (×3)

- Image: `redis:7-alpine`
- Startup script waits for `redis-master` DNS + PONG, then writes `/tmp/sentinel.conf`:
  - `sentinel monitor infrastructure-master redis-master 6379 2` (quorum 2 of 3)
  - `sentinel auth-pass infrastructure-master ${REDIS_PASSWORD}`
  - `sentinel down-after-milliseconds 5000`
  - `sentinel failover-timeout 60000`
  - `sentinel parallel-syncs 1`
  - `sentinel resolve-hostnames yes`
  - `sentinel announce-hostnames yes`
- Port: `127.0.0.1:${REDIS_SENTINEL_PORT:-26379}:26379`
- Deploy: **`replicas: 3`** (required for quorum)
- Healthcheck: `redis-cli -p 26379 SENTINEL master infrastructure-master`

#### redis-proxy (HAProxy)

- Image: `haproxy:2.9-alpine`
- Generates `/tmp/haproxy.cfg` at start with:
  - Docker DNS resolver `127.0.0.11:53`
  - TCP health check: AUTH → PING → `INFO replication` → must see `role:master`
  - Backends: `redis-master:6379` and `redis-replica:6379` (routes to whichever is master)
- Port: `127.0.0.1:${REDIS_PROXY_PORT:-6380}:6379`
- Deploy: `replicas: 1`
- Network alias: **`redis-proxy`** (apps connect here)

Full HAProxy config — **do not simplify**:

```yaml
redis-proxy:
  image: haproxy:2.9-alpine
  logging: *default-logging
  command:
    - sh
    - -ec
    - |
      cat > /tmp/haproxy.cfg << HAPROXYEOF
      global
          log stdout format raw local0
          maxconn 50000

      defaults
          mode tcp
          log global
          timeout connect 5s
          timeout client 60s
          timeout server 60s
          option tcplog

      resolvers docker
          nameserver dns 127.0.0.11:53
          resolve_retries 3
          timeout resolve 1s
          timeout retry 1s
          hold valid 2s

      frontend redis_front
          bind *:6379
          default_backend redis_master_backend

      backend redis_master_backend
          option tcp-check
          tcp-check send "AUTH ${REDIS_PASSWORD}\r\n"
          tcp-check expect string +OK
          tcp-check send "PING\r\n"
          tcp-check expect string +PONG
          tcp-check send "INFO replication\r\n"
          tcp-check expect string role:master
          tcp-check send "QUIT\r\n"
          tcp-check expect string +OK
          server redis-master redis-master:6379 check inter 1000 rise 2 fall 2 resolvers docker resolve-prefer ipv4
          server redis-replica redis-replica:6379 check inter 1000 rise 2 fall 2 resolvers docker resolve-prefer ipv4
      HAPROXYEOF
      exec haproxy -W -db -f /tmp/haproxy.cfg
  ports:
    - "127.0.0.1:${REDIS_PROXY_PORT:-6380}:6379"
  networks:
    infrastructure:
      aliases:
        - redis-proxy
  healthcheck:
    test: ["CMD-SHELL", "nc -z 127.0.0.1 6379 || exit 1"]
    interval: 10s
    timeout: 3s
    retries: 5
    start_period: 20s
  deploy:
    replicas: 1
    restart_policy:
      condition: on-failure
      delay: 10s
      max_attempts: 5
```

#### redis_exporter

```yaml
redis_exporter:
  image: oliver006/redis_exporter:v1.63.0
  environment:
    REDIS_ADDR: redis://redis-proxy:6379
    REDIS_PASSWORD: ${REDIS_PASSWORD}
  ports:
    - "${REDIS_EXPORTER_PORT:-9121}:9121"
  networks:
    - infrastructure
  deploy:
    replicas: 1
```

### 9.6 Volumes

```yaml
volumes:
  redis_master_data:
  redis_replica_data:
```

### 9.7 Swarm notes

- **`depends_on` is ignored in Swarm** — sentinel startup script already waits for master; do not rely on depends_on.
- Do **not** expose master/replica ports publicly — only `127.0.0.1` for master, proxy, sentinel admin.
- After Sentinel failover, HAProxy automatically routes to the new master (health check `role:master`).

### 9.8 Acceptance — Redis

- [ ] All 4 Redis services + exporter healthy after `docker stack deploy`.
- [ ] `redis-cli -h redis-proxy -a $PASS PING` → PONG from any container on `infrastructure`.
- [ ] 3 sentinel replicas running (`docker service ls`).
- [ ] Stop master → failover within 60s → proxy still accepts writes.
- [ ] Prometheus scrapes `redis_exporter:9121`.

---

## 10. Backup service

- **All** non-template databases, each → `.sql.gz`
- **Schedule:** `0 1 * * *` (1am) and `0 12 * * *` (12pm), timezone `TZ`
- **Upload:** Cloudflare R2 via rclone (env-provided credentials)
- **Prefix:** `${R2_PREFIX:-infrastructure-backups/}`
- **Retention:** `${R2_MAX_BACKUPS_PER_DB:-14}` per DB on R2
- Swarm-safe: `pg_dump` to `postgres:5432` over network (no `docker exec`)
- New DB → next run includes it automatically
- Email alert on failure; optional success report

See v1.1 backup section details in git history; requirements unchanged.

---

## 11. Observability stack

### 11.1 Infrastructure services

Prometheus, Grafana, Alertmanager, Loki, Alloy (global), postgres_exporter, redis_exporter, node_exporter (global), cadvisor (global).

### 11.2 Per-project monitoring (implementer must enable)

Infrastructure must support **adding projects without restructuring**:

1. **Prometheus** — add scrape job per project in `monitoring/prometheus/prometheus.yml`
2. **Grafana** — folder `Projects/` provisioned from `monitoring/grafana/dashboards/projects/<project>/`
3. **Alerts** — add rule group per project in `monitoring/prometheus/alert_rules.yml`
4. **Logs** — Alloy ships all container logs to Loki; projects query by `container_name` or `service_name` (no per-app Alloy config)
5. **Alertmanager** — email via SMTP env; optional route by `project` label

### 11.3 Developer documentation (deliverable)

**Must ship:** `docs/ONBOARDING-PROJECTS.md` covering:

- Join `infrastructure` network
- Create DB + connection strings
- Add Prometheus scrape job (with Swarm DNS `{stack}_{service}`)
- Add Grafana dashboard JSON
- Add Prometheus alert rules
- Query logs in Loki / Grafana Explore
- Alertmanager routing
- Pre-go-live checklist

This README is the **contract** between infrastructure and application repos.

### 11.4 Grafana provisioning structure

```
monitoring/grafana/
├── provisioning/
│   ├── datasources/datasources.yml    # Prometheus + Loki
│   └── dashboards/dashboards.yml
└── dashboards/
    ├── infrastructure/                # Postgres, Redis, node, containers
    └── projects/                      # one subfolder per app project
        └── <project>/
            └── overview.json
```

### 11.5 Default infrastructure alerts (already required)

- Postgres / PgBouncer down
- High connection counts
- Backup failed / missing
- Container down

Projects add their own groups (see onboarding doc).

---

## 12. Future application stacks

```yaml
networks:
  infrastructure:
    external: true
    name: infrastructure

services:
  app:
    networks:
      - infrastructure
    environment:
      DATABASE_URL: postgres://user:pass@pgbouncer:6543/myapp_db
      REDIS_URL: redis://:pass@redis-proxy:6379
    deploy:
      replicas: 3
```

Deploy: `docker stack deploy -c compose.yml myapp`  
Prometheus target: `myapp_app:8001`  
Developer guide: `docs/ONBOARDING-PROJECTS.md`

---

## 13. Swarm deployment

```bash
docker swarm init
docker stack deploy -c docker-compose.yml infrastructure
```

Verify network:

```bash
docker network ls | grep infrastructure
```

---

## 14. Environment variables

See `.env.example` — include all Postgres, PgBouncer, pgAdmin, Redis, monitoring, R2 backup, and alert SMTP vars.

Key renames from v1.1:

```bash
REDIS_SENTINEL_MASTER_NAME=infrastructure-master
R2_PREFIX=infrastructure-backups/
```

---

## 15. File structure (deliverables)

```
dbsetup/
├── docker-compose.yml                    # stack name: infrastructure
├── Dockerfile.postgres                   # PostGIS + pgvector + pg_cron
├── .env.example
├── ini.sql                               # all extensions → postgres + template1
├── pgbouncer/
├── monitoring/
│   ├── prometheus/
│   │   ├── prometheus.yml
│   │   └── alert_rules.yml
│   ├── alertmanager/
│   ├── grafana/
│   │   ├── provisioning/
│   │   └── dashboards/
│   │       ├── infrastructure/
│   │       └── projects/                 # per-app dashboards
│   ├── loki/
│   └── alloy/
├── templates/
│   ├── backup-all.sh
│   ├── backup.cron
│   └── rclone-r2.conf.template
├── docs/
│   ├── PRD-infrastructure-stack.md       # this file
│   ├── ONBOARDING-PROJECTS.md            # developer guide (required)
│   └── reference-redis-ha.compose.yml    # Redis HA copy-paste reference
└── README.md                             # operator deploy + link to onboarding doc
```

---

## 16. Acceptance criteria

### Infrastructure core

- [ ] `docker stack deploy -c docker-compose.yml infrastructure` succeeds.
- [ ] Overlay network **`infrastructure`** exists and is attachable.
- [ ] Short DNS works from external stack: `pgbouncer`, `redis-proxy`, `postgres`.
- [ ] Custom `Dockerfile.postgres` image builds with pgvector + pg_cron.
- [ ] All extensions in Section 7.3 enabled in `postgres` and `template1` on first init.
- [ ] New database created in pgAdmin has PostGIS, vector, pg_trgm, earthdistance without manual `CREATE EXTENSION`.
- [ ] All DBs backed up to R2 at 1am and 12pm.

### Redis HA

- [ ] Sentinel + redis-proxy failover works; apps use `redis-proxy:6379`.

### Monitoring

- [ ] Grafana shows Infrastructure dashboards (Postgres, Redis, nodes).
- [ ] Sample project scrape job + dashboard + alert rule documented and tested.
- [ ] `docs/ONBOARDING-PROJECTS.md` complete and linked from README.
- [ ] Alloy → Loki; logs searchable in Grafana for a test app container.
- [ ] Alertmanager sends test email.

### Developer experience

- [ ] Developer can onboard a new project using only `ONBOARDING-PROJECTS.md` without asking infra details.
- [ ] Checklist in onboarding doc is accurate against running stack.

---

## 17. Security

- Secrets in env/Swarm secrets only — never git.
- R2 credentials private; bucket private.
- PgBouncer/Redis host ports on `127.0.0.1`.
- `scram-sha-256` for PgBouncer.
- Metrics endpoints: support bearer token where apps require auth.

---

## 18. Simplicity principles

1. **One network name: `infrastructure`** — every project uses the same join snippet.
2. **Short DNS aliases** — always `pgbouncer`, never stack-prefixed names in app config.
3. **Wildcard PgBouncer + wildcard backups** — new DB = zero infra work.
4. **One onboarding doc** — monitoring/dashboards/alerts in one place.
5. **Stateful = 1 replica**; app stacks scale horizontally.

---

## 19. Success statement

1. Deploy: `docker stack deploy -c docker-compose.yml infrastructure`
2. Create `new_saas_db` in pgAdmin
3. New project joins network `infrastructure`, connects to `pgbouncer` + `redis-proxy`
4. Developer follows `docs/ONBOARDING-PROJECTS.md` for metrics, dashboards, alerts
5. Backups land in R2 twice daily — automatically

**That is the product.**

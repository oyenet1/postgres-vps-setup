# Infra

Single-VPS Docker Swarm stack for shared application infrastructure:

- PostgreSQL 17 with PostGIS, pgvector, pg_cron
- PgBouncer on public host port `6543`
- pgAdmin
- Redis master, replica, Sentinel (3 nodes), and HAProxy write proxy
- Individual database backups to local disk + optional Cloudflare R2
- Optional Prometheus, Grafana, Loki, Alloy, Alertmanager, and exporters

## Prerequisites

Build and push the backup image (or let setup.sh build it locally):

```bash
bash scripts/build-backup-image.sh
```

For multi-node Swarm clusters push to a registry and set `INFRA_BACKUP_IMAGE`.

## Install

```bash
sudo ./setup.sh -s 22
```

Use your real SSH port instead of `22`. The script will:

- install Docker if missing
- initialize Docker Swarm if not active
- create or update `.env`
- generate strong passwords for placeholder values
- render local runtime config files
- build the backup image
- open the PgBouncer firewall port
- deploy the stack
- configure PgBouncer auth
- verify PgBouncer and Redis are reachable

Enable monitoring during install:

```bash
sudo ./setup.sh -s 22 -m
```

Render files without starting containers:

```bash
sudo ./setup.sh --no-start
```

## Environment

```env
POSTGRES_DB=postgres
POSTGRES_USER=postgres
POSTGRES_PASSWORD=change_me_postgres_password
PGADMIN_EMAIL=admin@example.com
PGADMIN_PASSWORD=change_me_pgadmin_password
REDIS_PASSWORD=change_me_redis_password
GRAFANA_PASSWORD=change_me_grafana_password

PGBOUNCER_PORT=6543
PGBOUNCER_BIND_ADDR=0.0.0.0

R2_BACKUP_ENABLED=true
R2_ACCOUNT_ID=your_cloudflare_account_id
R2_ACCESS_KEY_ID=your_r2_access_key_id
R2_SECRET_ACCESS_KEY=your_r2_secret_access_key
R2_BUCKET=your_bucket_name
R2_PREFIX=infra/
```

`setup.sh` generates passwords automatically when it sees `change_me_*` placeholders.

## Ports

| Service | Default host binding | Purpose |
| --- | --- | --- |
| PgBouncer | `0.0.0.0:6543` | Main external PostgreSQL endpoint for apps |
| PostgreSQL | `127.0.0.1:5432` | Local direct admin access only |
| pgAdmin | `127.0.0.1:5050` | Browser admin UI |
| Redis proxy | `127.0.0.1:6379` | Local Redis endpoint |
| Prometheus | `127.0.0.1:9090` | Metrics, monitoring only |
| Grafana | `127.0.0.1:3030` | Dashboards, monitoring only |
| Alertmanager | `127.0.0.1:9093` | Alerts, monitoring only |
| Loki | `127.0.0.1:3100` | Logs, monitoring only |

## Connection Strings

External app through PgBouncer:

```text
postgres://POSTGRES_USER:POSTGRES_PASSWORD@YOUR_SERVER_IP:6543/DATABASE_NAME
```

Local Redis through HAProxy:

```text
redis://:REDIS_PASSWORD@127.0.0.1:6379
```

## Backups

Each run creates one timestamped local folder:

```text
backups/
  20260621_235900/
    postgres.sql.gz
    myapp.sql.gz
    analytics.sql.gz
```

Run a backup immediately:

```bash
docker exec $(docker ps --filter name=infra_backup --format='{{.Names}}' | head -1) /bin/sh /scripts/backup.sh
```

Restore one database:

```bash
gunzip -c backups/20260621_235900/myapp.sql.gz | docker run --rm -i --network infra postgres:17-alpine psql -h postgres -U "$POSTGRES_USER" -d myapp
```

## Monitoring

Deploy the monitoring stack:

```bash
MONITORING_ENABLED=true bash scripts/deploy.sh
```

Or manually:

```bash
docker stack deploy -c docker-compose.yml -c docker-compose.monitoring.yml infra
```

## Operations

Show stack:

```bash
docker stack ps infra
```

View PgBouncer logs:

```bash
docker service logs infra_pgbouncer -f
```

Restart a service after config changes:

```bash
docker service update --force infra_pgbouncer
```

Remove the stack:

```bash
docker stack rm infra
```

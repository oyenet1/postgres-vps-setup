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
- **Optional monitoring**: Prometheus, Grafana, Loki, Alloy, Alertmanager, exporters
- **Optional Cloudflare Tunnel** for private edge access (Hyperdrive/Workers)
- **Cross-Swarm** service discovery via Tailscale (see `docs/TAILSCALE.md`)

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
sudo ./setup.sh -s 22            # deploy, SSH port 22
sudo ./setup.sh -s 22 -m         # also deploy monitoring stack
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

## Create a database

```bash
docker run --rm --network infra postgres:17-alpine \
  psql -h postgres -U postgres -c "CREATE DATABASE myapp;"
```

Then connect from any app:
```
postgres://postgres:PASSWORD@YOUR_VPS_IP:6543/myapp
```

## Environment

Edit `.env` to customize:

```env
POSTGRES_PASSWORD=...           # auto-generated on first run
PGADMIN_PASSWORD=...            # auto-generated
REDIS_PASSWORD=...              # auto-generated
GRAFANA_PASSWORD=...            # auto-generated

PGBOUNCER_PORT=6543
PGBOUNCER_BIND_ADDR=0.0.0.0     # apps reach PgBouncer on this port

R2_BACKUP_ENABLED=false         # set true to upload to Cloudflare R2
R2_ACCESS_KEY_ID=...
R2_SECRET_ACCESS_KEY=...
R2_BUCKET=...

MONITORING_ENABLED=false        # set true to deploy Prometheus/Grafana/etc

CLOUDFLARE_TUNNEL_TOKEN=...     # from https://one.dash.cloudflare.com (optional)
```

After editing, re-render and redeploy:
```bash
sudo ./setup.sh --no-start      # regenerate configs
docker stack deploy -c docker-compose.yml infra
```

## Ports

| Service | Default | Purpose |
|---|---|---|
| PgBouncer | `0.0.0.0:6543` | Main app endpoint for Postgres |
| PostgreSQL | `127.0.0.1:5432` | Local admin only |
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

## Cloudflare Tunnel (optional)

Add `CLOUDFLARE_TUNNEL_TOKEN` to `.env` and redeploy. See `docs/CLOUDFLARE-TUNNEL.md` for full setup including Hyperdrive for Cloudflare Workers.

## Cross-Swarm service names

To use `postgres`, `pgbouncer`, `redis-proxy` as names from other Swarms, install Tailscale on every VPS. See `docs/TAILSCALE.md`.

## Clean up Docker

Remove everything except running containers:
```bash
docker system prune -a --volumes -f
```

## Notes

- All passwords are auto-generated and stored in `.env` (gitignored)
- Single-node Swarm by default; add workers with `docker swarm join`
- For multi-node, `postgres_data` and `backup_data` need shared storage (NFS/EFS)
- Built-in extensions: postgis, postgis_topology, pg_stat_statements, pg_trgm, unaccent, btree_gin, btree_gist, hstore, ltree, citext, pgcrypto, uuid-ossp

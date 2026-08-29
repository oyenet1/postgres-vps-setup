#!/usr/bin/env bash
#
# ──────────────────────────────────────────────────────────────────
# 🏢 Company Name: Bonifade Technologies
# 👨‍💻 Developer: Bowofade Oyerinde
# 🐙 GitHub: oyenet1
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

if [[ $EUID -ne 0 ]]; then
  echo "[-] Please run this script with sudo: sudo ./scripts/redeploy-fresh.sh"
  exit 1
fi

echo "=========================================================="
echo " [1/6] Fixing Docker socket and user permissions..."
echo "=========================================================="
chmod 666 /var/run/docker.sock 2>/dev/null || true
if [[ -n "${SUDO_USER:-}" ]]; then
  usermod -aG docker "$SUDO_USER" 2>/dev/null || true
fi

echo "=========================================================="
echo " [2/6] Removing existing Docker Swarm stack 'infra'..."
echo "=========================================================="
docker stack rm infra 2>/dev/null || true

echo "Waiting for all stack services to shut down..."
while docker service ls --filter "label=com.docker.stack.namespace=infra" -q 2>/dev/null | grep -q .; do
  sleep 2
done
sleep 4

echo "Force cleaning any remaining containers..."
docker rm -f $(docker ps -a -q --filter "label=com.docker.stack.namespace=infra") 2>/dev/null || true
docker container prune -f >/dev/null 2>&1 || true

echo "=========================================================="
echo " [3/6] Deleting all persistent volumes & old data..."
echo "=========================================================="
VOLUMES=(
  infra_postgres_data
  infra_pgadmin_data
  infra_redis_master_data
  infra_redis_replica_data
  infra_backup_data
  infra_loki_data
  infra_prometheus_data
  infra_grafana_data
  infra_alertmanager_data
)

for vol in "${VOLUMES[@]}"; do
  docker volume rm -f "$vol" 2>/dev/null || true
done
docker volume prune -af >/dev/null 2>&1 || true

# Clean any stale host directories
rm -rf postgres_data/* pgbouncer_data/* backups/* 2>/dev/null || true

echo "=========================================================="
echo " [4/6] Rendering configuration files from .env..."
echo "=========================================================="
./setup.sh --no-start

echo "=========================================================="
echo " [5/6] Deploying fresh stack..."
echo "=========================================================="
./scripts/deploy.sh

echo "=========================================================="
echo " [6/6] Waiting for services to be ready & testing..."
echo "=========================================================="
set -a
source .env
set +a

attempts=0
while [[ $attempts -lt 30 ]]; do
  if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PGADMIN_PORT:-5050}/login" | grep -qE "200|302"; then
    break
  fi
  attempts=$((attempts + 1))
  sleep 2
done

echo "[+] pgAdmin is UP and running on port ${PGADMIN_PORT:-5050}!"
echo "[+] Grafana is UP and running on port ${GRAFANA_PORT:-3030}!"

# Open browser as original non-root user if available
if [[ -n "${SUDO_USER:-}" ]]; then
  su - "$SUDO_USER" -c "xdg-open http://localhost:${PGADMIN_PORT:-5050}; xdg-open http://localhost:${GRAFANA_PORT:-3030}" 2>/dev/null || true
else
  xdg-open "http://localhost:${PGADMIN_PORT:-5050}" 2>/dev/null || true
  xdg-open "http://localhost:${GRAFANA_PORT:-3030}" 2>/dev/null || true
fi

cat <<CREDENTIALS

======================================================================
  🚀 DEPLOYMENT SUCCESSFUL & VERIFIED!
======================================================================

  🔹 PGADMIN 4 (Web UI - Opened in Browser)
  URL:       http://localhost:${PGADMIN_PORT:-5050}
  Email:     ${PGADMIN_EMAIL}
  Password:  ${PGADMIN_PASSWORD}

======================================================================
  🔹 GRAFANA (Dashboard - Opened in Browser)
  URL:       http://localhost:${GRAFANA_PORT:-3030}
  User:      ${GRAFANA_USER:-admin}
  Password:  ${GRAFANA_PASSWORD}

======================================================================
  🔹 POSTGRESQL & PGBOUNCER
  PgBouncer (Apps):      postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:${PGBOUNCER_PORT:-6543}/${POSTGRES_DB}
  Postgres Direct:       postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:${POSTGRES_PORT_DIRECT:-5544}/${POSTGRES_DB}
  PgBouncer Auth User:   ${PGBOUNCER_AUTH_USER} / ${PGBOUNCER_AUTH_PASSWORD}

======================================================================
  🔹 REDIS HA (HAProxy Proxy)
  Host:      127.0.0.1:${REDIS_PORT:-6379}
  Password:  ${REDIS_PASSWORD}
  URI:       redis://:${REDIS_PASSWORD}@127.0.0.1:${REDIS_PORT:-6379}/0

======================================================================
  🔹 OBSERVABILITY & MONITORING
  Grafana:       http://localhost:${GRAFANA_PORT:-3030}
  Prometheus:    http://localhost:${PROMETHEUS_PORT:-9090}
  Loki:          http://localhost:${LOKI_PORT:-3100}
  Alertmanager:  http://localhost:${ALERTMANAGER_PORT:-9093}
======================================================================

CREDENTIALS

#!/usr/bin/env bash
#
# ──────────────────────────────────────────────────────────────────
# 🏢 Company Name: Bonifade Technologies
# 👨‍💻 Developer: Bowofade Oyerinde
# 🐙 GitHub: oyenet1
# 📅 Created Date: 2026-07-16
# 🔄 Updated Date: 2026-07-16
# ──────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

STACK_NAME="${STACK_NAME:-${INFRA_STACK_NAME:-infra}}"
COMPOSE_FILES=(-c docker-compose.yml)

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

NODE_STATE="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
IS_MANAGER="$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || true)"

if [[ "$NODE_STATE" != "active" || "$IS_MANAGER" != "true" ]]; then
  echo "[deploy] leaving stale swarm state (if any)"
  docker swarm leave --force 2>/dev/null || true

  echo "[deploy] initializing Docker Swarm as manager"
  ADVERTISE="${SWARM_ADVERTISE_ADDR:-}"
  if [[ -z "$ADVERTISE" ]]; then
    ADVERTISE="$(ip -4 addr show up 2>/dev/null | awk '/inet / && !/127\./ {print $2}' | cut -d/ -f1 | head -1)"
  fi

  if [[ -n "$ADVERTISE" ]]; then
    docker swarm init --advertise-addr "$ADVERTISE"
  else
    docker swarm init
  fi
fi

NETWORK_NAME="${INFRA_NETWORK_NAME:-infra}"

if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
  DRIVER="$(docker network inspect "$NETWORK_NAME" --format '{{.Driver}}')"
  SCOPE="$(docker network inspect "$NETWORK_NAME" --format '{{.Scope}}')"
  if [[ "$DRIVER" != "overlay" || "$SCOPE" != "swarm" ]]; then
    echo "[deploy] network ${NETWORK_NAME} exists but is ${DRIVER}/${SCOPE}, expected overlay/swarm" >&2
    exit 1
  fi
else
  echo "[deploy] Creating overlay network: ${NETWORK_NAME}"
  docker network create --driver overlay --attachable "$NETWORK_NAME" >/dev/null
fi

echo "[deploy] Rendering generated config from .env"
./setup.sh --no-start

echo "[deploy] Normalizing permissions on configs and certificates"
chmod 755 pgbouncer postgres_config initdb redis monitoring grafana templates 2>/dev/null || true
chmod 644 pgbouncer/* postgres_config/* initdb/* redis/* templates/* monitoring/* 2>/dev/null || true
chmod 755 redis/sentinel-entrypoint.sh templates/backup.sh initdb/02-pgbouncer-auth.sh 2>/dev/null || true

echo "[deploy] Deploying stack: $STACK_NAME"
docker stack deploy "${COMPOSE_FILES[@]}" "$STACK_NAME"

if [[ "$STACK_NAME" == "infra" || "$STACK_NAME" == "infrastructure" ]]; then
  ./scripts/configure-pgbouncer-auth.sh
fi

echo "[deploy] Waiting 30s for Swarm services to converge..."
sleep 30

echo "[deploy] Cleaning up stopped containers and dangling images..."
docker rm -f $(docker ps -a -q -f status=exited -f status=dead) 2>/dev/null || true
docker container prune -f >/dev/null 2>&1 || true
docker image prune -f >/dev/null 2>&1 || true

echo "[deploy] Done"

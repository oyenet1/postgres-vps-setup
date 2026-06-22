#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

STACK_NAME="${STACK_NAME:-infra}"
COMPOSE_FILES=(-c docker-compose.yml)

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

if docker network inspect infra >/dev/null 2>&1; then
  DRIVER="$(docker network inspect infra --format '{{.Driver}}')"
  SCOPE="$(docker network inspect infra --format '{{.Scope}}')"
  if [[ "$DRIVER" != "overlay" || "$SCOPE" != "swarm" ]]; then
    echo "[deploy] network infra exists but is ${DRIVER}/${SCOPE}, expected overlay/swarm" >&2
    exit 1
  fi
else
  echo "[deploy] Creating persistent overlay network: infra"
  docker network create --driver overlay --attachable infra >/dev/null
fi

echo "[deploy] Deploying stack: $STACK_NAME"
docker stack deploy "${COMPOSE_FILES[@]}" "$STACK_NAME"

echo "[deploy] Done"

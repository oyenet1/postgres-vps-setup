#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

STACK_NAME="${STACK_NAME:-infra}"
COMPOSE_FILES=(-c docker-compose.yml)

if [[ "${MONITORING_ENABLED:-false}" == "true" ]]; then
  COMPOSE_FILES+=(-c docker-compose.monitoring.yml)
fi

if ! docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active; then
  echo "[deploy] Initializing Docker Swarm"
  docker swarm init --advertise-addr "${SWARM_ADVERTISE_ADDR:-eth0}"
fi

echo "[deploy] Deploying stack: $STACK_NAME"
docker stack deploy "${COMPOSE_FILES[@]}" "$STACK_NAME"

echo "[deploy] Done"

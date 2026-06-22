#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${1:-infra/backup:latest}"

docker build \
  -t "$IMAGE" \
  -f "$SCRIPT_DIR/Dockerfile.backup" \
  "$SCRIPT_DIR"

echo ""
echo "Built: $IMAGE"
echo ""
echo "If deploying to a multi-node Swarm, push to a registry:"
echo "  docker push $IMAGE"
echo ""
echo "Then set INFRA_BACKUP_IMAGE=$IMAGE in your env."

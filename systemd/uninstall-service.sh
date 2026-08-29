#!/usr/bin/env bash
#
# ──────────────────────────────────────────────────────────────────
# 🏢 Company Name: Bonifade Technologies
# 👨‍💻 Developer: Bowofade Oyerinde
# 🐙 GitHub: oyenet1
# 📅 Created Date: 2026-08-29
# ──────────────────────────────────────────────────────────────────
#
# Uninstalls the infra-stack systemd service.
# Usage: sudo ./systemd/uninstall-service.sh
#
set -euo pipefail

SERVICE_NAME="infra-stack"

if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] This script must be run with sudo" >&2
  exit 1
fi

echo "[1/3] Stopping ${SERVICE_NAME} service..."
systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true

echo "[2/3] Disabling ${SERVICE_NAME} service..."
systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true

echo "[3/3] Removing service file..."
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload

echo ""
echo "✅ ${SERVICE_NAME}.service has been removed."
echo "   Note: Docker auto-start was NOT disabled. Run 'sudo systemctl disable docker' if desired."
echo ""

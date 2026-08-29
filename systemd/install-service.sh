#!/usr/bin/env bash
#
# ──────────────────────────────────────────────────────────────────
# 🏢 Company Name: Bonifade Technologies
# 👨‍💻 Developer: Bowofade Oyerinde
# 🐙 GitHub: oyenet1
# 📅 Created Date: 2026-08-29
# ──────────────────────────────────────────────────────────────────
#
# Installs the infra-stack systemd service so the stack starts on boot.
# Usage: sudo ./systemd/install-service.sh
#
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVICE_NAME="infra-stack"
SERVICE_FILE="${SCRIPT_DIR}/${SERVICE_NAME}.service"

if [[ $EUID -ne 0 ]]; then
  printf '%b\n' "${RED}[ERROR]${NC} This script must be run with sudo" >&2
  exit 1
fi

if [[ ! -f "$SERVICE_FILE" ]]; then
  printf '%b\n' "${RED}[ERROR]${NC} Service file not found: ${SERVICE_FILE}" >&2
  exit 1
fi

# ── 1. Enable Docker to start on boot ────────────────────────────
printf '%b\n' "${CYAN}[1/5]${NC} Enabling Docker to start on boot..."
systemctl enable docker.service
systemctl enable containerd.service

# ── 2. Ensure Docker is running now ──────────────────────────────
printf '%b\n' "${CYAN}[2/5]${NC} Starting Docker if not running..."
systemctl start docker.service

# ── 3. Make deploy.sh executable ─────────────────────────────────
printf '%b\n' "${CYAN}[3/5]${NC} Ensuring deploy.sh is executable..."
chmod +x "${INFRA_DIR}/scripts/deploy.sh"
chmod +x "${INFRA_DIR}/setup.sh"

# ── 4. Install the systemd service ──────────────────────────────
printf '%b\n' "${CYAN}[4/5]${NC} Installing ${SERVICE_NAME}.service..."

# Update WorkingDirectory and paths in the service file to match this install
sed \
  -e "s|WorkingDirectory=.*|WorkingDirectory=${INFRA_DIR}|" \
  -e "s|EnvironmentFile=.*|EnvironmentFile=${INFRA_DIR}/.env|" \
  -e "s|ExecStart=.*|ExecStart=${INFRA_DIR}/scripts/deploy.sh|" \
  "$SERVICE_FILE" > "/etc/systemd/system/${SERVICE_NAME}.service"

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.service"

# ── 5. Verify ────────────────────────────────────────────────────
printf '%b\n' "${CYAN}[5/5]${NC} Verifying installation..."

printf '\n'
printf '%b\n' "${GREEN}══════════════════════════════════════════════════════════════${NC}"
printf '%b\n' "${GREEN}  ✅ ${SERVICE_NAME}.service installed and enabled!${NC}"
printf '%b\n' "${GREEN}══════════════════════════════════════════════════════════════${NC}"
printf '\n'
printf '%b\n' "The infra stack will now start automatically on every boot."
printf '\n'
printf '%b\n' "${YELLOW}Useful commands:${NC}"
printf '%b\n' "  ${CYAN}sudo systemctl status ${SERVICE_NAME}${NC}    — check service status"
printf '%b\n' "  ${CYAN}sudo systemctl start  ${SERVICE_NAME}${NC}    — start the stack now"
printf '%b\n' "  ${CYAN}sudo systemctl stop   ${SERVICE_NAME}${NC}    — stop the stack"
printf '%b\n' "  ${CYAN}sudo systemctl restart ${SERVICE_NAME}${NC}   — redeploy the stack"
printf '%b\n' "  ${CYAN}sudo journalctl -u ${SERVICE_NAME} -f${NC}   — view live logs"
printf '%b\n' "  ${CYAN}sudo systemctl disable ${SERVICE_NAME}${NC}   — disable auto-start"
printf '\n'

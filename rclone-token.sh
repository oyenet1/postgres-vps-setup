#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  rclone Google Drive Token Generator${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""
echo -e "${YELLOW}This script helps you get a Google Drive token${NC}"
echo -e "${YELLOW}for use with backup configurations.${NC}"
echo ""
echo -e "${CYAN}Prerequisites:${NC}"
echo -e "  - Run this on your LOCAL computer (with browser)${NC}"
echo -e "  - Install rclone: curl https://rclone.org/install.sh | sh${NC}"
echo ""

if ! command -v rclone &> /dev/null; then
    echo -e "${CYAN}[INFO] Installing rclone...${NC}"
    curl -fsSL https://rclone.org/install.sh | sh
fi

echo -e "${CYAN}[INFO] Starting rclone configuration...${NC}"
echo -e "${CYAN}Follow the prompts:${NC}"
echo ""
echo -e "  1. Choose 'n' (New remote)"
echo -e "  2. Enter name: ${GREEN}gdrive${NC}"
echo -e "  3. Storage: choose ${GREEN}24 (Google Drive)${NC}"
echo -e "  4. Client ID/Secret: leave blank (press Enter)"
echo -e "  5. Scope: choose ${GREEN}1 (Full access)${NC}"
echo -e "  6. Team Drive: choose 'n'"
echo -e "  7. Auto config: choose ${GREEN}n (headless)${NC}"
echo -e "  8. A URL will appear - paste it in your browser${NC}"
echo -e "  9. Authorize and paste the code back here"
echo ""
rclone config

echo ""
echo -e "${CYAN}[INFO] Extracting token...${NC}"

RCLONE_CONFIG="${HOME}/.config/rclone/rclone.conf"
if [[ ! -f "${RCLONE_CONFIG}" ]]; then
    RCLONE_CONFIG="${HOME}/.rclone.conf"
fi

TOKEN=$(grep -A5 "\[gdrive\]" "${RCLONE_CONFIG}" 2>/dev/null | grep "token" | sed 's/token = //' | head -1)

if [[ -z "${TOKEN}" ]]; then
    echo -e "${RED}[ERROR] Could not extract token from config${NC}"
    echo -e "${CYAN}Please manually copy the token from:${NC}"
    echo -e "${CYAN}${RCLONE_CONFIG}${NC}"
    echo -e "${CYAN}Look for 'token = ' in the [gdrive] section${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  COPY THIS TOKEN BELOW${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo "${TOKEN}"
echo ""
echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN}  USAGE INSTRUCTIONS${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""
echo -e "  1. Copy the token above"
echo -e "  2. On your VPS, edit the .env file:"
echo -e "     ${YELLOW}nano /path/to/your/.env${NC}"
echo -e "  3. Update this line with your token:"
echo -e "     ${YELLOW}GOOGLE_DRIVE_TOKEN=${NC}"
echo ""
echo -e "${CYAN}Alternatively, run this command on your VPS:${NC}"
echo -e "  ${YELLOW}sed -i 's/GOOGLE_DRIVE_TOKEN=.*/GOOGLE_DRIVE_TOKEN=${TOKEN}/' .env${NC}"
echo ""
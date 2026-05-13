#!/bin/bash
set -e

echo "============================================"
echo "  rclone Google Drive Token Generator"
echo "============================================"
echo ""
echo "Run this on your LOCAL computer (with browser)"
echo ""

INSTALL_RCLONE=""

if command -v rclone &> /dev/null; then
    echo "[OK] rclone is already installed"
else
    echo "[INFO] rclone not found, installing..."

    if command -v curl &> /dev/null; then
        DOWNLOADER="curl -fsSL"
    elif command -v wget &> /dev/null; then
        DOWNLOADER="wget -qO-"
    else
        echo "[ERROR] Neither curl nor wget found. Please install one of them first."
        exit 1
    fi

    if command -v uname &> /dev/null; then
        OS=$(uname -s)
        if [[ "$OS" == "Darwin" ]]; then
            echo "[INFO] Detected macOS - installing rclone via brew..."
            if command -v brew &> /dev/null; then
                brew install rclone
            else
                echo "[ERROR] Homebrew not found. Install from: https://brew.sh"
                exit 1
            fi
        elif [[ "$OS" == "Linux" ]]; then
            eval "${DOWNLOADER} https://rclone.org/install.sh | sh"
        else
            eval "${DOWNLOADER} https://rclone.org/install.sh | sh"
        fi
    else
        eval "${DOWNLOADER} https://rclone.org/install.sh | sh"
    fi
fi

if ! command -v rclone &> /dev/null; then
    echo "[ERROR] rclone installation failed"
    exit 1
fi

echo ""
echo "[INFO] Starting rclone configuration..."
echo "Follow the prompts:"
echo ""
echo "  1. Choose 'n' (New remote)"
echo "  2. Enter name: gdrive"
echo "  3. Storage: choose 24 (Google Drive)"
echo "  4. Client ID/Secret: leave blank (press Enter)"
echo "  5. Scope: choose 1 (Full access)"
echo "  6. Team Drive: choose 'n'"
echo "  7. Auto config: choose n (headless)"
echo "  8. A URL will appear - paste it in your browser"
echo "  9. Authorize and paste the code back here"
echo ""
rclone config

echo ""
echo "[INFO] Extracting token..."

if [[ "$OSTYPE" == "darwin"* ]]; then
    RCLONE_CONFIG="${HOME}/Library/Application Support/rclone/rclone.conf"
    [[ ! -f "${RCLONE_CONFIG}" ]] && RCLONE_CONFIG="${HOME}/.config/rclone/rclone.conf"
else
    RCLONE_CONFIG="${HOME}/.config/rclone/rclone.conf"
    [[ ! -f "${RCLONE_CONFIG}" ]] && RCLONE_CONFIG="${HOME}/.rclone.conf"
fi

TOKEN=$(grep -A5 "\[gdrive\]" "${RCLONE_CONFIG}" 2>/dev/null | grep "token" | sed 's/token = //' | head -1)

if [[ -z "${TOKEN}" ]]; then
    echo "[ERROR] Could not extract token from config"
    echo "Please manually copy the token from: ${RCLONE_CONFIG}"
    echo "Look for 'token = ' in the [gdrive] section"
    exit 1
fi

echo ""
echo "============================================"
echo "  COPY THIS TOKEN BELOW"
echo "============================================"
echo ""
echo "${TOKEN}"
echo ""
echo "============================================"
echo "  USAGE INSTRUCTIONS"
echo "============================================"
echo ""
echo "  1. Copy the token above"
echo "  2. On your VPS, edit the .env file:"
echo "     nano /path/to/your/.env"
echo "  3. Update this line with your token:"
echo "     GOOGLE_DRIVE_TOKEN=<paste_token_here>"
echo ""
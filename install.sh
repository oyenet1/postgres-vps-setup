#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/oyenet1/postgres-vps-setup.git}"
BRANCH="${BRANCH:-postgis}"
INSTALL_DIR="${INSTALL_DIR:-/opt/infra}"

usage() {
  cat <<EOF
Usage: curl -fsSL https://raw.githubusercontent.com/oyenet1/postgres-vps-setup/postgis/install.sh | sudo bash -s -- -s SSH_PORT [options]

Options:
  -s PORT      SSH port to allow if UFW is available
  -m           enable monitoring profile
  --no-start   render files only, do not start containers
  -h           show this help

Environment overrides:
  REPO_URL     git URL (default: $REPO_URL)
  BRANCH       git branch (default: $BRANCH)
  INSTALL_DIR  target directory (default: $INSTALL_DIR)
EOF
}

SSH_PORT=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s)
      SSH_PORT="$2"
      shift 2
      ;;
    -m|--monitoring)
      EXTRA_ARGS+=("-m")
      shift
      ;;
    --no-start)
      EXTRA_ARGS+=("--no-start")
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[install] unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "[install] re-run with sudo" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "[install] installing git"
  apt-get update -qq && apt-get install -y -qq git
fi

if [[ -d "$INSTALL_DIR/.git" ]]; then
  echo "[install] updating existing repo at $INSTALL_DIR"
  git -C "$INSTALL_DIR" fetch origin
  git -C "$INSTALL_DIR" reset --hard "origin/$BRANCH"
else
  echo "[install] cloning $REPO_URL (branch: $BRANCH) to $INSTALL_DIR"
  rm -rf "$INSTALL_DIR"
  git clone --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

chmod +x setup.sh scripts/*.sh

echo "[install] running setup.sh ${EXTRA_ARGS[*]} -s ${SSH_PORT:-<not set>}"
exec ./setup.sh "${EXTRA_ARGS[@]}" -s "$SSH_PORT"

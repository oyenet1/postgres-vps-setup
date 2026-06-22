#!/bin/sh
set -eu

: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"

BACKUP_DIR=/backups
LOCK_FILE="${BACKUP_DIR}/.backup.lock"
DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"
RCLONE_CONFIG="${RCLONE_CONFIG:-/config/rclone/rclone.conf}"
RETENTION="${BACKUP_RETENTION:-2}"
R2_ENABLED="${R2_BACKUP_ENABLED:-false}"
R2_REMOTE="${R2_REMOTE:-r2}"
R2_BUCKET="${R2_BUCKET:-}"
R2_PREFIX="${R2_PREFIX:-infra/}"
R2_MAX="${R2_MAX_BACKUPS_PER_DB:-2}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_DIR="${BACKUP_DIR}/${TIMESTAMP}"

mkdir -p "$BACKUP_DIR"

if ! mkdir "$LOCK_FILE" 2>/dev/null; then
  echo "[backup] another backup process is running (lock: $LOCK_FILE)"
  exit 1
fi
trap 'rm -rf "$LOCK_FILE"' EXIT

export PGPASSWORD="$POSTGRES_PASSWORD"

DATABASES="$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d postgres -Atc "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname")"

if [ -z "$DATABASES" ]; then
  echo "[backup] no databases found"
  exit 1
fi

mkdir -p "$RUN_DIR"

echo "[backup] starting individual database backups in $RUN_DIR"

case "$R2_PREFIX" in
  */) ;;
  *) R2_PREFIX="${R2_PREFIX}/" ;;
esac

if [ "$R2_ENABLED" = "true" ]; then
  if [ -z "$R2_BUCKET" ]; then
    echo "[backup] R2_BACKUP_ENABLED=true but R2_BUCKET is empty"
    exit 1
  fi

  if ! command -v rclone >/dev/null 2>&1; then
    echo "[backup] R2_BACKUP_ENABLED=true but rclone is not installed"
    exit 1
  fi
fi

for db in $DATABASES; do
  file="${RUN_DIR}/${db}.sql.gz"
  echo "[backup] dumping $db"
  pg_dump -h "$DB_HOST" -p "$DB_PORT" -U "$POSTGRES_USER" -d "$db" | gzip > "$file"

  if [ ! -s "$file" ]; then
    echo "[backup] backup file is empty for database: $db"
    rm -f "$file"
    exit 1
  fi

  if [ "$R2_ENABLED" = "true" ]; then
    remote_dir="${R2_REMOTE}:${R2_BUCKET}/${R2_PREFIX}${db}"
    remote_file="${remote_dir}/${TIMESTAMP}.sql.gz"
    echo "[backup] uploading $db to R2: ${R2_PREFIX}${db}/${TIMESTAMP}.sql.gz"
    rclone --config "$RCLONE_CONFIG" copyto "$file" "$remote_file"

    rclone --config "$RCLONE_CONFIG" lsf "$remote_dir/" --files-only 2>/dev/null \
      | sort -r \
      | tail -n +"$((R2_MAX + 1))" \
      | while IFS= read -r old; do
          [ -n "$old" ] && rclone --config "$RCLONE_CONFIG" deletefile "${remote_dir}/${old}" || true
        done
  fi
done

ls -1dt "$BACKUP_DIR"/*/ 2>/dev/null | tail -n +"$((RETENTION + 1))" | xargs -r rm -rf

echo "[backup] completed: $(basename "$RUN_DIR")"

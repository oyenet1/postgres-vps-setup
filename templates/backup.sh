#!/bin/bash
set -e

BACKUP_DIR="/backups"
GOOGLE_DRIVE_REMOTE="${GOOGLE_DRIVE_REMOTE_NAME}"
GOOGLE_DRIVE_FOLDER="${GOOGLE_DRIVE_FOLDER}"
DATABASE="${POSTGRES_DB}"
DB_USER="${POSTGRES_USER}"
DB_HOST="postgres"
DB_PORT="5432"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="backup_${DATABASE}_${TIMESTAMP}.sql.gz"

echo "[INFO] Starting backup of database: ${DATABASE}"

docker exec postgres pg_dump -U "${DB_USER}" -d "${DATABASE}" | gzip > "${BACKUP_DIR}/${BACKUP_FILE}"

echo "[INFO] Backup completed: ${BACKUP_FILE}"

if command -v rclone &> /dev/null; then
    rclone copy "${BACKUP_DIR}/${BACKUP_FILE}" "${GOOGLE_DRIVE_REMOTE}:${GOOGLE_DRIVE_FOLDER}/" --progress
    echo "[SUCCESS] Backup uploaded to Google Drive"
else
    echo "[WARNING] rclone not found, skipping upload"
fi

find "${BACKUP_DIR}" -name "backup_*.sql.gz" -mtime +30 -delete 2>/dev/null || true
cd "${BACKUP_DIR}" && ls -t backup_*.sql.gz | tail -n +4 | xargs -r rm -f

echo "[SUCCESS] Backup process completed"
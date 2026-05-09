#!/bin/bash
set -e

BACKUP_DIR="/backups"
GOOGLE_DRIVE_REMOTE="${GOOGLE_DRIVE_REMOTE_NAME}"
GOOGLE_DRIVE_FOLDER="${GOOGLE_DRIVE_FOLDER}"
DATABASE="${POSTGRES_DB}"
DB_USER="${POSTGRES_USER}"
DB_HOST="postgres"
DB_PORT="5432"
MAX_BACKUPS="${MAX_BACKUPS:-3}"
ALERT_EMAIL_TO="${ALERT_EMAIL_TO:-}"
SMTP_HOST="${SMTP_HOST:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_FROM="${SMTP_FROM:-}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="backup_${DATABASE}_${TIMESTAMP}.sql.gz"
BACKUP_SIZE=""

send_alert_email() {
    local subject="$1"
    local body="$2"

    if [[ -z "${ALERT_EMAIL_TO}" || -z "${SMTP_HOST}" ]]; then
        return
    fi

    apt-get update -qq && apt-get install -y -qq msmtp > /dev/null 2>&1

    cat > /tmp/msmtp_config << EOF
defaults
auth on
tls on
tls_certcheck off
host ${SMTP_HOST}
port ${SMTP_PORT}
from ${SMTP_FROM}
user ${SMTP_USER}
password ${SMTP_PASSWORD}
EOF

    echo -e "From: ${SMTP_FROM}\nTo: ${ALERT_EMAIL_TO}\nSubject: ${subject}\n\n${body}" | msmtp -C /tmp/msmtp_config -t "${ALERT_EMAIL_TO}"
}

echo "[INFO] Starting backup of database: ${DATABASE}"

START_TIME=$(date +%s)

docker exec postgres pg_dump -U "${DB_USER}" -d "${DATABASE}" 2>/dev/null | gzip > "${BACKUP_DIR}/${BACKUP_FILE}"

if [[ ! -f "${BACKUP_DIR}/${BACKUP_FILE}" ]]; then
    ERROR_MSG="[ERROR] Backup failed - pg_dump returned error"
    echo "${ERROR_MSG}"
    send_alert_email "[CRITICAL] Database Backup Failed - ${DATABASE}" "Backup failed for database ${DATABASE} at $(date).\n\nError: pg_dump command failed.\n\nPlease check the database server immediately."
    exit 1
fi

BACKUP_SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_FILE}" | cut -f1)
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "[INFO] Backup completed: ${BACKUP_FILE} (${BACKUP_SIZE})"

UPLOAD_STATUS="FAILED"
if command -v rclone &> /dev/null; then
    if rclone copy "${BACKUP_DIR}/${BACKUP_FILE}" "${GOOGLE_DRIVE_REMOTE}:${GOOGLE_DRIVE_FOLDER}/" --progress 2>&1; then
        UPLOAD_STATUS="SUCCESS"
        echo "[SUCCESS] Backup uploaded to Google Drive"

        echo "[INFO] Cleaning up old backups on Google Drive (keeping ${MAX_BACKUPS})..."
        rclone lsf "${GOOGLE_DRIVE_REMOTE}:${GOOGLE_DRIVE_FOLDER}/" --sort-by=modtime,desc 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | while read file; do
            rclone delete "${GOOGLE_DRIVE_REMOTE}:${GOOGLE_DRIVE_FOLDER}/${file}" 2>/dev/null || true
            echo "[INFO] Deleted old backup: ${file}"
        done
        echo "[SUCCESS] Google Drive cleanup completed"
    else
        UPLOAD_STATUS="FAILED - rclone error"
    fi
else
    UPLOAD_STATUS="SKIPPED - rclone not found"
fi

find "${BACKUP_DIR}" -name "backup_*.sql.gz" -mtime +30 -delete 2>/dev/null || true
cd "${BACKUP_DIR}" && ls -t backup_*.sql.gz 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -f

BACKUP_COUNT=$(ls -1 "${BACKUP_DIR}"/backup_*.sql.gz 2>/dev/null | wc -l)
POSTGRES_STATUS=$(docker exec postgres pg_isready -U "${DB_USER}" 2>/dev/null && echo "UP" || echo "DOWN")
PGBOUNCER_STATUS=$(docker exec pgbouncer pgbouncer --version 2>/dev/null && echo "UP" || echo "DOWN")
BACKUP_STATUS="SUCCESS"
if [[ "${UPLOAD_STATUS}" != "SUCCESS" ]]; then
    BACKUP_STATUS="WARNING - Upload issues"
fi

EMAIL_BODY="Database Backup Report - ${DATABASE}
==========================================
Date: $(date '+%Y-%m-%d %H:%M:%S')
Database: ${DATABASE}
Backup File: ${BACKUP_FILE}
Size: ${BACKUP_SIZE}
Duration: ${DURATION} seconds
Upload Status: ${UPLOAD_STATUS}
Local Backups Kept: ${BACKUP_COUNT}

Service Status:
----------------
PostgreSQL: ${POSTGRES_STATUS}
PgBouncer: ${PGBOUNCER_STATUS}
Backup: ${BACKUP_STATUS}

Next backup will run in 12 hours.
"
send_alert_email "Database Backup Report - ${DATABASE} - $(date '+%Y-%m-%d %H:%M')" "${EMAIL_BODY}"

echo "[SUCCESS] Backup process completed"
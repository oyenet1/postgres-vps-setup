#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TARGET_DIR="/opt/postgres"
SSH_PORT=""

usage() {
    echo "Usage: $0 -d <target_directory> -s <ssh_port>"
    echo "  -d  Target directory for deployment (default: /opt/postgres)"
    echo "  -s  SSH port for firewall (default: none, skip firewall)"
    echo ""
    echo "Examples:"
    echo "  $0 -d /opt/postgres -s 4422   # Custom SSH port"
    echo "  $0 -d /opt/postgres -s 22      # Default SSH port"
    echo "  $0 -d /opt/postgres            # Skip SSH firewall rule"
    exit 1
}

while getopts "d:s:h" opt; do
    case $opt in
        d) TARGET_DIR="$OPTARG" ;;
        s) SSH_PORT="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ERROR] This script must be run as root${NC}"
    exit 1
fi

echo -e "${CYAN}[INFO] Starting PostgreSQL + PgBouncer deployment${NC}"
echo -e "${CYAN}[INFO] Target directory: ${TARGET_DIR}${NC}"
if [[ -n "${SSH_PORT}" ]]; then
    echo -e "${CYAN}[INFO] SSH port: ${SSH_PORT} (firewall will be configured)${NC}"
else
    echo -e "${YELLOW}[INFO] SSH port: not specified (firewall SSH rule will be skipped)${NC}"
fi

if ! command -v docker &> /dev/null; then
    echo -e "${CYAN}[INFO] Installing Docker...${NC}"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm /tmp/get-docker.sh
    echo -e "${GREEN}[SUCCESS] Docker installed${NC}"
else
    echo -e "${YELLOW}[WARNING] Docker is already installed${NC}"
fi

if ! docker compose version &> /dev/null; then
    echo -e "${CYAN}[INFO] Installing Docker Compose V2...${NC}"
    apt-get update
    apt-get install -y docker-compose-plugin
    echo -e "${GREEN}[SUCCESS] Docker Compose V2 installed${NC}"
else
    echo -e "${YELLOW}[WARNING] Docker Compose V2 is already installed${NC}"
fi

systemctl enable docker 2>/dev/null || true
systemctl start docker 2>/dev/null || true

echo -e "${CYAN}[INFO] Configuring UFW firewall...${NC}"
if command -v ufw &> /dev/null; then
    ufw --force enable
    ufw default deny incoming
    if [[ -n "${SSH_PORT}" ]]; then
        ufw allow ${SSH_PORT}/tcp
        echo -e "${CYAN}[INFO] SSH firewall rule added for port ${SSH_PORT}${NC}"
    else
        echo -e "${YELLOW}[WARNING] No SSH port specified, skipping SSH firewall rule${NC}"
    fi
    ufw allow 6543/tcp
    ufw allow 5050/tcp
    ufw allow 9090/tcp
    ufw allow 3030/tcp
    echo -e "${GREEN}[SUCCESS] UFW configured${NC}"
else
    echo -e "${YELLOW}[WARNING] UFW not found, skipping firewall configuration${NC}"
fi

mkdir -p "${TARGET_DIR}"
cd "${TARGET_DIR}"

mkdir -p postgres_data pgbouncer_ssl backups templates config/rclone monitoring grafana/provisioning/datasources grafana/provisioning/dashboards

if [[ -f "${TARGET_DIR}/.env" ]]; then
    echo -e "${CYAN}[INFO] .env exists, loading existing values...${NC}"
    source "${TARGET_DIR}/.env"
    echo -e "${YELLOW}[WARNING] .env already exists. Will prompt for missing values you want to update.${NC}"
else
    if [[ -f "${TARGET_DIR}/.env.example" ]]; then
        echo -e "${CYAN}[INFO] Creating .env from .env.example${NC}"
        cp "${TARGET_DIR}/.env.example" "${TARGET_DIR}/.env"
        if grep -q "changeme_random_32_chars" "${TARGET_DIR}/.env"; then
            NEW_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
            sed -i "s/changeme_random_32_chars/${NEW_PASSWORD}/g" "${TARGET_DIR}/.env"
        fi
        echo -e "${GREEN}[SUCCESS] .env created with random passwords${NC}"
        source "${TARGET_DIR}/.env"
    else
        echo -e "${RED}[ERROR] .env.example not found${NC}"
        exit 1
    fi
fi

echo -e "${CYAN}[INFO] Checking for missing values...${NC}"

if [[ -z "${POSTGRES_DB}" || "${POSTGRES_DB}" == "mydb" ]]; then
    read -p "PostgreSQL database name [${POSTGRES_DB:-mydb}]: " val
    POSTGRES_DB="${val:-${POSTGRES_DB:-mydb}}"
    sed -i "s/POSTGRES_DB=.*/POSTGRES_DB=${POSTGRES_DB}/" "${TARGET_DIR}/.env"
fi

if [[ -z "${POSTGRES_USER}" || "${POSTGRES_USER}" == "pguser" ]]; then
    read -p "PostgreSQL user [${POSTGRES_USER:-pguser}]: " val
    POSTGRES_USER="${val:-${POSTGRES_USER:-pguser}}"
    sed -i "s/POSTGRES_USER=.*/POSTGRES_USER=${POSTGRES_USER}/" "${TARGET_DIR}/.env"
fi

if [[ -z "${POSTGRES_PASSWORD}" || "${POSTGRES_PASSWORD}" == "changeme_random_32_chars" ]]; then
    read -p "PostgreSQL password (32+ chars): " -s val
    echo
    POSTGRES_PASSWORD="${val}"
    sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${POSTGRES_PASSWORD}/" "${TARGET_DIR}/.env"
fi

if [[ -z "${PGADMIN_EMAIL}" || "${PGADMIN_EMAIL}" == "admin@example.com" ]]; then
    read -p "pgAdmin email [${PGADMIN_EMAIL:-admin@example.com}]: " val
    PGADMIN_EMAIL="${val:-${PGADMIN_EMAIL:-admin@example.com}}"
    sed -i "s/PGADMIN_EMAIL=.*/PGADMIN_EMAIL=${PGADMIN_EMAIL}/" "${TARGET_DIR}/.env"
fi

if [[ -z "${PGADMIN_PASSWORD}" || "${PGADMIN_PASSWORD}" == "changeme_random_32_chars" ]]; then
    read -p "pgAdmin password (32+ chars): " -s val
    echo
    PGADMIN_PASSWORD="${val}"
    sed -i "s/PGADMIN_PASSWORD=.*/PGADMIN_PASSWORD=${PGADMIN_PASSWORD}/" "${TARGET_DIR}/.env"
fi

if [[ -z "${GOOGLE_DRIVE_TOKEN}" || "${GOOGLE_DRIVE_TOKEN}" == "your_token_here" ]]; then
    echo -e "${CYAN}[INFO] Google Drive not configured. Setting up rclone...${NC}"
    if ! command -v rclone &> /dev/null; then
        echo -e "${CYAN}[INFO] Installing rclone...${NC}"
        curl -fsSL https://rclone.org/install.sh | sh
    fi
    echo -e "${CYAN}[INFO] Configuring Google Drive (headless)...${NC}"
    echo -e "${CYAN}[INFO] When asked, choose:${NC}"
    echo -e "${CYAN}  - n (New remote)${NC}"
    echo -e "${CYAN}  - name: gdrive${NC}"
    echo -e "${CYAN}  - Storage: drive${NC}"
    echo -e "${CYAN}  - Google Drive: y${NC}"
    echo -e "${CYAN}  - scope: y (Full access)${NC}"
    echo -e "${CYAN}  - ID (leave empty)${NC}"
    echo -e "${CYAN}  - Secret (leave empty)${NC}"
    echo -e "${CYAN}  - Aut config: n (headless)${NC}"
    echo -e "${CYAN}  - Then paste the URL in your browser, authorize, and paste the code back${NC}"
    echo ""
    rclone config
    echo -e "${CYAN}[INFO] Copy the token from ~/.config/rclone/rclone.conf${NC}"
    echo -e "${CYAN}[INFO] The token is the JSON after 'token = ' in [gdrive] section${NC}"
    read -p "Paste the full token JSON here: " GOOGLE_DRIVE_TOKEN
    sed -i "s|GOOGLE_DRIVE_TOKEN=.*|GOOGLE_DRIVE_TOKEN=${GOOGLE_DRIVE_TOKEN}|" "${TARGET_DIR}/.env"
fi

echo ""
echo -e "${CYAN}[INFO] Enable Prometheus + Grafana monitoring? [y/N]: ${NC}"
read -p "> " val
if [[ "${val}" =~ ^[Yy]$ ]]; then
    sed -i "s/MONITORING_ENABLED=.*/MONITORING_ENABLED=true/" "${TARGET_DIR}/.env"
    MONITORING_ENABLED=true

    read -p "Grafana admin password [${GRAFANA_PASSWORD:-admin123}]: " val
    GRAFANA_PASSWORD="${val:-${GRAFANA_PASSWORD:-admin123}}"
    sed -i "s/GRAFANA_PASSWORD=.*/GRAFANA_PASSWORD=${GRAFANA_PASSWORD}/" "${TARGET_DIR}/.env"

    echo ""
    echo -e "${CYAN}[INFO] Setup email alerts? (leave empty to skip)${NC}"
    read -p "Alert email address: " val
    ALERT_EMAIL_TO="${val}"
    sed -i "s/ALERT_EMAIL_TO=.*/ALERT_EMAIL_TO=${ALERT_EMAIL_TO}/" "${TARGET_DIR}/.env"

    if [[ -n "${ALERT_EMAIL_TO}" ]]; then
        read -p "SMTP host [smtp.gmail.com]: " val
        SMTP_HOST="${val:-smtp.gmail.com}"
        read -p "SMTP port [587]: " val
        SMTP_PORT="${val:-587}"
        read -p "SMTP username (your Gmail): " val
        SMTP_USER="${val}"
        echo -e "${CYAN}For Gmail password, use an App Password:${NC}"
        echo -e "${CYAN}https://myaccount.google.com/apppasswords${NC}"
        read -p "SMTP App Password: " -s val
        echo
        SMTP_PASSWORD="${val}"
        read -p "From email address [${SMTP_USER}]: " val
        SMTP_FROM="${val:-${SMTP_USER}}"

        sed -i "s/SMTP_HOST=.*/SMTP_HOST=${SMTP_HOST}/" "${TARGET_DIR}/.env"
        sed -i "s/SMTP_PORT=.*/SMTP_PORT=${SMTP_PORT}/" "${TARGET_DIR}/.env"
        sed -i "s/SMTP_USER=.*/SMTP_USER=${SMTP_USER}/" "${TARGET_DIR}/.env"
        sed -i "s/SMTP_PASSWORD=.*/SMTP_PASSWORD=${SMTP_PASSWORD}/" "${TARGET_DIR}/.env"
        sed -i "s/SMTP_FROM=.*/SMTP_FROM=${SMTP_FROM}/" "${TARGET_DIR}/.env"
    fi
else
    sed -i "s/MONITORING_ENABLED=.*/MONITORING_ENABLED=false/" "${TARGET_DIR}/.env"
fi

echo ""
echo -e "${CYAN}[INFO] Setup Cloudflare Hyperdrive? [y/N]: ${NC}"
read -p "> " val
if [[ "${val}" =~ ^[Yy]$ ]]; then
    sed -i "s/HYPERDRIVE_ENABLED=.*/HYPERDRIVE_ENABLED=true/" "${TARGET_DIR}/.env"

    if ! command -v node &> /dev/null || [[ "$(node -v 2>/dev/null | cut -d'v' -f2 | cut -d'.' -f1)" -lt 22 ]]; then
        echo -e "${CYAN}[INFO] Node.js 22 not found. Installing via NodeSource...${NC}"
        curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
        apt-get install -y nodejs
        echo -e "${GREEN}[SUCCESS] Node.js $(node -v) installed${NC}"
    else
        echo -e "${YELLOW}[WARNING] Node.js $(node -v) is already installed${NC}"
    fi

    if ! command -v wrangler &> /dev/null; then
        echo -e "${CYAN}[INFO] Installing Wrangler...${NC}"
        npm install -g wrangler@latest
        echo -e "${GREEN}[SUCCESS] Wrangler installed${NC}"
    else
        echo -e "${YELLOW}[WARNING] Wrangler is already installed${NC}"
    fi

    echo -e "${YELLOW}[WARNING] This will open your browser for Cloudflare authentication.${NC}"
    echo -e "${YELLOW}If no browser opens, manually visit: https://dash.cloudflare.com/${NC}"
    echo -e "${CYAN}[INFO] Running wrangler login...${NC}"
    wrangler login

    echo -e "${CYAN}[INFO] Getting public IP...${NC}"
    PUBLIC_IP=$(curl -s ifconfig.me)
    if [[ -z "${PUBLIC_IP}" ]]; then
        echo -e "${RED}[ERROR] Could not determine public IP${NC}"
        exit 1
    fi
    echo -e "${CYAN}[INFO] Public IP: ${PUBLIC_IP}${NC}"

    HYPERDRIVE_NAME="${HYPERDRIVE_NAME:-postgres-hd}"
    CONNECTION_STRING="postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${PUBLIC_IP}:6543/${POSTGRES_DB}?sslmode=require"

    echo -e "${CYAN}[INFO] Creating Hyperdrive binding: ${HYPERDRIVE_NAME}${NC}"
    HYPERDRIVE_OUTPUT=$(wrangler hyperdrive create "${HYPERDRIVE_NAME}" --connection-string="${CONNECTION_STRING}" 2>&1)

    if echo "${HYPERDRIVE_OUTPUT}" | grep -q '"id"'; then
        HYPERDRIVE_ID=$(echo "${HYPERDRIVE_OUTPUT}" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
        sed -i "s/HYPERDRIVE_ID=.*/HYPERDRIVE_ID=${HYPERDRIVE_ID}/" "${TARGET_DIR}/.env"
        sed -i "s|HYPERDRIVE_CONNECTION_STRING=.*|HYPERDRIVE_CONNECTION_STRING=${CONNECTION_STRING}|" "${TARGET_DIR}/.env"
        echo -e "${GREEN}[SUCCESS] Hyperdrive created!${NC}"
        echo -e "${CYAN}Hyperdrive ID: ${HYPERDRIVE_ID}${NC}"

        echo -e "${CYAN}[INFO] Updating PgBouncer to listen on all interfaces...${NC}"
        sed -i 's/LISTEN_ADDR: "127.0.0.1"/LISTEN_ADDR: "0.0.0.0"/' "${TARGET_DIR}/docker-compose.yml"
        sed -i 's/"127.0.0.1:6543:5432"/"6543:5432"/' "${TARGET_DIR}/docker-compose.yml"
        echo -e "${YELLOW}[WARNING] PgBouncer now listens on 0.0.0.0:6543${NC}"

        echo -e "${CYAN}[INFO] Opening firewall for Cloudflare IPs (104.16.0.0/12)...${NC}"
        ufw allow from 104.16.0.0/12 to any port 6543 proto tcp 2>/dev/null || true

        echo ""
        echo -e "${GREEN}[SUCCESS] Hyperdrive created!${NC}"
        echo -e "${CYAN}Hyperdrive ID: ${HYPERDRIVE_ID}${NC}"
        echo ""
        echo -e "${CYAN}Add this to your wrangler.jsonc:${NC}"
        echo -e '{
  "hyperdrive": [{
    "binding": "HYPERDRIVE",
    "id": "'"${HYPERDRIVE_ID}"'"
  }]
}'
    else
        echo -e "${RED}[ERROR] Failed to create Hyperdrive${NC}"
        echo "${HYPERDRIVE_OUTPUT}"
        exit 1
    fi
else
    sed -i "s/HYPERDRIVE_ENABLED=.*/HYPERDRIVE_ENABLED=false/" "${TARGET_DIR}/.env"
fi

source "${TARGET_DIR}/.env"

if [[ ! -f "${TARGET_DIR}/pgbouncer_ssl/server.crt" ]]; then
    echo -e "${CYAN}[INFO] Generating SSL certificates...${NC}"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${TARGET_DIR}/pgbouncer_ssl/server.key" \
        -out "${TARGET_DIR}/pgbouncer_ssl/server.crt" \
        -subj "/C=US/ST=State/L=City/O=Organization/CN=pgbouncer" 2>/dev/null
    chmod 600 "${TARGET_DIR}/pgbouncer_ssl/server.key"
    chmod 644 "${TARGET_DIR}/pgbouncer_ssl/server.crt"
    echo -e "${GREEN}[SUCCESS] SSL certificates generated${NC}"
else
    echo -e "${YELLOW}[WARNING] SSL certificates already exist${NC}"
fi

HASHED_PASSWORD=$(echo -n "${POSTGRES_PASSWORD}" | md5sum | cut -d' ' -f1)
cat > "${TARGET_DIR}/userlist.txt" << EOF
"${POSTGRES_USER}" "${HASHED_PASSWORD}"
EOF

if [[ ! -f "${TARGET_DIR}/config/rclone/rclone.conf" ]]; then
    echo -e "${CYAN}[INFO] Creating rclone.conf from template...${NC}"
    cat > "${TARGET_DIR}/config/rclone/rclone.conf" << RCLONE_EOF
[gdrive]
type = drive
scope = drive
token = ${GOOGLE_DRIVE_TOKEN}
team_drive = ${GOOGLE_DRIVE_TEAM_DRIVE_ID}
RCLONE_EOF
    echo -e "${GREEN}[SUCCESS] rclone.conf created${NC}"
else
    echo -e "${YELLOW}[WARNING] rclone.conf already exists, skipping${NC}"
fi

if [[ ! -f "${TARGET_DIR}/monitoring/prometheus.yml" ]]; then
    echo -e "${CYAN}[INFO] Creating monitoring configs...${NC}"
    cat > "${TARGET_DIR}/monitoring/prometheus.yml" << 'EOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

alerting:
  alertmanagers:
    - static_configs:
        - targets:
            - alertmanager:9093

rule_files:
  - /etc/prometheus/alert.rules.yml

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'postgres'
    static_configs:
      - targets: ['postgres:5432']

  - job_name: 'pgbouncer'
    static_configs:
      - targets: ['pgbouncer:5432']
EOF

    cat > "${TARGET_DIR}/monitoring/alert.rules.yml" << 'EOF'
groups:
  - name: postgres_alerts
    interval: 30s
    rules:
      - alert: PostgresDown
        expr: up{job="postgres"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "PostgreSQL is down"

      - alert: PostgresHighConnections
        expr: pg_stat_activity_count > 80
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "PostgreSQL high connection count"

  - name: pgbouncer_alerts
    interval: 30s
    rules:
      - alert: PgBouncerDown
        expr: up{job="pgbouncer"} == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "PgBouncer is down"

      - alert: PgBouncerHighConnections
        expr: pgbouncer_cl_connections > 800
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "PgBouncer high client connections"
EOF

    cat > "${TARGET_DIR}/monitoring/alertmanager.yml" << 'EOF'
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'severity']
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: 'email'

receivers:
  - name: 'email'
    email_configs:
      - to: '${ALERT_EMAIL_TO}'
        from: '${SMTP_FROM}'
        smarthost: '${SMTP_HOST}:${SMTP_PORT}'
        auth_username: '${SMTP_USER}'
        auth_password: '${SMTP_PASSWORD}'
        send_resolved: true
EOF

    cat > "${TARGET_DIR}/grafana/provisioning/datasources/datasources.yml" << 'EOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
EOF

    cat > "${TARGET_DIR}/grafana/provisioning/dashboards/dashboards.yml" << 'EOF'
apiVersion: 1
providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    options:
      path: /etc/grafana/provisioning/dashboards
EOF

    echo -e "${GREEN}[SUCCESS] Monitoring configs created${NC}"
else
    echo -e "${YELLOW}[WARNING] Monitoring configs already exist, skipping${NC}"
fi

if [[ ! -f "${TARGET_DIR}/templates/backup.sh" ]]; then
    echo -e "${CYAN}[INFO] Creating backup script...${NC}"
    cat > "${TARGET_DIR}/templates/backup.sh" << 'EOF'
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
SMTP_HOST="${SMTP_HOST:-smtp.gmail.com}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_FROM="${SMTP_FROM:-}"
MONITORING_ENABLED="${MONITORING_ENABLED:-false}"

send_alert_email() {
    local subject="$1"
    local body="$2"

    if [[ -z "${ALERT_EMAIL_TO}" || -z "${SMTP_HOST}" || -z "${SMTP_USER}" ]]; then
        return
    fi

    apt-get update -qq && apt-get install -y -qq msmtp > /dev/null 2>&1

    cat > /tmp/msmtp_config << CONFIGEOF
defaults
auth on
tls on
tls_certcheck off
host ${SMTP_HOST}
port ${SMTP_PORT}
from ${SMTP_FROM}
user ${SMTP_USER}
password ${SMTP_PASSWORD}
CONFIGEOF

    echo -e "From: ${SMTP_FROM}\nTo: ${ALERT_EMAIL_TO}\nSubject: ${subject}\n\n${body}" | msmtp -C /tmp/msmtp_config -t "${ALERT_EMAIL_TO}" 2>/dev/null || true
}

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="backup_${DATABASE}_${TIMESTAMP}.sql.gz"
BACKUP_SIZE=""

echo "[INFO] Starting backup of database: ${DATABASE}"

START_TIME=$(date +%s)

if ! docker exec postgres pg_dump -U "${DB_USER}" -d "${DATABASE}" 2>/dev/null | gzip > "${BACKUP_DIR}/${BACKUP_FILE}"; then
    ERROR_MSG="[ERROR] Backup failed - pg_dump returned error"
    echo "${ERROR_MSG}"
    send_alert_email "[CRITICAL] Database Backup Failed - ${DATABASE}" "Backup failed for database ${DATABASE} at $(date).\n\nError: pg_dump command failed."
    exit 1
fi

if [[ ! -f "${BACKUP_DIR}/${BACKUP_FILE}" ]]; then
    echo "[ERROR] Backup file was not created"
    exit 1
fi

BACKUP_SIZE=$(du -h "${BACKUP_DIR}/${BACKUP_FILE}" | cut -f1)
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "[INFO] Backup completed: ${BACKUP_FILE} (${BACKUP_SIZE})"

UPLOAD_STATUS="SUCCESS"
if command -v rclone &> /dev/null; then
    if ! rclone copy "${BACKUP_DIR}/${BACKUP_FILE}" "${GOOGLE_DRIVE_REMOTE}:${GOOGLE_DRIVE_FOLDER}/" --progress 2>&1; then
        UPLOAD_STATUS="FAILED"
        echo "[WARNING] Upload to Google Drive failed"
    else
        echo "[SUCCESS] Backup uploaded to Google Drive"

        rclone lsf "${GOOGLE_DRIVE_REMOTE}:${GOOGLE_DRIVE_FOLDER}/" --sort-by=modtime,desc 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | while read file; do
            rclone delete "${GOOGLE_DRIVE_REMOTE}:${GOOGLE_DRIVE_FOLDER}/${file}" 2>/dev/null || true
        done
        echo "[INFO] Old backups cleaned from Google Drive"
    fi
else
    UPLOAD_STATUS="SKIPPED"
fi

find "${BACKUP_DIR}" -name "backup_*.sql.gz" -mtime +30 -delete 2>/dev/null || true
cd "${BACKUP_DIR}" && ls -t backup_*.sql.gz 2>/dev/null | tail -n +$((MAX_BACKUPS + 1)) | xargs -r rm -f

BACKUP_COUNT=$(ls -1 "${BACKUP_DIR}"/backup_*.sql.gz 2>/dev/null | wc -l)
POSTGRES_STATUS=$(docker exec postgres pg_isready -U "${DB_USER}" 2>/dev/null && echo "UP" || echo "DOWN")
PGBOUNCER_STATUS=$(docker exec pgbouncer pgbouncer --version 2>/dev/null && echo "UP" || echo "DOWN")

EMAIL_BODY="Database Backup Report - ${DATABASE}
==========================================
Date: $(date '+%Y-%m-%d %H:%M:%S')
Backup File: ${BACKUP_FILE}
Size: ${BACKUP_SIZE}
Duration: ${DURATION} seconds
Upload Status: ${UPLOAD_STATUS}
Local Backups Kept: ${BACKUP_COUNT}

Service Status:
----------------
PostgreSQL: ${POSTGRES_STATUS}
PgBouncer: ${PGBOUNCER_STATUS}
"
send_alert_email "Database Backup Report - ${DATABASE} - $(date '+%Y-%m-%d %H:%M')" "${EMAIL_BODY}"

echo "[SUCCESS] Backup process completed"
EOF
    chmod +x "${TARGET_DIR}/templates/backup.sh"
    echo -e "${GREEN}[SUCCESS] Backup script created${NC}"
else
    echo -e "${YELLOW}[WARNING] Backup script already exists, skipping${NC}"
fi

if [[ "${MONITORING_ENABLED}" == "true" ]]; then
    echo -e "${CYAN}[INFO] Starting containers with monitoring...${NC}"
    docker compose --profile monitoring up -d
    echo -e "${GREEN}[SUCCESS] Containers started with monitoring${NC}"
else
    echo -e "${CYAN}[INFO] Starting containers without monitoring...${NC}"
    docker compose up -d
    echo -e "${GREEN}[SUCCESS] Containers started${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${CYAN}Services:${NC}"
echo -e "  - PostgreSQL:  localhost:5432 (internal)"
echo -e "  - PgBouncer:  localhost:6543"
echo -e "  - pgAdmin:    localhost:5050"
if [[ "${MONITORING_ENABLED}" == "true" ]]; then
echo -e "  - Prometheus: localhost:9090"
echo -e "  - Grafana:    localhost:3030"
echo -e "  - Alertmanager: localhost:9093"
echo -e "${YELLOW}[INFO] Monitoring stack is enabled${NC}"
else
echo -e "${YELLOW}[INFO] Monitoring is disabled (enable with MONITORING_ENABLED=true)${NC}"
fi
echo ""
echo -e "${CYAN}Next Steps:${NC}"
echo -e "  1. Review ${TARGET_DIR}/.env with your settings"
echo -e "  2. To enable monitoring later: docker compose --profile monitoring up -d"
echo -e "  3. Access Grafana at http://your-server:3030"
echo ""
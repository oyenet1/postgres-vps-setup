#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TARGET_DIR="/opt/postgres"
SSH_PORT=""
PGBOUNCER_PORT=6543

prompt_env() {
    echo -e "${CYAN}[INFO] Some environment variables are missing or are placeholders. Please provide values:${NC}"

    if [[ -z "${POSTGRES_DB}" || "${POSTGRES_DB}" == "mydb" ]]; then
        read -p "PostgreSQL database name [mydb]: " val
        POSTGRES_DB="${val:-mydb}"
    fi

    if [[ -z "${POSTGRES_USER}" || "${POSTGRES_USER}" == "pguser" ]]; then
        read -p "PostgreSQL user [pguser]: " val
        POSTGRES_USER="${val:-pguser}"
    fi

    if [[ -z "${POSTGRES_PASSWORD}" || "${POSTGRES_PASSWORD}" == "changeme_random_32_chars" ]]; then
        read -p "PostgreSQL password (32+ chars): " -s val
        echo
        POSTGRES_PASSWORD="${val}"
    fi

    if [[ -z "${PGADMIN_EMAIL}" || "${PGADMIN_EMAIL}" == "admin@example.com" ]]; then
        read -p "pgAdmin email [admin@example.com]: " val
        PGADMIN_EMAIL="${val:-admin@example.com}"
    fi

    if [[ -z "${PGADMIN_PASSWORD}" || "${PGADMIN_PASSWORD}" == "changeme_random_32_chars" ]]; then
        read -p "pgAdmin password (32+ chars): " -s val
        echo
        PGADMIN_PASSWORD="${val}"
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
    fi

    if [[ -n "${GOOGLE_DRIVE_TEAM_DRIVE_ID}" ]]; then
        sed -i "s|GOOGLE_DRIVE_TEAM_DRIVE_ID=.*|GOOGLE_DRIVE_TEAM_DRIVE_ID=${GOOGLE_DRIVE_TEAM_DRIVE_ID}|" "${TARGET_DIR}/.env"
    fi

    sed -i "s/POSTGRES_DB=.*/POSTGRES_DB=${POSTGRES_DB}/" "${TARGET_DIR}/.env"
    sed -i "s/POSTGRES_USER=.*/POSTGRES_USER=${POSTGRES_USER}/" "${TARGET_DIR}/.env"
    sed -i "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${POSTGRES_PASSWORD}/" "${TARGET_DIR}/.env"
    sed -i "s/PGADMIN_EMAIL=.*/PGADMIN_EMAIL=${PGADMIN_EMAIL}/" "${TARGET_DIR}/.env"
    sed -i "s/PGADMIN_PASSWORD=.*/PGADMIN_PASSWORD=${PGADMIN_PASSWORD}/" "${TARGET_DIR}/.env"
    sed -i "s|GOOGLE_DRIVE_TOKEN=.*|GOOGLE_DRIVE_TOKEN=${GOOGLE_DRIVE_TOKEN}|" "${TARGET_DIR}/.env"

    echo -e "${GREEN}[SUCCESS] Environment variables updated${NC}"
}

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
    ufw allow ${PGBOUNCER_PORT}/tcp
    echo -e "${GREEN}[SUCCESS] UFW configured${NC}"
else
    echo -e "${YELLOW}[WARNING] UFW not found, skipping firewall configuration${NC}"
fi

mkdir -p "${TARGET_DIR}"
cd "${TARGET_DIR}"

mkdir -p postgres_data pgbouncer_ssl backups templates config/rclone

if [[ ! -f "${TARGET_DIR}/.env" ]]; then
    if [[ -f "${TARGET_DIR}/.env.example" ]]; then
        echo -e "${CYAN}[INFO] Creating .env from .env.example${NC}"
        cp "${TARGET_DIR}/.env.example" "${TARGET_DIR}/.env"
        if grep -q "changeme_random_32_chars" "${TARGET_DIR}/.env"; then
            NEW_PASSWORD=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
            sed -i "s/changeme_random_32_chars/${NEW_PASSWORD}/g" "${TARGET_DIR}/.env"
        fi
        echo -e "${GREEN}[SUCCESS] .env created with random passwords${NC}"
    else
        echo -e "${RED}[ERROR] .env.example not found${NC}"
        exit 1
    fi
else
    echo -e "${YELLOW}[WARNING] .env already exists, skipping${NC}"
fi

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

if [[ ! -f "${TARGET_DIR}/docker-compose.yml" ]]; then
    echo -e "${CYAN}[INFO] Creating docker-compose.yml...${NC}"
    cat > "${TARGET_DIR}/docker-compose.yml" << 'EOF'
services:
  postgres:
    image: postgres:17
    container_name: postgres
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    networks:
      - dbstack
    restart: unless-stopped

  pgbouncer:
    image: pgbouncer/pgbouncer:latest
    container_name: pgbouncer
    environment:
      DATABASE_URL: "postgres://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}"
    ports:
      - "6543:6543"
    volumes:
      - ./pgbouncer_ssl:/etc/pgbouncer/ssl
      - ./pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini
      - ./userlist.txt:/etc/pgbouncer/userlist.txt
    networks:
      - dbstack
    depends_on:
      - postgres
    restart: unless-stopped

  pgadmin:
    image: dpage/pgadmin4:latest
    container_name: pgadmin
    environment:
      PGADMIN_EMAIL: ${PGADMIN_EMAIL}
      PGADMIN_PASSWORD: ${PGADMIN_PASSWORD}
    ports:
      - "5050:80"
    volumes:
      - pgadmin_data:/var/lib/pgadmin
    networks:
      - dbstack
    restart: unless-stopped

  backup:
    image: ubuntu:latest
    container_name: backup
    volumes:
      - ./backups:/backups
      - ./templates/backup.sh:/backup.sh
      - ./templates/backup.cron:/backup.cron
      - /var/run/docker.sock:/var/run/docker.sock
      - ./config/rclone:/config/rclone:ro
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      GOOGLE_DRIVE_REMOTE_NAME: ${GOOGLE_DRIVE_REMOTE_NAME}
      GOOGLE_DRIVE_FOLDER: ${GOOGLE_DRIVE_FOLDER}
    command: >
      bash -c "apt-get update && apt-get install -y cron rclone && crontab /backup.cron && cron && tail -f /dev/null"
    networks:
      - dbstack
    depends_on:
      - postgres
    restart: unless-stopped

networks:
  dbstack:
    driver: bridge

volumes:
  pgadmin_data:
EOF
    echo -e "${GREEN}[SUCCESS] docker-compose.yml created${NC}"
else
    echo -e "${YELLOW}[WARNING] docker-compose.yml already exists, skipping${NC}"
fi

if [[ ! -f "${TARGET_DIR}/pgbouncer.ini" ]]; then
    echo -e "${CYAN}[INFO] Creating PgBouncer config...${NC}"
    cat > "${TARGET_DIR}/pgbouncer.ini" << 'EOF'
[databases]
postgres = host=postgres port=5432 dbname=postgres

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6543
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 1000
default_pool_size = 20
server_lifetime = 3600
server_idle_timeout = 600
server_reset_query = DISCARD ALL

log_connections = 1
log_disconnections = 1
log_pooler_errors = 1
EOF
    echo -e "${GREEN}[SUCCESS] PgBouncer config created${NC}"
else
    echo -e "${YELLOW}[WARNING] PgBouncer config already exists, skipping${NC}"
fi

source "${TARGET_DIR}/.env" 2>/dev/null || true

if [[ "${POSTGRES_PASSWORD}" == "changeme_random_32_chars" || "${PGADMIN_PASSWORD}" == "changeme_random_32_chars" || "${GOOGLE_DRIVE_TOKEN}" == "your_token_here" ]]; then
    prompt_env
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
EOF
    chmod +x "${TARGET_DIR}/templates/backup.sh"
    echo -e "${GREEN}[SUCCESS] Backup script created${NC}"
else
    echo -e "${YELLOW}[WARNING] Backup script already exists, skipping${NC}"
fi

if ! docker ps --format '{{.Names}}' | grep -q postgres; then
    echo -e "${CYAN}[INFO] Starting containers...${NC}"
    docker compose up -d
    echo -e "${GREEN}[SUCCESS] Containers started${NC}"
else
    echo -e "${YELLOW}[WARNING] Containers are already running${NC}"
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Deployment Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${CYAN}Services:${NC}"
echo -e "  - PostgreSQL:  localhost:5432 (internal only)"
echo -e "  - PgBouncer:   localhost:${PGBOUNCER_PORT}"
echo -e "  - pgAdmin:     localhost:5050"
echo ""
echo -e "${CYAN}SSH Port:${NC}"
if [[ -n "${SSH_PORT}" ]]; then
    echo -e "  - Firewall configured for SSH on port ${SSH_PORT}"
else
    echo -e "  - No SSH firewall rule added (use: sudo ufw allow <port>/tcp)"
fi
echo ""
echo -e "${CYAN}Next Steps:${NC}"
echo -e "  1. Ensure rclone config exists at: ${TARGET_DIR}/config/rclone/rclone.conf"
echo -e "  2. Configure Google Drive credentials if not already done"
echo -e "  3. Update firewall rules if not using UFW"
echo -e "  4. Review and update ${TARGET_DIR}/.env with secure passwords"
echo ""
echo -e "${CYAN}Useful Commands:${NC}"
echo -e "  docker compose logs -f postgres"
echo -e "  docker compose logs -f pgbouncer"
echo -e "  docker compose ps"
echo ""
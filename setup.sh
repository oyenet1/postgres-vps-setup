#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TARGET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_PORT=""
START_STACK="true"

usage() {
  cat <<EOF
Usage: sudo ./setup.sh [options]

Options:
  -d DIR       deployment directory, default: current directory
  -s PORT      SSH port to allow if UFW is available
  --no-start   render files only, do not start containers
  -h           show this help
EOF
}

log() {
  printf '%b\n' "${CYAN}[INFO]${NC} $*"
}

warn() {
  printf '%b\n' "${YELLOW}[WARN]${NC} $*"
}

ok() {
  printf '%b\n' "${GREEN}[OK]${NC} $*"
}

fail() {
  printf '%b\n' "${RED}[ERROR]${NC} $*" >&2
  exit 1
}

random_secret() {
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 40
}

quote_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

set_env() {
  local key="$1"
  local value="$2"
  local escaped
  escaped="$(quote_sed_replacement "$value")"

  if grep -q "^${key}=" .env; then
    sed -i "s/^${key}=.*/${key}=${escaped}/" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

env_value() {
  local key="$1"
  grep -E "^${key}=" .env | tail -1 | cut -d= -f2-
}

env_default() {
  local key="$1"
  local fallback="$2"
  local value
  value="$(env_value "$key" || true)"
  printf '%s' "${value:-$fallback}"
}

set_default_env() {
  local key="$1"
  local value="$2"

  if ! grep -q "^${key}=" .env; then
    set_env "$key" "$value"
  fi
}

ensure_env_value() {
  local key="$1"
  local current
  local generated
  current="$(env_value "$key" || true)"

  case "$current" in
    ""|change_me_*|password|password1234|admin|admin123|your_token_here)
      generated="$(random_secret)"
      set_env "$key" "$generated"
      ;;
  esac
}

merge_env_defaults() {
  local line
  local key

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    [[ "$line" != *=* ]] && continue

    key="${line%%=*}"
    if ! grep -q "^${key}=" .env; then
      printf '%s\n' "$line" >> .env
    fi
  done < .env.example
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d)
        TARGET_DIR="$2"
        shift 2
        ;;
      -s)
        SSH_PORT="$2"
        shift 2
        ;;

      --no-start)
        START_STACK="false"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown option: $1"
        ;;
    esac
  done
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker and Docker Compose are already installed"
    fix_containerd_storage
    return
  fi

  log "Installing Docker and Docker Compose plugin"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y ca-certificates curl gnupg openssl
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    apt-get install -y docker-compose-plugin
  else
    fail "Automatic Docker install only supports apt-based systems. Install Docker manually and rerun."
  fi

  systemctl enable docker >/dev/null 2>&1 || true
  systemctl start docker >/dev/null 2>&1 || true

  fix_containerd_storage
}

fix_containerd_storage() {
  local snap_dir="/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
  local containerd_dir="/var/lib/containerd"

  if [[ -d "$snap_dir" ]]; then
    return
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "systemctl not available; skipping containerd storage fix"
    return
  fi

  log "Containerd overlayfs snapshotter directory missing, recreating"

  mkdir -p "$snap_dir"
  mkdir -p "$containerd_dir/io.containerd.snapshotter.v1.native/snapshots"
  chown -R root:root "$containerd_dir" 2>/dev/null || true

  systemctl restart containerd 2>/dev/null || warn "could not restart containerd"
  systemctl restart docker 2>/dev/null || warn "could not restart docker"

  sleep 2

  if [[ -d "$snap_dir" ]]; then
    ok "Containerd storage repaired"
  else
    warn "Containerd storage dir still missing; docker build may fail"
  fi
}

configure_firewall() {
  if ! command -v ufw >/dev/null 2>&1; then
    warn "UFW not found; skipping firewall configuration"
    return
  fi

  log "Configuring UFW"
  ufw default deny incoming

  if [[ -n "$SSH_PORT" ]]; then
    ufw allow "${SSH_PORT}/tcp"
  else
    warn "No SSH port supplied. Existing SSH firewall rules were not changed."
  fi

  ufw allow "$(env_value PGBOUNCER_PORT)/tcp"
  ufw --force enable
  ok "Firewall allows PgBouncer on port $(env_value PGBOUNCER_PORT)"
}

prepare_env() {
  cd "$TARGET_DIR"

  if [[ ! -f .env ]]; then
    cp .env.example .env
    ok "Created .env from .env.example"
  else
    ok "Using existing .env"
  fi

  merge_env_defaults

  set_default_env POSTGRES_DB postgres
  set_default_env POSTGRES_USER postgres
  set_default_env POSTGRES_PORT 5432
  set_default_env POSTGRES_BIND_ADDR 127.0.0.1
  set_default_env PGBOUNCER_PORT 6543
  set_default_env PGBOUNCER_BIND_ADDR 0.0.0.0
  set_default_env PGBOUNCER_AUTH_USER pgbouncer_auth
  set_default_env PGBOUNCER_DEFAULT_POOL_SIZE 50
  set_default_env PGBOUNCER_MIN_POOL_SIZE 5
  set_default_env PGBOUNCER_RESERVE_POOL_SIZE 10
  set_default_env PGBOUNCER_MAX_CLIENT_CONN 2000
  set_default_env PGADMIN_EMAIL admin@example.com
  set_default_env PGADMIN_PORT 5050
  set_default_env REDIS_PORT 6379
  set_default_env REDIS_SENTINEL_MASTER_NAME dbmaster
  set_default_env BACKUP_INTERVAL_SECONDS 43200
  set_default_env BACKUP_RETENTION 2
  set_default_env R2_BACKUP_ENABLED false
  set_default_env R2_PREFIX infra/
  set_default_env R2_MAX_BACKUPS_PER_DB 2
  set_default_env GRAFANA_PORT 3030
  set_default_env ALERT_FROM alerts@example.com
  set_default_env SMTP_SMARTHOST smtp.gmail.com:587

  ensure_env_value POSTGRES_PASSWORD
  ensure_env_value PGBOUNCER_AUTH_PASSWORD
  ensure_env_value PGADMIN_PASSWORD
  ensure_env_value REDIS_PASSWORD
  ensure_env_value GRAFANA_PASSWORD
}

render_pgbouncer_config() {
  local pg_user
  local auth_user
  local auth_password
  local pool_size
  local min_pool_size
  local reserve_pool_size
  local max_client_conn
  local tls_enabled

  pg_user="$(env_default POSTGRES_USER postgres)"
  auth_user="$(env_default PGBOUNCER_AUTH_USER pgbouncer_auth)"
  auth_password="$(env_value PGBOUNCER_AUTH_PASSWORD)"
  pool_size="$(env_default PGBOUNCER_DEFAULT_POOL_SIZE 50)"
  min_pool_size="$(env_default PGBOUNCER_MIN_POOL_SIZE 5)"
  reserve_pool_size="$(env_default PGBOUNCER_RESERVE_POOL_SIZE 10)"
  max_client_conn="$(env_default PGBOUNCER_MAX_CLIENT_CONN 2000)"
  tls_enabled="$(env_default PGBOUNCER_TLS_ENABLED false)"

  mkdir -p pgbouncer

  if [[ ! -f pgbouncer/pgbouncer-cert.pem || ! -f pgbouncer/pgbouncer-key.pem ]]; then
    log "Generating self-signed cert for PgBouncer"
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout pgbouncer/pgbouncer-key.pem \
      -out pgbouncer/pgbouncer-cert.pem \
      -subj "/CN=pgbouncer/O=Infra" \
      -addext "subjectAltName=DNS:pgbouncer,DNS:localhost,IP:127.0.0.1"
    chmod 600 pgbouncer/pgbouncer-key.pem
  fi

  cat > pgbouncer/pgbouncer.ini <<EOF
[databases]
* = host=postgres port=5432 auth_user=${auth_user}

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
auth_type = scram-sha-256
auth_file = /etc/pgbouncer/userlist.txt
auth_query = SELECT username, password FROM pgbouncer.get_auth(\$1)
auth_dbname = postgres
admin_users = ${pg_user}
stats_users = ${pg_user}, ${auth_user}
pool_mode = transaction
max_client_conn = ${max_client_conn}
default_pool_size = ${pool_size}
min_pool_size = ${min_pool_size}
reserve_pool_size = ${reserve_pool_size}
reserve_pool_timeout = 5
server_idle_timeout = 600
server_lifetime = 3600
query_timeout = 300
ignore_startup_parameters = extra_float_digits,options
server_reset_query = DISCARD ALL
log_connections = 1
log_disconnections = 1
$( [[ "$tls_enabled" == "true" ]] && cat <<TLS
client_tls_sslmode = prefer
client_tls_key_file = /etc/pgbouncer/server-key.pem
client_tls_cert_file = /etc/pgbouncer/server-cert.pem
TLS
)
EOF

  cat > pgbouncer/userlist.generated.txt <<EOF
"${pg_user}" "$(env_value POSTGRES_PASSWORD)"
"${auth_user}" "${auth_password}"
EOF

  chmod 600 pgbouncer/userlist.generated.txt
  ok "Rendered PgBouncer config with wildcard database routing${tls_enabled:+ and TLS}"
}

render_redis_config() {
  local redis_password
  redis_password="$(env_value REDIS_PASSWORD)"
  mkdir -p redis

  cat > redis/haproxy.generated.cfg <<EOF
global
    log stdout format raw local0
    maxconn 50000

defaults
    mode tcp
    log global
    timeout connect 5s
    timeout client 60s
    timeout server 60s
    option tcplog

resolvers docker
    nameserver dns 127.0.0.11:53
    resolve_retries 3
    timeout resolve 1s
    timeout retry 1s
    hold valid 2s

frontend redis_front
    bind *:6379
    default_backend redis_master_backend

backend redis_master_backend
    option tcp-check
    tcp-check send "AUTH ${redis_password}\r\n"
    tcp-check expect string +OK
    tcp-check send "PING\r\n"
    tcp-check expect string +PONG
    tcp-check send "INFO replication\r\n"
    tcp-check expect string role:master
    tcp-check send "QUIT\r\n"
    tcp-check expect string +OK
    server redis-master redis-master:6379 check inter 1000 rise 2 fall 2 resolvers docker resolve-prefer ipv4
    server redis-replica redis-replica:6379 check inter 1000 rise 2 fall 2 resolvers docker resolve-prefer ipv4
EOF

  chmod +x redis/sentinel-entrypoint.sh
  ok "Rendered Redis proxy config"
}

render_pgadmin_config() {
  local pg_user
  pg_user="$(env_default POSTGRES_USER postgres)"
  mkdir -p pgadmin

  cat > pgadmin/servers.json <<EOF
{
  "Servers": {
    "1": {
      "Name": "Postgres Direct",
      "Group": "Servers",
      "Host": "postgres",
      "Port": 5432,
      "MaintenanceDB": "postgres",
      "Username": "${pg_user}",
      "SSLMode": "prefer"
    },
    "2": {
      "Name": "PgBouncer",
      "Group": "Servers",
      "Host": "pgbouncer",
      "Port": 6432,
      "MaintenanceDB": "postgres",
      "Username": "${pg_user}",
      "SSLMode": "prefer"
    }
  }
}
EOF

  ok "Rendered pgAdmin server list"
}

render_rclone_config() {
  local enabled
  local account_id
  local access_key
  local secret_key
  local endpoint

  enabled="$(env_default R2_BACKUP_ENABLED false)"
  account_id="$(env_value R2_ACCOUNT_ID || true)"
  access_key="$(env_value R2_ACCESS_KEY_ID || true)"
  secret_key="$(env_value R2_SECRET_ACCESS_KEY || true)"
  endpoint="$(env_value R2_ENDPOINT || true)"

  mkdir -p config/rclone

  if [[ "$enabled" == "true" ]]; then
    [[ -n "$access_key" ]] || fail "R2_BACKUP_ENABLED=true but R2_ACCESS_KEY_ID is empty"
    [[ -n "$secret_key" ]] || fail "R2_BACKUP_ENABLED=true but R2_SECRET_ACCESS_KEY is empty"
    [[ -n "$(env_value R2_BUCKET || true)" ]] || fail "R2_BACKUP_ENABLED=true but R2_BUCKET is empty"

    if [[ -z "$endpoint" ]]; then
      [[ -n "$account_id" ]] || fail "Set R2_ACCOUNT_ID or R2_ENDPOINT when R2_BACKUP_ENABLED=true"
      endpoint="https://${account_id}.r2.cloudflarestorage.com"
    fi

    cat > config/rclone/rclone.generated.conf <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${access_key}
secret_access_key = ${secret_key}
endpoint = ${endpoint}
acl = private
no_check_bucket = false
EOF
    chmod 600 config/rclone/rclone.generated.conf
    ok "Rendered Cloudflare R2 rclone config"
    return
  fi

  cat > config/rclone/rclone.generated.conf <<'EOF'
[r2]
type = s3
provider = Cloudflare
access_key_id =
secret_access_key =
endpoint =
acl = private
no_check_bucket = false
EOF
  chmod 600 config/rclone/rclone.generated.conf
  ok "Rendered empty rclone config; R2 backups are disabled"
}

render_alertmanager_config() {
  local to
  local smtp_user
  local smtp_password

  to="$(env_value ALERT_EMAIL_TO || true)"
  smtp_user="$(env_value SMTP_USER || true)"
  smtp_password="$(env_value SMTP_PASSWORD || true)"

  if [[ -z "$to" || -z "$smtp_user" || -z "$smtp_password" ]]; then
    cat > monitoring/alertmanager.generated.yml <<'EOF'
global:
  resolve_timeout: 5m

route:
  group_by: ["alertname", "severity"]
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: default

receivers:
  - name: default
EOF
    ok "Rendered Alertmanager without email receiver"
    return
  fi

  cat > monitoring/alertmanager.generated.yml <<EOF
global:
  resolve_timeout: 5m
  smtp_smarthost: "$(env_value SMTP_SMARTHOST)"
  smtp_from: "$(env_value ALERT_FROM)"
  smtp_auth_username: "${smtp_user}"
  smtp_auth_password: "${smtp_password}"

route:
  group_by: ["alertname", "severity"]
  group_wait: 10s
  group_interval: 10s
  repeat_interval: 1h
  receiver: email

receivers:
  - name: email
    email_configs:
      - to: "${to}"
        send_resolved: true
EOF
  ok "Rendered Alertmanager with email receiver"
}

init_swarm() {
  local node_state
  local is_manager

  node_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"
  is_manager="$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || true)"

  if [[ "$node_state" == "active" && "$is_manager" == "true" ]]; then
    ok "Docker Swarm manager is already active"
    return
  fi

  if [[ "$node_state" == "active" && "$is_manager" != "true" ]]; then
    warn "Node is a Swarm worker, not a manager. Leaving and re-initializing as manager."
    docker swarm leave --force
  fi

  if [[ "$node_state" != "active" ]]; then
    docker swarm leave --force 2>/dev/null || true
  fi

  log "Initializing Docker Swarm (manager)"

  local advertise_addr="${SWARM_ADVERTISE_ADDR:-}"
  if [[ -z "$advertise_addr" ]]; then
    advertise_addr="$(detect_swarm_advertise_addr)"
  fi

  if [[ -n "$advertise_addr" ]]; then
    log "Using advertise address: $advertise_addr"
    docker swarm init --advertise-addr "$advertise_addr" || fail "docker swarm init failed. Is port 2377 open? Try: ufw allow 2377/tcp && ufw allow 7946/tcp && ufw allow 4789/udp"
  else
    log "No advertise address detected, initializing without --advertise-addr"
    docker swarm init || fail "docker swarm init failed. Set SWARM_ADVERTISE_ADDR=<your-ip> and retry."
  fi

  ok "Docker Swarm initialized as manager"
}

detect_swarm_advertise_addr() {
  local iface
  iface="$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-)' | head -1)"
  if [[ -n "$iface" ]]; then
    ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d/ -f1 | head -1
  fi
}

start_stack() {
  if [[ "$START_STACK" != "true" ]]; then
    warn "Skipping container startup because --no-start was supplied"
    return
  fi

  init_swarm

  local compose_cmd="docker stack deploy -c docker-compose.yml"
  local backup_image
  local pg_image
  local build_pg_image="true"

  backup_image="${INFRA_BACKUP_IMAGE:-infra/backup:latest}"
  pg_image="${POSTGRES_IMAGE:-infra/postgres:latest}"

  if [[ "${POSTGRES_IMAGE:-}" == postgis/* || "${POSTGRES_IMAGE:-}" == postgres:* ]]; then
    build_pg_image="false"
  fi

  if [[ "$build_pg_image" == "true" ]]; then
    if ! docker image inspect "$pg_image" >/dev/null 2>&1; then
      log "Building postgres image: $pg_image"
      docker build -t "$pg_image" -f Dockerfile.postgres .
    fi
  fi

  if ! docker image inspect "$backup_image" >/dev/null 2>&1; then
    log "Building backup image: $backup_image"
    docker build -t "$backup_image" -f Dockerfile.backup .
  fi

  log "Removing old stack (if any) to allow config updates"
  docker stack rm infra 2>/dev/null || true
  sleep 5

  log "Loading environment from .env"
  set -a
  source .env
  set +a

  log "Deploying stack"
  ${compose_cmd} infra
}

configure_database_auth() {
  if [[ "$START_STACK" != "true" ]]; then
    return
  fi

  local pg_user
  local pg_db
  local pg_password
  local auth_user
  local auth_password
  local pg_image

  pg_user="$(env_default POSTGRES_USER postgres)"
  pg_db="$(env_default POSTGRES_DB postgres)"
  pg_password="$(env_value POSTGRES_PASSWORD)"
  auth_user="$(env_default PGBOUNCER_AUTH_USER pgbouncer_auth)"
  auth_password="$(env_value PGBOUNCER_AUTH_PASSWORD)"
  pg_image="postgres:${POSTGRES_CLIENT_IMAGE_TAG:-17-alpine}"

  log "Waiting for PostgreSQL"
  local attempts=0
  while [[ "$attempts" -lt 60 ]]; do
    if docker run --rm --network infra "$pg_image" pg_isready -h postgres -U "$pg_user" -d "$pg_db" >/dev/null 2>&1; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 2
  done
  if [[ "$attempts" -eq 60 ]]; then
    fail "PostgreSQL did not become ready after 120s"
  fi

  docker run --rm -i --network infra -e PGPASSWORD="$pg_password" "$pg_image" \
    psql -h postgres -U "$pg_user" -d postgres -v ON_ERROR_STOP=1 <<SQL
CREATE SCHEMA IF NOT EXISTS pgbouncer;

CREATE OR REPLACE FUNCTION pgbouncer.get_auth(username TEXT)
RETURNS TABLE(username TEXT, password TEXT)
LANGUAGE sql
SECURITY DEFINER
AS \$\$
  SELECT rolname::TEXT, rolpassword::TEXT
  FROM pg_authid
  WHERE rolname = username
    AND rolcanlogin
    AND (rolvaliduntil IS NULL OR rolvaliduntil > now())
\$\$;

REVOKE ALL ON FUNCTION pgbouncer.get_auth(TEXT) FROM PUBLIC;

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${auth_user}') THEN
    CREATE ROLE ${auth_user} LOGIN PASSWORD '${auth_password}';
  ELSE
    ALTER ROLE ${auth_user} LOGIN PASSWORD '${auth_password}';
  END IF;
END
\$\$;
GRANT USAGE ON SCHEMA pgbouncer TO ${auth_user};
GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(TEXT) TO ${auth_user};
SQL

  docker service update --force infra_pgbouncer >/dev/null 2>&1 || true
  ok "Configured PgBouncer auth role"
}

verify_stack() {
  if [[ "$START_STACK" != "true" ]]; then
    return
  fi

  local pg_user
  local pg_db
  local pg_password
  local redis_password
  local pg_image
  local attempts

  pg_user="$(env_default POSTGRES_USER postgres)"
  pg_db="$(env_default POSTGRES_DB postgres)"
  pg_password="$(env_value POSTGRES_PASSWORD)"
  redis_password="$(env_value REDIS_PASSWORD)"
  pg_image="postgres:${POSTGRES_CLIENT_IMAGE_TAG:-17-alpine}"

  attempts=0
  log "Waiting for PgBouncer on host port $(env_default PGBOUNCER_PORT 6543)"
  while [[ "$attempts" -lt 30 ]]; do
    if docker run --rm --network host -e PGPASSWORD="$pg_password" "$pg_image" \
      psql -h 127.0.0.1 -p "$(env_default PGBOUNCER_PORT 6543)" -U "$pg_user" -d "$pg_db" -c 'SELECT 1;' >/dev/null 2>&1; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 2
  done
  if [[ "$attempts" -eq 30 ]]; then
    fail "PgBouncer did not become reachable on port $(env_default PGBOUNCER_PORT 6543) after 60s"
  fi

  attempts=0
  log "Waiting for Redis proxy on host port $(env_default REDIS_PORT 6379)"
  while [[ "$attempts" -lt 30 ]]; do
    if docker run --rm --network host redis:7-alpine \
      redis-cli -h 127.0.0.1 -p "$(env_default REDIS_PORT 6379)" -a "$redis_password" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
      break
    fi
    attempts=$((attempts + 1))
    sleep 2
  done
  if [[ "$attempts" -eq 30 ]]; then
    fail "Redis proxy did not become reachable on port $(env_default REDIS_PORT 6379) after 60s"
  fi

  ok "PgBouncer and Redis proxy are reachable"
}

print_summary() {
  local host
  host="${PUBLIC_HOST:-127.0.0.1}"

  if [[ "$START_STACK" == "true" ]]; then
    cat <<EOF

${GREEN}Deployment complete${NC}
EOF
  else
    cat <<EOF

${GREEN}Configuration rendered${NC}
EOF
  fi

  cat <<EOF

Postgres direct:
  Host: 127.0.0.1
  Port: $(env_default POSTGRES_PORT 5432)

PgBouncer:
  Host: ${host}
  Port: $(env_default PGBOUNCER_PORT 6543)
  URL: postgres://$(env_default POSTGRES_USER postgres):<password>@${host}:$(env_default PGBOUNCER_PORT 6543)/$(env_default POSTGRES_DB postgres)

Redis:
  Host: 127.0.0.1
  Port: $(env_default REDIS_PORT 6379)

pgAdmin:
  URL: http://127.0.0.1:$(env_default PGADMIN_PORT 5050)
  Email: $(env_default PGADMIN_EMAIL admin@example.com)

Grafana:
  URL: http://${host}:$(env_default GRAFANA_PORT 3030)
  User: $(env_default GRAFANA_USER admin)

Backups:
  Path: ${TARGET_DIR}/backups
  Shape: one timestamped folder, one .sql.gz per database
  R2: $(env_default R2_BACKUP_ENABLED false)

Useful commands:
  docker stack ps infra
  docker service logs infra_pgbouncer -f
  docker stack deploy -c docker-compose.yml infra
EOF
}

main() {
  parse_args "$@"

  if [[ $EUID -ne 0 && "$START_STACK" == "true" ]]; then
    fail "Run with sudo so Docker install, firewall, and bind mounts work reliably."
  fi

  mkdir -p "$TARGET_DIR"
  cd "$TARGET_DIR"

  [[ -f docker-compose.yml ]] || fail "docker-compose.yml not found in ${TARGET_DIR}"
  [[ -f .env.example ]] || fail ".env.example not found in ${TARGET_DIR}"

  if [[ "$START_STACK" == "true" ]] && command -v docker >/dev/null 2>&1; then
    fix_containerd_storage
  fi

  prepare_env
  render_pgbouncer_config
  render_redis_config
  render_pgadmin_config
  render_rclone_config
  render_alertmanager_config

  if [[ "$START_STACK" == "true" ]]; then
    install_docker
    configure_firewall
    start_stack
    configure_database_auth
    verify_stack
  else
    warn "Render-only mode complete; containers were not started"
  fi

  print_summary
}

main "$@"

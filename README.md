# PostgreSQL + PgBouncer Stack Deployment

Docker-based PostgreSQL with PgBouncer connection pooling, pgAdmin, and automated backups to Google Drive.

---

## Why This Project?

Setting up a production-ready PostgreSQL stack is harder than it should be. You need to:

- **Configure connection pooling** - Without PgBouncer, each client connection opens a new database connection, exhausting resources quickly
- **Set up automated backups** - Manual backups don't scale and get forgotten
- **Secure your database** - SSL, firewall rules, non-standard ports - it's easy to miss something
- **Manage multiple environments** - Development, staging, production all need slightly different configs
- **Connect to Cloudflare Hyperdrive** - Getting PostgreSQL to work with Cloudflare Workers requires specific configuration

This project solves all of that in one idempotent, repeatable script.

### Problems We Solve

| Problem | Solution |
|---------|----------|
| PostgreSQL connection exhaustion | PgBouncer with transaction-mode pooling |
| No automated backups | Cron-based backup container with rclone to Google Drive |
| Security vulnerabilities | UFW firewall, SSL/TLS, non-standard ports, no hardcoded secrets |
| Complex setup | One command deployment with interactive prompts for secrets |
| Cloudflare Hyperdrive integration | Pre-configured PgBouncer with SSL and transaction pooling |
| Environment management | .env-based configuration, generated passwords, idempotent scripts |

---

## Before You Start: Cloud Storage Setup (rclone)

The setup script will configure rclone automatically on your VPS. **First-time setup only** (when no rclone remote exists), you will be prompted to:

1. **Choose `n`** (New remote)
2. **Name:** `gdrive` (or your preferred name)
3. **Storage:** Enter a number or name. Popular options:
   | # | Storage |
   |---|---------|
   | 5 | Backblaze B2 |
   | 10 | Cloudinary |
   | 15 | Dropbox |
   | 24 | Google Drive |
   | 40 | Azure Blob |
   | 42 | OneDrive (Microsoft) |
   | 45 | Oracle Drive |
   | 64 | Yandex |
   | 66 | iCloud |
4. **For all other prompts:** Accept defaults by pressing Enter
5. **Auto config:** `n` (headless)

Then you'll see a URL - open it in your browser, authorize your cloud storage, and paste the verification code back into the terminal.

**The script will extract your token automatically.**

> **Note:** On subsequent runs, if rclone is already configured with a remote, the script will skip the interactive setup and use the existing token automatically.

## Quick Start

**One-line command (copy and paste):**

```bash
git clone https://github.com/oyenet1/postgres-vps-setup.git && cd postgres-vps-setup && chmod +x setup.sh && sudo ./setup.sh
```

Or step by step:

```bash
git clone https://github.com/oyenet1/postgres-vps-setup.git
cd postgres-vps-setup
chmod +x setup.sh
sudo ./setup.sh
```

**Clone a specific branch:**
```bash
git clone -b <branch-name> https://github.com/oyenet1/postgres-vps-setup.git
cd postgres-vps-setup
chmod +x setup.sh
sudo ./setup.sh
```

The script will prompt you step-by-step for any missing values.

### Command Options

| Option | Description | Default |
|--------|-------------|---------|
| `-d <dir>` | Target installation directory | Current script directory |
| `-s <port>` | SSH port for firewall | None (skips SSH rule) |

**Three ways to run:**

```bash
# 1. WITH custom SSH port - adds firewall rule for that port
sudo ./setup.sh -d /opt/postgres -s 4422

# 2. WITH default SSH port 22 - adds firewall rule for port 22
sudo ./setup.sh -d /opt/postgres -s 22

# 3. WITHOUT -s flag - skips SSH firewall rule entirely
sudo ./setup.sh -d /opt/postgres
```

> **Note:** If you omit `-s`, you must manually configure SSH access through your cloud provider's firewall/security groups.

### What the Script Does

1. Installs Docker & Docker Compose V2 (if missing)
2. Configures UFW firewall (SSH on your specified port, PgBouncer on 6543)
3. Generates SSL certificates
4. Creates docker-compose.yml and config files
5. Sets up PostgreSQL + PgBouncer + pgAdmin + Backup containers
6. Prompts for Google Drive rclone setup (if not configured)

If any environment variables are missing or are placeholders, the script will ask you step-by-step.

## Services

| Service | Port | Description |
|---------|------|-------------|
| PostgreSQL | 5432 | Database (internal only, not exposed) |
| PgBouncer | 6543 | Connection pooling (globally accessible) |
| pgAdmin | 5050 | Database administration |
| Prometheus | 9090 | Metrics collection |
| Grafana | 3030 | Dashboards and visualization |
| Alertmanager | 9093 | Alert routing and notification |

## Monitoring Setup (Optional)

During setup, you'll be asked:
```
Enable monitoring (Prometheus + Grafana)? [y/N]:
```

If you choose yes, you'll also configure:
- Grafana admin password
- Alert email address (optional)
- SMTP settings for email alerts (optional)

### Monitoring Environment Variables

```env
# Enable/Disable Monitoring
MONITORING_ENABLED=true
GRAFANA_USER=admin
GRAFANA_PASSWORD=admin123

# Alert Configuration (optional)
ALERT_EMAIL_TO=alerts@example.com
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-email@gmail.com
SMTP_PASSWORD=your-app-password
SMTP_FROM=alerts@example.com
```

### Accessing Monitoring Services

| Service | URL | Credentials |
|---------|-----|-------------|
| Prometheus | http://your-server:9090 | No auth (read-only) |
| Grafana | http://your-server:3030 | admin / (your set password) |
| Alertmanager | http://your-server:9093 | No auth (read-only) |

### Gmail SMTP Setup (for alerts)

To send alerts via Gmail, you need an **App Password**:

1. Go to: https://myaccount.google.com/apppasswords
2. Create a new App Password (select "Mail" and "Other app")
3. Copy the 16-character password
4. Use this as your `SMTP_PASSWORD` (not your regular Gmail password)

### Alerts Sent via Email

After each backup, an email report is sent with:
- Backup status (success/failed)
- Backup file name and size
- Upload status to Google Drive
- All service status (PostgreSQL, PgBouncer)
- Timestamp and duration

Critical alerts (service down, backup failed) are also sent via SMTP.

### Alert Rules Configured

| Alert | Condition | Severity |
|-------|-----------|----------|
| PostgresDown | PostgreSQL not responding | Critical |
| PostgresHighConnections | >80 connections | Warning |
| PgBouncerDown | PgBouncer not responding | Critical |
| PgBouncerHighConnections | >800 client connections | Warning |
| BackupFailed | Backup job failed | Critical |
| BackupMissing | No backup in 24 hours | Warning |

### Monitoring Files Location

All monitoring configs are in the `monitoring/` folder:
```
monitoring/
├── prometheus.yml      # Prometheus scrape config
├── alert.rules.yml     # Alert rules
└── alertmanager.yml    # Alertmanager SMTP config
```

## Example .env File (After Deployment)

After running `setup.sh`, your `.env` will look like this:

```env
# PostgreSQL Configuration
POSTGRES_VERSION=17
POSTGRES_DB=mydb
POSTGRES_USER=pguser
POSTGRES_PASSWORD=Xk9#mP2$nL5!qR8%vT4@wY7&jK3*hB6  (random 32-char password)
POSTGRES_PORT=5432

# PgBouncer Configuration
PGBOUNCER_PORT=6543
PGBOUNCER_POOL_SIZE=20
PGBOUNCER_MAX_CLIENT_CONN=1000
PGBOUNCER_SERVER_LIFETIME=3600
PGBOUNCER_SERVER_IDLE_TIMEOUT=600

# pgAdmin Configuration
PGADMIN_EMAIL=admin@example.com
PGADMIN_PASSWORD=Xk9#mP2$nL5!qR8%vT4@wY7&jK3*hB6

# Backup Configuration
BACKUP_SCHEDULE="0 */12 * * *"
GOOGLE_DRIVE_REMOTE_NAME=gdrive
GOOGLE_DRIVE_FOLDER=postgres_backups
GOOGLE_DRIVE_TOKEN={"access_token":"..."}
GOOGLE_DRIVE_TEAM_DRIVE_ID=
RCLONE_CONFIG_PATH=/config/rclone/rclone.conf
MAX_BACKUPS=3

# Monitoring
MONITORING_ENABLED=true
GRAFANA_USER=admin
GRAFANA_PASSWORD=admin123

# Alert Configuration
ALERT_EMAIL_TO=alerts@example.com
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-email@gmail.com
SMTP_PASSWORD=your-app-password
SMTP_FROM=alerts@example.com
```

## Configuration

### Changing Backup Schedule

Edit `templates/backup.cron` to change when backups run:

```bash
# Format: minute hour day month weekday command
# Examples:
0 */12 * * *    # Every 12 hours
0 2 * * *        # Daily at 2 AM
0 */6 * * *      # Every 6 hours
0 0 * * 0        # Weekly on Sunday at midnight
```

After editing, restart the backup container:
```bash
docker compose restart backup
```

### Changing Backup Retention (Max Backups)

By default, only the last 3 backups are kept on Google Drive (oldest are deleted). To change this:

1. Edit `.env`:
```
MAX_BACKUPS=5
```

2. Restart backup container:
```bash
docker compose restart backup
```

This applies to both Google Drive and local backups (keeping MAX_BACKUPS locally too).

### Creating New Databases

#### Via pgAdmin (GUI)
1. Go to `http://your-server-ip:5050`
2. Login with your `PGADMIN_EMAIL` and `PGADMIN_PASSWORD`
3. Right-click **Databases** → **Create** → **Database...**
4. Enter database name and click **Save**

#### Via SQL
1. In pgAdmin, click **Query Tool** or connect via terminal:
```bash
docker exec -it postgres psql -U pguser -d postgres -c "CREATE DATABASE newdbname;"
```

#### Via terminal directly
```bash
docker exec -it postgres psql -U pguser -d postgres -c "CREATE DATABASE mynewdb;"
```

### Adding New Databases to PgBouncer

By default, PgBouncer only knows about the primary database. To add additional databases for connection pooling:

1. Edit `pgbouncer.ini` in your deployment directory:
```ini
[databases]
postgres = host=postgres port=5432 dbname=postgres
myappdb = host=postgres port=5432 dbname=myappdb
analytics = host=postgres port=5432 dbname=analytics
```

2. Update the userlist if using different credentials:
```ini
[databases]
postgres = host=postgres port=5432 dbname=postgres user=pguser
myappdb = host=postgres port=5432 dbname=myappdb user=appuser
```

3. Restart PgBouncer:
```bash
docker compose restart pgbouncer
```

4. Connect via PgBouncer on port 6543:
```
postgresql://pguser:password@localhost:6543/myappdb
```

**Note:** For dynamic database lookup without editing config, you can use `auth_query` in PgBouncer - this allows any database to be accessed through PgBouncer without pre-configuration.

### Volume Persistence (Data Safety)

All persistent data is stored in Docker volumes - your data survives container restarts and redeployments:

| Volume | Location | What's Stored |
|--------|----------|---------------|
| `postgres_data` | `./postgres_data/` | PostgreSQL database files |
| `pgadmin_data` | Docker named volume | pgAdmin settings and configs |
| `backups` | `./backups/` | Local backup files (before upload) |
| `pgbouncer_ssl` | `./pgbouncer_ssl/` | SSL certificates and keys |

**Important:** Never delete `postgres_data/` - it contains your database!

### If Files Change (Watch Out)

When changing config files, be aware:

```bash
# SSL certificates - if regenerated, clients need new certificates
# Always backup old certs before regeneration

# .env changes - containers must be recreated to take effect
docker compose down && docker compose up -d

# pgbouncer.ini - changes require restart
docker compose restart pgbouncer

# userlist.txt - if passwords change, update here too
# The hashed password in userlist.txt must match POSTGRES_PASSWORD in .env
```

**Idempotent redeploy (safe to run multiple times):**
```bash
docker compose down && docker compose up -d
```

This will NOT destroy your data - only containers are recreated, volumes persist.

### Making Changes and Redeploying

The setup is idempotent - you can make changes and redeploy safely:

```bash
# 1. Edit configuration files (.env, docker-compose.yml, etc.)
nano .env

# 2. Stop containers
docker compose down

# 3. Start containers with new config
docker compose up -d

# Or restart specific services
docker compose restart pgbouncer
docker compose restart postgres
```

**Common changes:**

| What to Change | File to Edit | Redeploy Command |
|----------------|--------------|-------------------|
| Passwords, DB name | `.env` | `docker compose down && docker compose up -d` |
| Backup schedule | `templates/backup.cron` | `docker compose restart backup` |
| PgBouncer settings | `pgbouncer.ini` | `docker compose restart pgbouncer` |
| New environment vars | `.env` then | `docker compose down && docker compose up -d` |

### Changing PgBouncer Settings

Edit `pgbouncer.ini` for connection pooling tuning:

```ini
[pgbouncer]
listen_addr = 127.0.0.1        # Keep localhost only for security
listen_port = 6543
max_client_conn = 100           # Max simultaneous client connections
default_pool_size = 20          # Connections per database
server_lifetime = 3600          # Server connection lifetime (seconds)
server_idle_timeout = 600       # Idle server timeout (seconds)
pool_mode = transaction         # Transaction-based pooling
```

After editing, restart PgBouncer:
```bash
docker compose restart pgbouncer
```

### Changing PgBouncer Port

If you need to change the PgBouncer port (default 6543):

1. Edit `docker-compose.yml`:
   ```yaml
   pgbouncer:
     ports:
       - "6544:6543"  # Change host port from 6543 to 6544
   ```

2. Update `.env`:
   ```
   PGBOUNCER_PORT=6544
   ```

3. Restart:
   ```bash
   docker compose down
   docker compose up -d
   ```

### Changing Backup Retention

Edit `templates/backup.sh` to keep more/fewer local backups:

```bash
# Keep only 3 newest backups (change +4 to your preference)
cd "${BACKUP_DIR}" && ls -t backup_*.sql.gz | tail -n +4 | xargs -r rm -f

# Or use age-based cleanup (e.g., delete backups older than 7 days):
find "${BACKUP_DIR}" -name "backup_*.sql.gz" -mtime +7 -delete
```

### PgBouncer Security

PgBouncer listens on `0.0.0.0:6543` (globally accessible). The UFW firewall restricts access so only connections from known sources can reach it.

For Hyperdrive, a firewall rule is added to allow only Cloudflare IPs (`104.16.0.0/12`) to access PgBouncer.

To restrict PgBouncer to localhost-only (not recommended if using Hyperdrive):
```yaml
# In docker-compose.yml, change:
LISTEN_ADDR: "127.0.0.1"  # Listen on localhost only
ports:
  - "127.0.0.1:6543:5432"  # Only accessible via 127.0.0.1
```

## Accessing pgAdmin

pgAdmin is pre-configured and ready to use once the stack is running.

### 1. Open pgAdmin

Navigate to: `http://your-server-ip:5050`

### 2. Login

Use the credentials you set in `.env`:

- **Email**: `PGADMIN_EMAIL` (e.g., `admin@example.com`)
- **Password**: `PGADMIN_PASSWORD`

### 3. Add Your PostgreSQL Server

1. Click **"Add New Server"** in the dashboard
2. **General tab**:
   - Name: `PostgreSQL` (or any name you prefer)
3. **Connection tab**:
   - Host name/address: `postgres` (Docker internal hostname)
   - Port: `5432`
   - Database: `postgres`
   - Username: `PGADMIN_USER` from `.env` (e.g., `pguser`)
   - Password: `POSTGRES_PASSWORD` from `.env`
4. Click **"Save"**

### 4. View Your Database

Once connected:
- Expand **Servers** → **PostgreSQL** → **Databases** → **postgres**
- Expand **Schemas** → **Tables** to see your tables

### 5. Create a New Database

1. Right-click **Databases** → **Create** → **Database...**
2. Enter the database name (e.g., `mynewdb`)
3. Click **Save**

Or via SQL query tool:
```sql
CREATE DATABASE mynewdb;
```

### 6. Create a New User

```sql
CREATE USER newuser WITH PASSWORD 'your_password';
GRANT ALL PRIVILEGES ON DATABASE mynewdb TO newuser;
```

## Google Drive Token Setup (rclone OAuth)

### Method 1: Interactive OAuth (Recommended for testing)

```bash
curl https://rclone.org/install.sh | sudo bash
rclone config
```

### Method 2: Service Account (Recommended for production)

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project or select existing
3. Enable Google Drive API
4. Create Service Account:
   - IAM & Admin > Service Accounts > Create
   - Name it (e.g., `backup-uploader`)
   - Grant "Project Owner" or "Drive File" access
5. Generate JSON key:
   - Click service account > Keys > Add Key > JSON
   - Download the JSON file
6. Configure rclone:
   ```bash
   rclone config
   # n > name: gdrive > drive > y
   # service_account_credentials: /path/to/json
   ```

### Method 3: Token-Based (Headless Server)

1. On local machine, run: `rclone config` to get OAuth URL
2. Visit URL, authorize, get code
3. Paste code back
4. Copy `~/.config/rclone/rclone.conf` to server at `./config/rclone/rclone.conf`

## Security Checklist

- [ ] SSH on non-standard port (4422)
- [ ] UFW deny-by-default policy
- [ ] Only ports 4422 (SSH) and 6543 (PgBouncer) exposed
- [ ] SSL/TLS encryption for PgBouncer
- [ ] Strong random passwords in `.env`
- [ ] No hardcoded credentials
- [ ] Backup encryption (gzip only; consider gpg for sensitive data)

## File Structure

```
dbsetup/
├── setup.sh
├── docker-compose.yml
├── .env.example
├── README.md
├── templates/
│   ├── pgbouncer.ini
│   ├── backup.sh
│   └── backup.cron
├── config/
│   └── rclone/
│       └── rclone.conf    (generated from .env)
└── ssl/                   (generated)
    ├── server.crt
    └── server.key
```

## Useful Commands

```bash
docker compose logs -f postgres
docker compose logs -f pgbouncer
docker compose ps
docker compose restart pgbouncer
```

## Cloudflare Hyperdrive (Optional)

Cloudflare Hyperdrive lets your Cloudflare Workers connect to your PostgreSQL database with automatic caching, connection pooling, and reduced latency worldwide. This setup uses PgBouncer as the target (not direct PostgreSQL), which provides additional connection pooling benefits.

### Benefits of Hyperdrive

| Benefit | Description |
|---------|-------------|
| **Global Performance** | Cache queries at Cloudflare's 300+ data centers worldwide |
| **Connection Pooling** | Hyperdrive manages a pool of connections to your database, reducing connection overhead |
| **Reduced Latency** | Workers connect to the nearest Cloudflare edge, which then connects to your VPS through Hyperdrive |
| **SSL/TLS by Default** | All connections are encrypted automatically |
| **No Cold Starts** | Hyperdrive keeps connections warm |
| **Cost Savings** | Reduced database compute since connection pooling is handled by both PgBouncer and Hyperdrive |
| **Security** | Only Cloudflare IPs (104.16.0.0/12) can reach your PgBouncer port |

### Architecture

```
Cloudflare Workers → Hyperdrive → PgBouncer (6543) → PostgreSQL (5432)
                                        ↓
                              Connection Pooling
                              (transaction mode)
```

**PgBouncer is globally accessible** (0.0.0.0:6543) to allow Hyperdrive connections. The UFW firewall ensures only Cloudflare IPs (`104.16.0.0/12`) can reach it when Hyperdrive is enabled.

**Why connect through PgBouncer?**
- PgBouncer provides transaction-mode connection pooling (more efficient than session-mode)
- Reduces load on PostgreSQL by reusing connections
- Hyperdrive connects to PgBouncer's port 6543, not directly to PostgreSQL's 5432

### During Setup

When running `setup.sh`, you'll be prompted:
```
Setup Cloudflare Hyperdrive? [y/N]:
```

If you choose yes, the script will:
1. Auto-install Node.js 22 (if missing)
2. Install Wrangler CLI
3. Open browser for Cloudflare authentication (`wrangler login`)
4. Get your server's public IP automatically
5. Create Hyperdrive binding connected to PgBouncer
6. Configure PgBouncer to listen on all interfaces (`0.0.0.0:6543`)
7. Open firewall for Cloudflare IPs (`104.16.0.0/12`)

### Manual Setup (if not using automated setup)

```bash
# 1. Install Wrangler
npm install -g wrangler@latest

# 2. Login to Cloudflare
wrangler login

# 3. Create Hyperdrive (pointing to PgBouncer port 6543)
wrangler hyperdrive create postgres-hd \
  --connection-string="postgres://pguser:your_password@YOUR_PUBLIC_IP:6543/mydb?sslmode=require"

# 4. Copy the Hyperdrive ID from the output
```

### Add to wrangler.jsonc

```jsonc
{
  "hyperdrive": [{
    "binding": "HYPERDRIVE",
    "id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
  }]
}
```

### Use in Worker Code

```typescript
export interface Env {
  HYPERDRIVE: Hyperdrive;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const client = await env.HYPERDRIVE.getClient();

    // Query through Hyperdrive (connected to PgBouncer)
    const result = await client.queryArray('SELECT NOW()');
    await client.end();

    return new Response(JSON.stringify(result.rows));
  }
};
```

### Environment Variables Added

After Hyperdrive setup, your `.env` will include:
```env
HYPERDRIVE_ENABLED=true
HYPERDRIVE_NAME=postgres-hd
HYPERDRIVE_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
HYPERDRIVE_CONNECTION_STRING=postgres://user:pass@PUBLIC_IP:6543/db?sslmode=require
```

### Firewall Changes for Hyperdrive

When Hyperdrive is enabled:
- PgBouncer changes from `LISTEN_ADDR: "127.0.0.1"` to `LISTEN_ADDR: "0.0.0.0"`
- UFW rule added: `ufw allow from 104.16.0.0/12 to any port 6543 proto tcp`
- Only Cloudflare can reach port 6543 externally

### Important Notes

- **Always connect to port 6543 (PgBouncer)**, not 5432 (PostgreSQL direct)
- **SSL is required** - always append `?sslmode=require`
- **PgBouncer uses transaction pooling** - no prepared statements across transactions
- **Keep your Hyperdrive ID secret** - it's the key to your database
- **Node.js 22 required** for Wrangler CLI

### Disabling Hyperdrive

To disable Hyperdrive and restrict PgBouncer to localhost-only:
1. Set `HYPERDRIVE_ENABLED=false` in `.env`
2. Edit `docker-compose.yml`:
   - Change `LISTEN_ADDR: "0.0.0.0"` to `LISTEN_ADDR: "127.0.0.1"`
   - Change `"6543:5432"` to `"127.0.0.1:6543:5432"`
3. Remove the Cloudflare firewall rule: `ufw delete allow from 104.16.0.0/12 to any port 6543 proto tcp`
4. Restart: `docker compose down && docker compose up -d`

---

## About

Created by [Bowofade](https://bowofade.com) | [Twitter](https://twitter.com/Fade_networker) | [Hire or Collaborate](https://bowofade.com)
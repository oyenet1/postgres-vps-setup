# PostgreSQL + PgBouncer Stack Deployment

Docker-based PostgreSQL with PgBouncer connection pooling, pgAdmin, and automated backups to Google Drive.

## Before You Start: Get Google Drive Token

**You need an rclone Google Drive token first.** On your local machine:

```bash
# 1. Install rclone
curl https://rclone.org/install.sh | sudo bash

# 2. Configure rclone with Google Drive
rclone config
# Select: n (New remote) → drive → y (Google Drive) → stay at default → y (Yes) → n (No team drive) → y (Yes complete) → q (Quit)

# 3. Get the token from the config
cat ~/.config/rclone/rclone.conf
# Look for the token= line under [gdrive]
# Copy the full token value (everything after "token = ")
```

**Token format looks like:** `{"access_token":"ya29.a0AfH6SMB...","token_type":"Bearer","refresh_token":"1//0gYJ9...","expiry":"2024-..."}`

## Quick Start (One-Liner)

```bash
git clone https://github.com/your-repo/dbsetup.git && cd dbsetup && chmod +x setup.sh && sudo ./setup.sh -d /opt/postgres -s 4422
```

Or step by step:

```bash
git clone https://github.com/your-repo/dbsetup.git
cd dbsetup
chmod +x setup.sh
sudo ./setup.sh -d /opt/postgres -s 4422
```

When prompted, paste your Google Drive token.

## Services

| Service | Port | Description |
|---------|------|-------------|
| PostgreSQL | 5432 | Database (internal only, not exposed) |
| PgBouncer | 6543 | Connection pooling (localhost only) |
| pgAdmin | 5050 | Database administration |

## Example .env File (After Deployment)

After running `setup.sh`, your `.env` will look like this:

```env
# PostgreSQL Configuration
POSTGRES_VERSION=16
POSTGRES_DB=mydb
POSTGRES_USER=pguser
POSTGRES_PASSWORD=Xk9#mP2$nL5!qR8%vT4@wY7&jK3*hB6  (random 32-char password)
POSTGRES_PORT=5432

# PgBouncer Configuration
PGBOUNCER_PORT=6543
PGBOUNCER_POOL_SIZE=20
PGBOUNCER_MAX_CLIENT_CONN=100
PGBOUNCER_SERVER_LIFETIME=3600
PGBOUNCER_SERVER_IDLE_TIMEOUT=600

# pgAdmin Configuration
PGADMIN_EMAIL=admin@example.com
PGADMIN_PASSWORD=Xk9#mP2$nL5!qR8%vT4@wY7&jK3*hB6

# Backup Configuration
BACKUP_SCHEDULE="0 */12 * * *"    # Every 12 hours
GOOGLE_DRIVE_REMOTE_NAME=gdrive
GOOGLE_DRIVE_FOLDER=postgres_backups
GOOGLE_DRIVE_TOKEN={"access_token":"..."}   (your rclone token)
GOOGLE_DRIVE_TEAM_DRIVE_ID=
RCLONE_CONFIG_PATH=/config/rclone/rclone.conf
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

### PgBouncer Security (localhost-only)

PgBouncer is configured to listen on `127.0.0.1:6543` only. External access is blocked by the UFW firewall.

To allow external access (not recommended without additional firewall rules):
```ini
listen_addr = 0.0.0.0  # Listen on all interfaces
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

## Connecting via Cloudflare Hyperdrive

You can connect your Cloudflare Workers to this PostgreSQL database through Hyperdrive.

### 1. Install Wrangler and Login

```bash
npm install -g wrangler
wrangler login
```

### 2. Create a Hyperdrive Binding

```bash
wrangler hyperdrive create my-postgres-db --connection-string="postgres://pguser:your_password@your-server-ip:6543/mydb?sslmode=require"
```

### 3. Add to wrangler.jsonc

```jsonc
{
  "hyperdrive": {
    "DB": {
      "id": "your-hyperdrive-id",
      "protocol": "postgresql",
      "connectionString": "postgres://pguser:your_password@your-server-ip:6543/mydb?sslmode=require"
    }
  }
}
```

### 4. Use in Worker Code

```typescript
export interface Env {
  DB: Hyperdrive;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const client = await env.DB.getClient();

    const result = await client.queryArray('SELECT NOW()');
    await client.end();

    return new Response(JSON.stringify(result.rows));
  }
};
```

### 5. Firewall Requirements

PgBouncer is configured to listen on `127.0.0.1` (localhost) for security. For Hyperdrive to work, you need to allow Cloudflare IPs:

```bash
# Allow Cloudflare IP ranges to reach PgBouncer
ufw allow from 104.16.0.0/12 to any port 6543
```

If using Hyperdrive, you may also need to change PgBouncer to listen externally. Edit `pgbouncer.ini`:

```ini
listen_addr = 0.0.0.0  # Listen on all interfaces for Hyperdrive access
```

Then restart:
```bash
docker compose restart pgbouncer
```

### Important Notes

- **PgBouncer defaults to localhost-only** for security. Enable external access if using Hyperdrive.
- **Always use PgBouncer port 6543**, not direct PostgreSQL port 5432
- **Enable SSL** by appending `?sslmode=require` to your connection string
- **Use transaction pooling mode** - Hyperdrive is compatible with PgBouncer's transaction mode
- Keep your `POSTGRES_PASSWORD` secure and never commit it to version control
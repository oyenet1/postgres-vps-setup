# Cloudflare Tunnel + Hyperdrive

This stack includes a `cloudflared` service that opens a private Cloudflare Tunnel to your infrastructure. Use it to:

- Expose **PgBouncer** and **Redis** privately to Cloudflare's edge
- Connect **Cloudflare Workers** to your database with sub-millisecond latency
- Use **Cloudflare Hyperdrive** for connection pooling at the edge
- Keep port 6543 / 6379 closed to the public internet

## Setup

### 1. Create a Cloudflare Tunnel

On any machine with `cloudflared` installed (or via the dashboard):

```bash
cloudflared tunnel login
cloudflared tunnel create infra-db
cloudflared tunnel token infra-db
```

The last command prints a long `TUNNEL_TOKEN` string. Copy it.

### 2. Add the token to `.env`

```env
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoixxxxxxxx...
```

### 3. Configure ingress (in Cloudflare Zero Trust dashboard)

Go to https://one.dash.cloudflare.com → Networks → Tunnels → `infra-db` → Configure → Public Hostname:

| Subdomain | Domain | Service |
|---|---|---|
| `pg` | `yourdomain.com` | `tcp://pgbouncer:6432` |
| `redis` | `yourdomain.com` | `tcp://redis-proxy:6379` |

(Or use the cloudflared config file in this repo and mount it as a Swarm config — see "Advanced" below.)

### 4. Redeploy the stack

```bash
docker service update --force infra_cloudflared
```

Or redeploy the whole stack:

```bash
docker stack deploy -c docker-compose.yml infra
```

## Use from a Cloudflare Worker

### Direct connection (Postgres / Redis)

```js
// wrangler.toml
// [[hyperdrive]]
// binding = "HYPERDRIVE"
// id = "<hyperdrive-id>"

export default {
  async fetch(req, env) {
    // Postgres via Hyperdrive
    const { Client } = require('pg');
    const client = new Client({ connectionString: env.HYPERDRIVE.connectionString });
    await client.connect();
    const { rows } = await client.query('SELECT 1 as ping');
    await client.end();

    return Response.json(rows);
  }
}
```

### Use Hyperdrive

In Cloudflare dashboard → Workers & Pages → Hyperdrive → Create configuration:

- **Connection string**: `postgres://postgres:PASSWORD@pg.yourdomain.com:5432/myapp`
- Click create, copy the Hyperdrive ID

Add to your Worker's `wrangler.toml`:

```toml
[[hyperdrive]]
binding = "HYPERDRIVE"
id = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

Then in your Worker code, use `env.HYPERDRIVE.connectionString`:

```js
import { Client } from 'pg';

export default {
  async fetch(req, env) {
    const client = new Client({ connectionString: env.HYPERDRIVE.connectionString });
    await client.connect();
    const { rows } = await client.query('SELECT now()');
    await client.end();
    return Response.json(rows);
  }
}
```

## Use from a Cloudflare Worker without Hyperdrive

If you don't need Hyperdrive, just point your Worker at the tunnel directly:

```js
// Postgres
import { Client } from 'pg';
const client = new Client({
  host: 'pg.yourdomain.com',
  port: 5432,
  user: 'postgres',
  password: env.DB_PASSWORD,
  database: 'myapp',
  ssl: { rejectUnauthorized: false }
});
```

For Redis, use any Redis client library with `redis://:PASSWORD@redis.yourdomain.com:6379`.

## Security notes

- The tunnel is outbound-only — no public inbound ports needed for 6543/6379
- Cloudflare authenticates the tunnel using the token; only your Cloudflare account can reach the services
- Restrict which Workers can reach the tunnel via Cloudflare WAF / Zero Trust policies
- For database traffic, use `sslmode=require` in your connection strings (Hyperdrive enforces this)

## Advanced: custom cloudflared config

If you want to define ingress rules in a config file instead of the dashboard:

1. Create `cloudflared/config.yml`:

```yaml
tunnel: <TUNNEL_ID>
credentials-file: /etc/cloudflared/<TUNNEL_ID>.json
ingress:
  - hostname: pg.yourdomain.com
    service: tcp://pgbouncer:6432
  - hostname: redis.yourdomain.com
    service: redis://redis-proxy:6379
  - service: http_status:404
```

2. Change the `cloudflared` service in `docker-compose.yml`:

```yaml
cloudflared:
  image: cloudflare/cloudflared:latest
  command: tunnel --no-autoupdate --config /etc/cloudflared/config.yml run
  configs:
    - source: cloudflared_config
      target: /etc/cloudflared/config.yml
    - source: cloudflared_creds
      target: /etc/cloudflared/<TUNNEL_ID>.json
  secrets:
    - cloudflared_creds
```

3. Add to the top-level `configs:` and `secrets:` sections.

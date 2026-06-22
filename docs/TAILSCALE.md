# Cross-Swarm Service Discovery with Tailscale

Docker Swarm overlay networks are **cluster-scoped** — service names like `redis-proxy`, `postgres`, `pgbouncer` only resolve inside the Swarm that owns them. To make those names work from other Swarm clusters (your app VPSes), use a Tailscale mesh + `/etc/hosts`.

## What this gives you

- A flat private network across all your VPSes
- Direct Wireguard P2P tunnels (sub-millisecond latency in the same region)
- Service names resolvable across Swarms

## One-time setup

### 1. Create a free Tailscale account

Go to https://login.tailscale.com/start and sign in with GitHub / Google / Microsoft.

The **Personal** plan is free for up to 100 devices and 3 users.

### 2. Install Tailscale on every VPS

On **each VPS** (infra + every app VPS):

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

Then authenticate. Easiest (interactive, one click per machine):

```bash
sudo tailscale up
# it prints a URL → open it → click "Allow"
```

Or unattended with a reusable auth key:
1. https://login.tailscale.com/admin/settings/keys → **Generate auth key** (not API key)
2. On each VPS:
```bash
sudo tailscale up --authkey=tskey-auth-xxxxx
```

## Get the infra VPS Tailscale IP

On the **infra VPS** (the one running this stack):

```bash
tailscale ip -4
# example output: 100.64.0.1
```

That's the stable address other VPSes will use.

## Make service names resolvable on every app VPS

On **every app VPS**, run:

```bash
echo "100.64.0.1  redis-proxy postgres pgbouncer" | sudo tee -a /etc/hosts
```

(Replace `100.64.0.1` with the actual Tailscale IP from the previous step.)

This makes those three names resolve to the infra VPS for any container running on that machine.

## From your app containers

Now your app Swarm services can connect using the same names they'd use inside the infra Swarm:

```yaml
# example app service in another Swarm
services:
  myapp:
    image: myapp:latest
    environment:
      DATABASE_URL: postgres://postgres:PASSWORD@postgres:5432/myapp
      REDIS_URL: redis://:REDIS_PASSWORD@redis-proxy:6379
```

Traffic flows: app container → Tailscale tunnel (Wireguard P2P) → infra VPS → service.

## Latency

Tailscale uses direct Wireguard peer-to-peer tunnels when possible. Same-region VPSes typically see <1ms added latency. Falls back to DERP relay servers only if direct connection fails (e.g., behind aggressive NAT).

## Adding a new app VPS

1. Install + auth Tailscale: `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up`
2. Add the `/etc/hosts` line with the infra Tailscale IP
3. Done — service names now resolve on that VPS

## Verifying

On any VPS:

```bash
ping redis-proxy        # should reach the infra VPS
nslookup redis-proxy    # should return the Tailscale IP
```

## Troubleshooting

- **"unable to validate API key"** — you used a `tskey-api-...` (API key) instead of `tskey-auth-...` (auth key). Generate a new one from the **auth keys** page.
- **Service still not resolving** — check `/etc/hosts` has the entry and the IP is the infra VPS's Tailscale IP, not its public IP.
- **High latency** — both VPSes are behind symmetric NAT or in very different regions. Tailscale falls back to DERP relay servers; latency will be higher. Consider adding the VPSes to the same datacenter/VPC if latency is critical.
- **Forgot the auth key** — go to https://login.tailscale.com/admin/settings/keys, revoke the old one, generate a new one.

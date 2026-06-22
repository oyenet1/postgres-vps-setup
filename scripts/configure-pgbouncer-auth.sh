#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f .env ]]; then
  echo "[pgbouncer-auth] .env not found. Run ./setup.sh --no-start first." >&2
  exit 1
fi

set -a
source .env
set +a

POSTGRES_DB="${POSTGRES_DB:-postgres}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
PGBOUNCER_AUTH_USER="${PGBOUNCER_AUTH_USER:-pgbouncer_auth}"
POSTGRES_CLIENT_IMAGE_TAG="${POSTGRES_CLIENT_IMAGE_TAG:-17-alpine}"

if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
  echo "[pgbouncer-auth] POSTGRES_PASSWORD is missing in .env" >&2
  exit 1
fi

if [[ -z "${PGBOUNCER_AUTH_PASSWORD:-}" ]]; then
  echo "[pgbouncer-auth] PGBOUNCER_AUTH_PASSWORD is missing in .env" >&2
  exit 1
fi

PG_IMAGE="postgres:${POSTGRES_CLIENT_IMAGE_TAG}"

echo "[pgbouncer-auth] Waiting for PostgreSQL"
attempts=0
while [[ "$attempts" -lt 60 ]]; do
  if docker run --rm --network infra "$PG_IMAGE" \
    pg_isready -h postgres -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
    break
  fi

  attempts=$((attempts + 1))
  sleep 2
done

if [[ "$attempts" -eq 60 ]]; then
  echo "[pgbouncer-auth] PostgreSQL did not become ready after 120s" >&2
  exit 1
fi

docker run --rm -i --network infra -e PGPASSWORD="$POSTGRES_PASSWORD" "$PG_IMAGE" \
  psql \
    -h postgres \
    -U "$POSTGRES_USER" \
    -d postgres \
    -v ON_ERROR_STOP=1 \
    -v pgbouncer_auth_user="$PGBOUNCER_AUTH_USER" \
    -v pgbouncer_auth_password="$PGBOUNCER_AUTH_PASSWORD" <<'SQL'
CREATE SCHEMA IF NOT EXISTS pgbouncer;

CREATE OR REPLACE FUNCTION pgbouncer.get_auth(username TEXT)
RETURNS TABLE(username TEXT, password TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  SELECT rolname::TEXT, rolpassword::TEXT
  FROM pg_authid
  WHERE rolname = username
    AND rolcanlogin
    AND (rolvaliduntil IS NULL OR rolvaliduntil > now())
$$;

REVOKE ALL ON FUNCTION pgbouncer.get_auth(TEXT) FROM PUBLIC;

SELECT format('CREATE ROLE %I LOGIN', :'pgbouncer_auth_user')
WHERE NOT EXISTS (
  SELECT 1 FROM pg_roles WHERE rolname = :'pgbouncer_auth_user'
)
\gexec

SELECT format(
  'ALTER ROLE %I WITH LOGIN PASSWORD %L',
  :'pgbouncer_auth_user',
  :'pgbouncer_auth_password'
)
\gexec

SELECT format('GRANT USAGE ON SCHEMA pgbouncer TO %I', :'pgbouncer_auth_user')
\gexec

SELECT format('GRANT EXECUTE ON FUNCTION pgbouncer.get_auth(TEXT) TO %I', :'pgbouncer_auth_user')
\gexec
SQL

docker service update --force infra_pgbouncer >/dev/null 2>&1 || true

echo "[pgbouncer-auth] PgBouncer auth query is configured"

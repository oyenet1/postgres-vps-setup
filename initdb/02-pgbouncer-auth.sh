#!/bin/bash
set -e

if [ -n "${PGBOUNCER_AUTH_USER:-}" ] && [ -n "${PGBOUNCER_AUTH_PASSWORD:-}" ]; then
psql \
  -v ON_ERROR_STOP=1 \
  --username "$POSTGRES_USER" \
  --dbname postgres \
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
fi

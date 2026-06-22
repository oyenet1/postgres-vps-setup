-- =============================================================================
-- Infrastructure Postgres: enable ALL supported extensions by default
-- Runs on first cluster init via /docker-entrypoint-initdb.d/
--
-- Installs into template1 so EVERY NEW DATABASE (pgAdmin, CREATE DATABASE)
-- inherits the same extensions automatically.
-- =============================================================================

-- Helper: install extension list in current database (ignore if package missing)
DO $$
DECLARE
  ext TEXT;
  extensions TEXT[] := ARRAY[
    -- PostGIS / geospatial / location
    'postgis',
    'postgis_topology',
    'postgis_raster',
    'postgis_sfcgal',
    'postgis_tiger_geocoder',
    'address_standardizer',
    'address_standardizer_data_us',
    -- Location & distance search (cube + earthdistance)
    'cube',
    'earthdistance',
    -- Text search & fuzzy matching
    'pg_trgm',
    'unaccent',
    'fuzzystrmatch',
    -- Index support for arrays, GIS, full-text
    'btree_gin',
    'btree_gist',
    -- AI / vector embeddings (requires pgvector in image — see Dockerfile.postgres)
    'vector',
    -- Scheduling (requires pg_cron in image — see Dockerfile.postgres)
    'pg_cron',
    -- Performance & observability
    'pg_stat_statements',
    'pg_prewarm',
    -- Data types & utilities
    'hstore',
    'ltree',
    'citext',
    'intarray',
    'pgcrypto',
    'uuid-ossp',
    'tablefunc',
    'isn',
    'seg'
  ];
BEGIN
  FOREACH ext IN ARRAY extensions
  LOOP
    BEGIN
      EXECUTE format('CREATE EXTENSION IF NOT EXISTS %I', ext);
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'Extension % not available (skipped): %', ext, SQLERRM;
    END;
  END LOOP;
END
$$;

-- template1: all future databases inherit extensions from this template
\c template1

DO $$
DECLARE
  ext TEXT;
  extensions TEXT[] := ARRAY[
    'postgis',
    'postgis_topology',
    'postgis_raster',
    'postgis_sfcgal',
    'postgis_tiger_geocoder',
    'address_standardizer',
    'address_standardizer_data_us',
    'cube',
    'earthdistance',
    'pg_trgm',
    'unaccent',
    'fuzzystrmatch',
    'btree_gin',
    'btree_gist',
    'vector',
    'pg_cron',
    'pg_stat_statements',
    'pg_prewarm',
    'hstore',
    'ltree',
    'citext',
    'intarray',
    'pgcrypto',
    'uuid-ossp',
    'tablefunc',
    'isn',
    'seg'
  ];
BEGIN
  FOREACH ext IN ARRAY extensions
  LOOP
    BEGIN
      EXECUTE format('CREATE EXTENSION IF NOT EXISTS %I', ext);
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'template1: extension % not available (skipped): %', ext, SQLERRM;
    END;
  END LOOP;
END
$$;

-- Return to default database (POSTGRES_DB, usually postgres)
\c postgres

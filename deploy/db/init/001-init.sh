#!/bin/bash
# OFM bootstrap: runs automatically on the FIRST start of an empty database
# volume only, after the TimescaleDB image's own init scripts.
# Creates the schemas and the least-privilege roles (Architecture Overview §13)
# with passwords taken from deploy/.env, so no password is stored in Git.
# Everything after this (tables, views, triggers) arrives as numbered
# migrations in db/migrations/, applied as the superuser (POSTGRES_USER), so
# that the default privileges below apply to the objects they create.

: "${OFM_RUNTIME_DB_PASSWORD:?OFM_RUNTIME_DB_PASSWORD is not set in deploy/.env}"
: "${OFM_CONFIG_DB_PASSWORD:?OFM_CONFIG_DB_PASSWORD is not set in deploy/.env}"
: "${OFM_READER_DB_PASSWORD:?OFM_READER_DB_PASSWORD is not set in deploy/.env}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v runtime_pw="$OFM_RUNTIME_DB_PASSWORD" \
  -v config_pw="$OFM_CONFIG_DB_PASSWORD" \
  -v reader_pw="$OFM_READER_DB_PASSWORD" <<'EOSQL'

CREATE EXTENSION IF NOT EXISTS timescaledb;

-- ADR-0003: every session in this database works in UTC.
ALTER DATABASE :"DBNAME" SET timezone TO 'UTC';

CREATE SCHEMA config;   -- the Industrial Information Model
CREATE SCHEMA hist;     -- the historian

CREATE ROLE ofm_runtime LOGIN PASSWORD :'runtime_pw';
CREATE ROLE ofm_config  LOGIN PASSWORD :'config_pw';
CREATE ROLE ofm_reader  LOGIN PASSWORD :'reader_pw';

-- Least privilege: runtime reads the model and appends history (never UPDATE
-- or DELETE, ADR-0006); config edits the model (Mathesar); reader sees
-- everything and changes nothing (Grafana, analytics).
GRANT USAGE ON SCHEMA config TO ofm_runtime, ofm_config, ofm_reader;
GRANT USAGE ON SCHEMA hist   TO ofm_runtime, ofm_reader;

ALTER DEFAULT PRIVILEGES IN SCHEMA config
  GRANT SELECT ON TABLES TO ofm_runtime, ofm_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA config
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ofm_config;
ALTER DEFAULT PRIVILEGES IN SCHEMA config
  GRANT USAGE ON SEQUENCES TO ofm_config;
ALTER DEFAULT PRIVILEGES IN SCHEMA hist
  GRANT SELECT, INSERT ON TABLES TO ofm_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA hist
  GRANT USAGE ON SEQUENCES TO ofm_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA hist
  GRANT SELECT ON TABLES TO ofm_reader;
EOSQL

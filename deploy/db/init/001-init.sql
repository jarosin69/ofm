-- OFM bootstrap: runs automatically on the FIRST container start only.
-- Creates the extension, the two schemas, and the least-privilege roles
-- from Architecture Overview section 13. Phase 1 DDL (tables, views,
-- triggers) arrives later as numbered migrations.

CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE SCHEMA IF NOT EXISTS config;   -- the Industrial Information Model
CREATE SCHEMA IF NOT EXISTS hist;     -- the historian

-- Roles (passwords are placeholders: change them, or manage via migrations)
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ofm_runtime') THEN
    CREATE ROLE ofm_runtime LOGIN PASSWORD 'change-me-runtime';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ofm_config') THEN
    CREATE ROLE ofm_config LOGIN PASSWORD 'change-me-config';
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ofm_reader') THEN
    CREATE ROLE ofm_reader LOGIN PASSWORD 'change-me-reader';
  END IF;
END $$;

-- Least privilege: runtime reads the model and appends history;
-- config edits the model; reader sees everything, changes nothing.
GRANT USAGE ON SCHEMA config TO ofm_runtime, ofm_config, ofm_reader;
GRANT USAGE ON SCHEMA hist   TO ofm_runtime, ofm_reader;

ALTER DEFAULT PRIVILEGES IN SCHEMA config
  GRANT SELECT ON TABLES TO ofm_runtime, ofm_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA config
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ofm_config;
ALTER DEFAULT PRIVILEGES IN SCHEMA hist
  GRANT SELECT, INSERT ON TABLES TO ofm_runtime;
ALTER DEFAULT PRIVILEGES IN SCHEMA hist
  GRANT SELECT ON TABLES TO ofm_reader;

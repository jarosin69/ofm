-- 001 Foundations: naming rules, audit columns and the audit log.
-- Used by every configuration table created in later migrations.

-- ---------------------------------------------------------------------------
-- Naming rule (Architecture Overview §6.1). Names become MQTT topic segments,
-- so they are lowercase letters, digits and underscores, starting with a
-- letter, at most 48 characters. A malformed name cannot be stored, so a
-- malformed topic can never reach the broker.
-- ---------------------------------------------------------------------------
CREATE FUNCTION config.fn_is_valid_name(name text)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$ SELECT name ~ '^[a-z][a-z0-9_]{0,47}$' $$;

COMMENT ON FUNCTION config.fn_is_valid_name(text) IS
  'True if the text is a valid OFM name: lowercase a-z, 0-9 and _, starting with a letter, max 48 characters.';

-- Time zone names (e.g. Australia/Melbourne) are checked against the database's
-- time zone list, so a typo is refused instead of breaking reports later.
CREATE FUNCTION config.fn_is_valid_time_zone(tz text)
RETURNS boolean
LANGUAGE sql STABLE
AS $$ SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_timezone_names WHERE name = tz) $$;

-- ---------------------------------------------------------------------------
-- Audit columns (Architecture Overview §11). Every configuration table has
-- created_at, created_by, updated_at and updated_by. This trigger keeps them
-- honest on every UPDATE: the "created" pair can never be changed.
-- Note: NocoDB connects as the single role ofm_config, so *_by shows the
-- database role; the person is recorded in NocoDB's own audit log.
-- ---------------------------------------------------------------------------
CREATE FUNCTION config.fn_set_audit_columns()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.created_at := OLD.created_at;
  NEW.created_by := OLD.created_by;
  NEW.updated_at := now();
  NEW.updated_by := current_user;
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------------
-- Audit log: an old/new image of every changed configuration row. It lives in
-- its own schema, which the editing role (ofm_config) cannot reach, so the log
-- cannot be edited from NocoDB. Rows are written by a SECURITY DEFINER
-- function, i.e. with the rights of the migration owner, not of the editor.
-- ---------------------------------------------------------------------------
CREATE SCHEMA audit;

CREATE TABLE audit.audit_log (
  id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  changed_at  timestamptz NOT NULL DEFAULT now(),
  changed_by  text        NOT NULL,
  table_name  text        NOT NULL,
  row_id      bigint,
  action      text        NOT NULL CHECK (action IN ('INSERT', 'UPDATE', 'DELETE')),
  old_row     jsonb,
  new_row     jsonb
);

CREATE INDEX audit_log_table_row_idx ON audit.audit_log (table_name, row_id, changed_at);

COMMENT ON TABLE audit.audit_log IS
  'Old and new image of every INSERT, UPDATE and DELETE on configuration tables. Written by trigger only.';

CREATE FUNCTION audit.fn_log_change()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, audit
AS $$
BEGIN
  INSERT INTO audit.audit_log (changed_by, table_name, row_id, action, old_row, new_row)
  VALUES (
    session_user,                                   -- the login role, not the function owner
    TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
    COALESCE((to_jsonb(NEW) ->> 'id')::bigint, (to_jsonb(OLD) ->> 'id')::bigint),
    TG_OP,
    CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END,
    CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END
  );
  RETURN NULL;
END $$;

-- Attaches both audit triggers to a configuration table. Called once per table
-- (CALL audit.fn_enable('config.site')) by the migrations that create tables.
CREATE PROCEDURE audit.fn_enable(target regclass)
LANGUAGE plpgsql
AS $$
BEGIN
  EXECUTE format(
    'CREATE TRIGGER trg_set_audit_columns BEFORE UPDATE ON %s
       FOR EACH ROW EXECUTE FUNCTION config.fn_set_audit_columns()', target);
  EXECUTE format(
    'CREATE TRIGGER trg_audit_log AFTER INSERT OR UPDATE OR DELETE ON %s
       FOR EACH ROW EXECUTE FUNCTION audit.fn_log_change()', target);
END $$;

REVOKE ALL ON PROCEDURE audit.fn_enable(regclass) FROM PUBLIC;

GRANT USAGE ON SCHEMA audit TO ofm_reader;
GRANT SELECT ON audit.audit_log TO ofm_reader;

-- 009 Model changes reach the runtime without restart (ADR-0001, step 2.1).
-- Every change to a configuration table sends a PostgreSQL notification on
-- the channel 'model_changed', with the table name as payload. The runtime
-- LISTENs on that channel and reloads config.vw_runtime_model.
-- Notifications are delivered only when the transaction commits, so a
-- rolled-back edit causes no reload; identical notifications within one
-- transaction are merged by PostgreSQL.

CREATE FUNCTION config.fn_notify_model_changed()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  PERFORM pg_notify('model_changed', TG_TABLE_NAME);
  RETURN NULL;
END $$;

COMMENT ON FUNCTION config.fn_notify_model_changed() IS
  'Statement trigger: notifies the runtime (channel model_changed) that a configuration table changed.';

-- Attach to every configuration table that exists now.
DO $$
DECLARE t record;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'config' ORDER BY tablename LOOP
    EXECUTE format(
      'CREATE TRIGGER trg_notify_model_changed AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON config.%I
         FOR EACH STATEMENT EXECUTE FUNCTION config.fn_notify_model_changed()', t.tablename);
  END LOOP;
END $$;

-- Configuration tables created by later migrations get the notification
-- together with the audit triggers: CALL audit.fn_enable('config.<table>').
CREATE OR REPLACE PROCEDURE audit.fn_enable(target regclass)
LANGUAGE plpgsql
AS $$
BEGIN
  EXECUTE format(
    'CREATE TRIGGER trg_set_audit_columns BEFORE UPDATE ON %s
       FOR EACH ROW EXECUTE FUNCTION config.fn_set_audit_columns()', target);
  EXECUTE format(
    'CREATE TRIGGER trg_audit_log AFTER INSERT OR UPDATE OR DELETE ON %s
       FOR EACH ROW EXECUTE FUNCTION audit.fn_log_change()', target);
  EXECUTE format(
    'CREATE TRIGGER trg_notify_model_changed AFTER INSERT OR UPDATE OR DELETE OR TRUNCATE ON %s
       FOR EACH STATEMENT EXECUTE FUNCTION config.fn_notify_model_changed()', target);
END $$;

REVOKE ALL ON PROCEDURE audit.fn_enable(regclass) FROM PUBLIC;

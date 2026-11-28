-- 032 Made-up operations history, marked (step R1 follow-up, 2026-11-28).
--
-- "migrate test-history" (step H1) makes up a year of signal values for the
-- trend page only: no machine states, stops, orders or counts, so reports
-- and OEE had nothing to show for those months. "migrate test-operations"
-- (db/examples/demo-test-operations.sql) now makes up months of operations
-- for the demo line, before its first real history, and removes them again
-- with "migrate test-operations-remove". This migration only adds where the
-- made-up periods are recorded, and shows them:
--   1. hist.test_operation_range   each made-up period of a line
--   2. hist.fn_report_summary      also says whether made-up operations lie
--                                  in the period (column test_operations)
--   3. hist.fn_dashboard_period    Grafana's "Period shown" adds
--                                  "· made-up test data" when they do
-- History refers to the model by ID only, without foreign keys (ADR-0030).

-- ---------------------------------------------------------------------------
-- 1. The made-up periods.
-- ---------------------------------------------------------------------------
CREATE TABLE hist.test_operation_range (
  line_id     integer     NOT NULL,
  from_ts     timestamptz NOT NULL,
  to_ts       timestamptz NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  note        text,
  PRIMARY KEY (line_id, from_ts),
  CHECK (to_ts > from_ts)
);
COMMENT ON TABLE hist.test_operation_range IS
  'Periods of made-up operations history of a line (migrate test-operations): states, reasons, orders, counts. Removed with migrate test-operations-remove.';
GRANT SELECT ON hist.test_operation_range TO ofm_reader;

-- ---------------------------------------------------------------------------
-- 2. The report's header: as in migration 031, plus test_operations.
-- ---------------------------------------------------------------------------
DROP FUNCTION hist.fn_report_summary(integer, timestamptz, timestamptz);
CREATE FUNCTION hist.fn_report_summary(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (line_name text, line_path text, time_zone text, oee_target double precision,
               kpi_rule_changed boolean, test_data boolean, has_rule boolean, test_operations boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT l.display_name, e.name || '/' || s.name || '/' || a.name, s.time_zone, l.oee_target,
         EXISTS (SELECT 1 FROM config.line_kpi_rule r WHERE r.line_id = l.id AND r.valid_from > p_from AND r.valid_from < least(p_to, now())),
         EXISTS (SELECT 1 FROM hist.test_data_range t
                 JOIN config.machine_property p ON p.id = t.property_id
                 JOIN config.machine m ON m.id = p.machine_id
                 WHERE m.line_id = l.id AND t.from_ts < p_to AND t.to_ts > p_from),
         EXISTS (SELECT 1 FROM config.line_kpi_rule r WHERE r.line_id = l.id AND r.valid_from < p_to),
         EXISTS (SELECT 1 FROM hist.test_operation_range o WHERE o.line_id = l.id AND o.from_ts < p_to AND o.to_ts > p_from)
  FROM config.line l
  JOIN config.area a ON a.id = l.area_id
  JOIN config.site s ON s.id = a.site_id
  JOIN config.enterprise e ON e.id = s.enterprise_id
  WHERE l.id = p_line_id
$$;
COMMENT ON FUNCTION hist.fn_report_summary(integer, timestamptz, timestamptz) IS
  'The report header of a line and period: names, time zone, OEE target, KPI rule changed, made-up signal values (test_data) or operations (test_operations) present (steps R1, migration 032).';
REVOKE ALL ON FUNCTION hist.fn_report_summary(integer, timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hist.fn_report_summary(integer, timestamptz, timestamptz) TO ofm_screens, ofm_reader;

-- ---------------------------------------------------------------------------
-- 3. Grafana's period: as in migration 022, the label marks made-up periods.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hist.fn_dashboard_period(p_line_id integer, p_shift text, p_order text, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (t0 timestamptz, t1 timestamptz, label text)
LANGUAGE sql STABLE
AS $$
  WITH zone AS (
    SELECT s.time_zone AS tz
    FROM config.line l JOIN config.area a ON a.id = l.area_id JOIN config.site s ON s.id = a.site_id
    WHERE l.id = p_line_id
  ),
  ord AS (                                    -- the chosen order: by ID, or the running (else the last) one
    SELECT o.wo_number, o.sku, o.started_at, o.completed_at
    FROM hist.vw_work_order_interval o
    WHERE o.line_id = p_line_id
      AND (o.work_order_id = CASE WHEN p_order ~ '^[0-9]{1,9}$' THEN p_order::integer END OR p_order = 'current')
    ORDER BY (o.completed_at IS NULL) DESC, o.started_at DESC
    LIMIT 1
  ),
  shift_ AS (
    SELECT to_timestamp(CASE WHEN p_shift ~ '^[0-9]{1,15}-[0-9]{1,15}$' THEN split_part(p_shift, '-', 1)::bigint END / 1000.0) AS t0,
           to_timestamp(CASE WHEN p_shift ~ '^[0-9]{1,15}-[0-9]{1,15}$' THEN split_part(p_shift, '-', 2)::bigint END / 1000.0) AS t1
    WHERE p_shift ~ '^[0-9]{1,15}-[0-9]{1,15}$'          -- the CASEs keep PostgreSQL from converting other text
  ),
  chosen AS (
    SELECT o.started_at AS t0, coalesce(o.completed_at, 'infinity') AS t1,
           'Order ' || o.wo_number || ' (' || o.sku || ')' || CASE WHEN o.completed_at IS NULL THEN ', running' ELSE '' END AS what, 1 AS pref
    FROM ord o
    UNION ALL
    SELECT s.t0, s.t1, 'Shift ' || coalesce((SELECT w.name FROM config.fn_line_shifts(p_line_id, s.t0, s.t1) w WHERE w.starts_at = s.t0 LIMIT 1), ''), 2
    FROM shift_ s
    UNION ALL
    SELECT p_from, p_to, 'Time picker', 3
  ),
  best AS (SELECT * FROM chosen ORDER BY pref LIMIT 1),
  cut AS (SELECT b.what, b.t0, greatest(b.t0, least(b.t1, hist.fn_counted_until())) AS t1, b.t1 AS t1_planned FROM best b)
  SELECT c.t0, c.t1,
         c.what || ' · ' || to_char(c.t0 AT TIME ZONE z.tz, 'Dy DD/MM HH24:MI') || ' – ' ||
         CASE WHEN c.t1_planned > now() THEN 'now'
              WHEN (c.t1 AT TIME ZONE z.tz)::date = (c.t0 AT TIME ZONE z.tz)::date THEN to_char(c.t1 AT TIME ZONE z.tz, 'HH24:MI')
              ELSE to_char(c.t1 AT TIME ZONE z.tz, 'Dy DD/MM HH24:MI') END ||
         CASE WHEN EXISTS (SELECT 1 FROM hist.test_operation_range r WHERE r.line_id = p_line_id AND r.from_ts < c.t1 AND r.to_ts > c.t0)
              THEN ' · made-up test data' ELSE '' END
  FROM cut c, zone z
$$;
COMMENT ON FUNCTION hist.fn_dashboard_period(integer, text, text, timestamptz, timestamptz) IS
  'The Line OEE dashboard''s period: a work order (an ID, or current = the running one), else a shift (''<start ms>-<end ms>''), else the time picker; ends at the last counted minute; label in the site''s local time, marked when made-up operations lie in it (migration 032).';

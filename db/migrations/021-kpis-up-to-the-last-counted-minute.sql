-- 021 KPIs up to the last counted minute (step 3a.8, found on the laptop
-- 2026-11-10).
-- Units are written per minute (ADR-0026): the runtime books a minute's
-- units a few seconds after the minute ends. Running time, from the state
-- events, is known to the second. A KPI period ending "now" therefore had
-- the running time of the current minute without its units, so a period
-- that had just begun showed a far too low performance (an order 3 minutes
-- old: 38 % instead of about 95 %); over a day the missing minute hardly
-- shows. The live KPIs and the dashboard now end their periods at the last
-- minute whose units are written: the start of the current minute, or of
-- the one before during the first 10 seconds of a minute. Periods in the
-- past are unchanged.

-- When "now" is the end of a period, the KPIs end here.
CREATE FUNCTION hist.fn_counted_until()
RETURNS timestamptz
LANGUAGE sql STABLE
AS $$ SELECT date_trunc('minute', now() - interval '10 seconds') $$;
COMMENT ON FUNCTION hist.fn_counted_until() IS
  'The end of the last minute whose units the runtime has written (ADR-0026): live KPIs end here instead of at now (migration 021).';

-- As migration 017, but every period ends at hist.fn_counted_until().
CREATE OR REPLACE FUNCTION hist.fn_live_line_kpi()
RETURNS TABLE (line_id integer, line_topic text, period text, work_order_id integer, wo_number text,
               period_start timestamptz, period_end timestamptz,
               oee double precision, availability double precision, performance double precision, quality double precision,
               ge double precision, good double precision, reject double precision,
               running_s double precision, downtime_h double precision, unaccounted_s double precision,
               kpi_rule_id integer, performance_over_100 boolean)
LANGUAGE sql STABLE
SET jit = off
AS $$
WITH lines AS (
  SELECT l.id, concat_ws('/', e.name, s.name, a.name, l.name) AS topic, s.time_zone AS tz
  FROM config.line l
  JOIN config.area a ON a.id = l.area_id AND a.retired_at IS NULL
  JOIN config.site s ON s.id = a.site_id AND s.retired_at IS NULL
  JOIN config.enterprise e ON e.id = s.enterprise_id AND e.retired_at IS NULL
  WHERE l.retired_at IS NULL
    AND EXISTS (SELECT 1 FROM config.line_kpi_rule r WHERE r.line_id = l.id AND r.valid_from <= now())
),
periods AS (
  SELECT id, topic, 'hour' AS period, NULL::integer AS wo_id, NULL::text AS wo_number,
         date_trunc('hour', now() AT TIME ZONE tz) AT TIME ZONE tz AS s FROM lines
  UNION ALL
  SELECT id, topic, 'day', NULL, NULL, date_trunc('day', now() AT TIME ZONE tz) AT TIME ZONE tz FROM lines
  UNION ALL
  SELECT lines.id, lines.topic, 'order', w.work_order_id, w.wo_number, w.started_at
  FROM lines JOIN hist.vw_line_work_order w ON w.line_id = lines.id AND w.active
)
SELECT p.id, p.topic, p.period, p.wo_id, p.wo_number, k.period_start, k.period_end,
       k.oee, k.availability, k.performance, k.quality, k.ge, k.good, k.reject,
       k.running_s, k.downtime_h, k.unaccounted_s, k.kpi_rule_id, k.performance_over_100
FROM periods p CROSS JOIN LATERAL hist.fn_line_kpi(p.id, p.s, hist.fn_counted_until()) k
$$;

-- As migration 019, but a period reaching past the last counted minute ends
-- there (it was IMMUTABLE; it now depends on the time, so STABLE).
CREATE OR REPLACE FUNCTION hist.fn_dashboard_period(p_shift text, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (t0 timestamptz, t1 timestamptz)
LANGUAGE sql STABLE
AS $$
  SELECT x.t0, greatest(x.t0, least(x.t1, hist.fn_counted_until()))
  FROM (SELECT CASE WHEN p_shift ~ '^[0-9]+-[0-9]+$' THEN to_timestamp(split_part(p_shift, '-', 1)::bigint / 1000.0) ELSE p_from END AS t0,
               CASE WHEN p_shift ~ '^[0-9]+-[0-9]+$' THEN to_timestamp(split_part(p_shift, '-', 2)::bigint / 1000.0) ELSE p_to END AS t1) x
$$;

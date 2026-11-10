-- 020 Line view status (step 3a.8, found on the laptop 2026-11-09).
-- Outside the line's schedule nothing counts towards the KPIs (ADR-0008),
-- so the line view showed an order started at 22:08 as "0 of 180 good"
-- while the line made cartons. Two things the line view needs besides the
-- KPIs, read every 10 s through one more function for the role
-- ofm_screens:
-- - whether the line is inside its schedule now, and when it next is;
-- - the running order's progress: every good unit counted since it
--   started, scheduled or not (as on the floor), not only the KPI's.

CREATE FUNCTION hist.fn_screen_line_status()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
WITH lines AS (
  SELECT l.id
  FROM config.line l
  CROSS JOIN LATERAL config.fn_line_kpi_rule(l.id, now()) r
  WHERE l.retired_at IS NULL AND r.id IS NOT NULL
)
SELECT coalesce(jsonb_object_agg(l.id, jsonb_build_object(
  'scheduled', EXISTS (SELECT 1 FROM config.fn_line_schedule(l.id, now(), now() + interval '1 second')),
  'nextScheduledMs', (SELECT (extract(epoch FROM min(s.starts_at)) * 1000)::bigint
                      FROM config.fn_line_schedule(l.id, now(), now() + interval '8 days') s WHERE s.starts_at > now()),
  'order', (SELECT jsonb_build_object('workOrderId', w.work_order_id,
                     'good', coalesce((SELECT sum(c.good) FROM hist.vw_line_count c
                                       WHERE c.line_id = l.id AND c.ts >= date_trunc('minute', w.started_at)), 0))
            FROM hist.vw_line_work_order w WHERE w.line_id = l.id AND w.active))), '{}'::jsonb)
FROM lines l
$$;
COMMENT ON FUNCTION hist.fn_screen_line_status() IS
  'Per line (line view, ADR-0027): inside its schedule now, the next scheduled start, and the running order''s good units since it started (scheduled or not).';
REVOKE ALL ON FUNCTION hist.fn_screen_line_status() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hist.fn_screen_line_status() TO ofm_screens;

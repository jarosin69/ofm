-- 027 Planned quantity reached (step 3a.8 follow-up, 2026-11-16). When the
-- running order's good units reach its planned quantity, the line view tells
-- the operator so and asks to complete the order. Nothing is completed
-- automatically, and the KPIs do not change: until Complete is pressed, a
-- stopped line still has an order and its stop still needs a reason
-- (ADR-0009, ADR-0010 amendment of 2026-11-16).
-- hist.fn_screen_line_status (migration 020) also gives, per line, the
-- start of the minute in which the order's good units reached its planned
-- quantity (reachedMs; null before), and the planned quantity.

CREATE OR REPLACE FUNCTION hist.fn_screen_line_status()
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
  'order', (SELECT jsonb_build_object('workOrderId', w.work_order_id, 'plannedQty', w.planned_qty,
                                      'good', coalesce(g.good, 0), 'reachedMs', g.reached_ms)
            FROM hist.vw_line_work_order w
            -- good units per minute since the start, and the first minute where their running total reaches the plan
            CROSS JOIN LATERAL (
              SELECT sum(c.good) AS good,
                     (extract(epoch FROM min(c.ts) FILTER (WHERE c.total >= w.planned_qty)) * 1000)::bigint AS reached_ms
              FROM (SELECT c.ts, c.good, sum(c.good) OVER (ORDER BY c.ts) AS total
                    FROM hist.vw_line_count c
                    WHERE c.line_id = l.id AND c.ts >= date_trunc('minute', w.started_at)) c
            ) g
            WHERE w.line_id = l.id AND w.active))), '{}'::jsonb)
FROM lines l
$$;
COMMENT ON FUNCTION hist.fn_screen_line_status() IS
  'Per line (line view, ADR-0027): inside its schedule now, the next scheduled start, and the running order''s good units since it started (scheduled or not), its planned quantity and the minute the plan was reached (migration 027).';

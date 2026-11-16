-- 029 Live order progress on the line view (2026-11-17).
--
-- The line view took the running order's good units from the per-minute
-- counts, which are written once a minute is over: the progress, and the
-- note that the planned quantity is reached (migration 027), came up to
-- about a minute and a half late. Now hist.fn_screen_line_status also gives
-- the topic of the order's good counter, and that counter's reading at the
-- end of its newest stored minute (counterValue) with the minute
-- (counterMinuteMs). The line view adds the live counter's movement since
-- that reading to the stored good units: good units to the second, with no
-- gap or double count. A counter reset, or no live value, falls back to the
-- stored good units. The KPIs stay per minute (ADR-0008).

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
                                      'good', coalesce(g.good, 0), 'reachedMs', g.reached_ms,
                                      'goodTopic', (SELECT w.line_topic || '/' || m.name || '/' || p.name
                                                    FROM config.machine_property p JOIN config.machine m ON m.id = p.machine_id
                                                    WHERE p.id = w.good_property_id),
                                      'counterValue', lc.last_value,
                                      'counterMinuteMs', (extract(epoch FROM lc.ts) * 1000)::bigint)
            FROM hist.vw_line_work_order w
            -- good units per minute since the start, and the first minute where their running total reaches the plan
            CROSS JOIN LATERAL (
              SELECT sum(c.good) AS good,
                     (extract(epoch FROM min(c.ts) FILTER (WHERE c.total >= w.planned_qty)) * 1000)::bigint AS reached_ms
              FROM (SELECT c.ts, c.good, sum(c.good) OVER (ORDER BY c.ts) AS total
                    FROM hist.vw_line_count c
                    WHERE c.line_id = l.id AND c.ts >= date_trunc('minute', w.started_at)) c
            ) g
            -- the good counter's newest stored minute: the live counter is read against it
            LEFT JOIN LATERAL (
              SELECT pc.ts, pc.last_value FROM hist.production_count pc
              WHERE pc.property_id = w.good_property_id ORDER BY pc.ts DESC LIMIT 1
            ) lc ON true
            WHERE w.line_id = l.id AND w.active))), '{}'::jsonb)
FROM lines l
$$;
COMMENT ON FUNCTION hist.fn_screen_line_status() IS
  'Per line (line view, ADR-0027): inside its schedule now, the next scheduled start, and the running order''s good units since it started (scheduled or not), its planned quantity, the minute the plan was reached (migration 027), and its good counter''s topic and newest stored reading, for live progress (migration 029).';

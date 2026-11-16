-- 028 A stop is split where an order starts or ends (fix, 2026-11-17).
--
-- hist.fn_line_stops (migration 017) cut the constraint's stops only at
-- state changes, the period's start and KPI rules, and decided "waiting for
-- order" at the start of each piece. A stop that began while an order was
-- running stayed "no reason yet" after the order was completed, so the
-- time after Complete counted as not accounted for and lowered OEE; and a
-- stop that began without an order stayed "waiting for order" after the
-- next order started, hiding its changeover. Now the stops are also cut
-- where an order starts and where it is completed: before Complete the stop
-- still needs a reason (ADR-0010 amendment of 2026-11-16), after it the
-- line waits for an order (Pos 7), and after the next start the changeover
-- window applies (Pos 6). Everything else is as in migration 017; KPIs are
-- calculated at read time (ADR-0008), so past figures are corrected at once.

CREATE OR REPLACE FUNCTION hist.fn_line_stops(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (
  slice_start timestamptz, slice_end timestamptz, duration_s double precision,
  machine_id integer, state text, event_ts timestamptz, cause text,
  reason_id integer, reason_code text, reason_name text, loss_category_id integer,
  cause_machine_id integer, cause_machine_name text, cause_state text,
  assigned_by text, comment text)
LANGUAGE sql STABLE
SET enable_nestloop = off        -- the planner cannot estimate these steps; matching joins are always right here
SET jit = off                    -- compiling this query would take longer than running it
AS $$
WITH RECURSIVE
lim AS (SELECT p_from AS t0, greatest(p_from, least(p_to, now())) AS t1),
mach AS (SELECT id FROM config.machine WHERE line_id = p_line_id),
f AS (
  SELECT r.from_machine_id AS a, r.to_machine_id AS b
  FROM config.asset_relationship r
  WHERE r.relation_type = 'feeds' AND r.from_machine_id IN (SELECT id FROM mach) AND r.to_machine_id IN (SELECT id FROM mach)
),
chain (machine_id, pos) AS (                         -- position along the flow; empty if not one chain
  SELECT a, 1 FROM f
  WHERE NOT EXISTS (SELECT 1 FROM config.vw_line_flow_problem p WHERE p.line_id = p_line_id)
    AND NOT EXISTS (SELECT 1 FROM f f2 WHERE f2.b = f.a)
  UNION ALL
  SELECT f.b, c.pos + 1 FROM chain c JOIN f ON f.a = c.machine_id WHERE c.pos < 500
),
rules AS (
  SELECT r.id, r.constraint_machine_id AS cm, r.order_required, r.valid_from,
         coalesce(lead(r.valid_from) OVER (ORDER BY r.valid_from), 'infinity'::timestamptz) AS valid_to
  FROM config.line_kpi_rule r WHERE r.line_id = p_line_id
),
ev AS (                                              -- events in range, and each machine's state at its start
  SELECT e.machine_id, greatest(e.ts, lim.t0) AS t, e.ts AS event_ts, e.state_id FROM hist.machine_state_event e, lim
  WHERE e.machine_id IN (SELECT id FROM mach) AND e.ts > lim.t0 AND e.ts < lim.t1
  UNION ALL
  SELECT * FROM (
    SELECT DISTINCT ON (e.machine_id) e.machine_id, lim.t0, e.ts, e.state_id FROM hist.machine_state_event e, lim
    WHERE e.machine_id IN (SELECT id FROM mach) AND e.ts <= lim.t0
    ORDER BY e.machine_id, e.ts DESC) first_state
),
orders AS (                                          -- the line's orders touching the period
  SELECT o.started_at, coalesce(o.completed_at, 'infinity'::timestamptz) AS ended
  FROM hist.vw_work_order_interval o, lim
  WHERE o.line_id = p_line_id AND o.started_at < lim.t1 AND coalesce(o.completed_at, 'infinity'::timestamptz) > lim.t0
),
cut AS (                                             -- also where an order starts or ends (migration 028)
  SELECT DISTINCT x.t FROM lim, (SELECT t FROM ev UNION ALL SELECT t0 FROM lim UNION ALL SELECT valid_from FROM rules
                                 UNION ALL SELECT started_at FROM orders UNION ALL SELECT ended FROM orders) x
  WHERE x.t >= lim.t0 AND x.t < lim.t1
),
sl AS (SELECT c.t AS s, coalesce(lead(c.t) OVER (ORDER BY c.t), (SELECT t1 FROM lim)) AS e FROM cut c),
marks AS (                                           -- every slice start for every machine, and the events
  SELECT m.id AS machine_id, sl.s AS t, 1 AS kind, NULL::integer AS state_id, NULL::timestamptz AS event_ts FROM sl CROSS JOIN mach m
  UNION ALL
  SELECT ev.machine_id, ev.t, 0, ev.state_id, ev.event_ts FROM ev
),
carried AS (                                         -- each machine's state carried forward to every slice
  SELECT g.machine_id, g.t AS s,
         first_value(g.state_id) OVER (PARTITION BY g.machine_id, g.grp ORDER BY g.t, g.kind) AS state_id,
         first_value(g.event_ts) OVER (PARTITION BY g.machine_id, g.grp ORDER BY g.t, g.kind) AS event_ts,
         g.kind
  FROM (SELECT mk.*, count(mk.state_id) OVER (PARTITION BY mk.machine_id ORDER BY mk.t, mk.kind) AS grp FROM marks mk) g
),
at_slice AS (SELECT c.machine_id, c.s, c.state_id, c.event_ts, ch.pos FROM carried c LEFT JOIN chain ch ON ch.machine_id = c.machine_id
             WHERE c.kind = 1 AND c.state_id IS NOT NULL),
own AS (                                             -- the constraint's state in each slice; running dropped
  SELECT sl.s, sl.e, r.cm, r.order_required, a.state_id, a.event_ts, a.pos AS cpos
  FROM sl
  JOIN rules r ON r.valid_from <= sl.s AND sl.s < r.valid_to
  JOIN at_slice a ON a.machine_id = r.cm AND a.s = sl.s
  WHERE a.state_id <> 1 AND sl.e > sl.s
),
hits AS (                                            -- the nearest machine the walk stops at
  SELECT o.s,
    (array_agg(jsonb_build_object('machine_id', a.machine_id, 'state_id', a.state_id, 'event_ts', a.event_ts) ORDER BY a.pos DESC)
       FILTER (WHERE o.state_id = 4 AND a.pos < o.cpos AND a.state_id <> 4))[1] AS up,
    (array_agg(jsonb_build_object('machine_id', a.machine_id, 'state_id', a.state_id, 'event_ts', a.event_ts) ORDER BY a.pos)
       FILTER (WHERE o.state_id = 3 AND a.pos > o.cpos AND a.state_id <> 3))[1] AS down
  FROM own o JOIN at_slice a ON a.s = o.s
  WHERE o.state_id IN (3, 4) AND o.cpos IS NOT NULL
  GROUP BY o.s
),
walked AS (SELECT o.*, coalesce(h.up, h.down) AS hit FROM own o LEFT JOIN hits h ON h.s = o.s),
withreason AS (
  SELECT w.*, er.reason_id AS own_reason,
         (SELECT sr.reason_id FROM hist.state_reason sr
          WHERE w.hit IS NOT NULL AND sr.machine_id = (w.hit->>'machine_id')::int AND sr.event_ts = (w.hit->>'event_ts')::timestamptz
          ORDER BY sr.assigned_at DESC LIMIT 1) AS cause_reason
  FROM walked w
  LEFT JOIN LATERAL (SELECT sr.reason_id FROM hist.state_reason sr WHERE sr.machine_id = w.cm AND sr.event_ts = w.event_ts
                     ORDER BY sr.assigned_at DESC LIMIT 1) er ON true
),
classified AS (
  SELECT w.s, w.e, w.cm, w.state_id, w.event_ts, w.hit,
         CASE
           WHEN w.state_id = 9 THEN 'unknown'
           WHEN w.own_reason IS NOT NULL THEN 'reason'
           WHEN w.state_id IN (3, 4) AND (w.hit->>'state_id')::int IN (2, 5, 6, 7, 8, 9) THEN 'attributed'
           WHEN w.state_id IN (3, 4) AND w.cpos IS NOT NULL THEN 'flow'
           WHEN w.order_required AND NOT EXISTS (SELECT 1 FROM orders o WHERE o.started_at <= w.s AND o.ended > w.s) THEN 'waiting_for_order'
           ELSE 'none'
         END AS cause,
         w.own_reason, w.cause_reason
  FROM withreason w
),
detailed AS (
  SELECT c.s, c.e, c.cm, c.state_id, c.event_ts, c.cause,
         CASE c.cause WHEN 'reason' THEN c.own_reason
                      WHEN 'attributed' THEN c.cause_reason
                      WHEN 'waiting_for_order' THEN (SELECT id FROM config.reason WHERE code = 'waiting_for_order' AND is_system)
         END AS reason_id,
         CASE WHEN c.cause = 'attributed' THEN (c.hit->>'machine_id')::int END AS cause_machine_id,
         CASE WHEN c.cause = 'attributed' THEN (c.hit->>'state_id')::int END AS cause_state_id,
         CASE WHEN c.cause = 'attributed' THEN (c.hit->>'event_ts')::timestamptz END AS cause_event_ts
  FROM classified c
),
described AS (
  SELECT d.*,
         CASE d.cause WHEN 'reason' THEN er.assigned_by WHEN 'attributed' THEN er.assigned_by WHEN 'waiting_for_order' THEN 'ofm' END AS assigned_by,
         CASE WHEN d.cause IN ('reason', 'attributed') THEN er.comment END AS comment
  FROM detailed d
  LEFT JOIN LATERAL (SELECT sr.assigned_by, sr.comment FROM hist.state_reason sr
                     WHERE d.cause IN ('reason', 'attributed')
                       AND sr.machine_id = CASE d.cause WHEN 'reason' THEN d.cm ELSE d.cause_machine_id END
                       AND sr.event_ts = CASE d.cause WHEN 'reason' THEN d.event_ts ELSE d.cause_event_ts END
                     ORDER BY sr.assigned_at DESC LIMIT 1) er ON true
),
grouped AS (                                         -- join neighbouring slices that say the same
  SELECT d.*, sum(CASE WHEN prev_same THEN 0 ELSE 1 END) OVER (ORDER BY d.s) AS grp
  FROM (
    SELECT d.*,
           coalesce(lag(d.e) OVER w = d.s
           AND (lag(d.cm) OVER w, lag(d.event_ts) OVER w, lag(d.cause) OVER w, lag(d.reason_id) OVER w,
                lag(d.cause_machine_id) OVER w, lag(d.cause_state_id) OVER w, lag(d.assigned_by) OVER w, lag(d.comment) OVER w)
               IS NOT DISTINCT FROM (d.cm, d.event_ts, d.cause, d.reason_id, d.cause_machine_id, d.cause_state_id, d.assigned_by, d.comment), false)
           AS prev_same
    FROM described d WINDOW w AS (ORDER BY d.s)) d
)
SELECT min(g.s), max(g.e), extract(epoch FROM max(g.e) - min(g.s))::double precision,
       g.cm, ms.name, g.event_ts, g.cause,
       g.reason_id, r.code, r.display_name, r.loss_category_id,
       g.cause_machine_id, cmach.name, cs.name,
       g.assigned_by, g.comment
FROM grouped g
JOIN config.machine_state ms ON ms.id = g.state_id
LEFT JOIN config.reason r ON r.id = g.reason_id
LEFT JOIN config.machine cmach ON cmach.id = g.cause_machine_id
LEFT JOIN config.machine_state cs ON cs.id = g.cause_state_id
GROUP BY g.grp, g.cm, ms.name, g.event_ts, g.cause, g.reason_id, r.code, r.display_name, r.loss_category_id,
         g.cause_machine_id, cmach.name, cs.name, g.assigned_by, g.comment
ORDER BY min(g.s)
$$;

COMMENT ON FUNCTION hist.fn_line_stops(integer, timestamptz, timestamptz) IS
  'The line''s stop list (ADR-0009, ADR-0024): its constraint machine''s non-running time in [from, to), cut at state changes and where orders start or end (migration 028), each slice with cause (unknown, reason, attributed, flow, waiting_for_order, none), reason and position, and the machine it is charged to.';

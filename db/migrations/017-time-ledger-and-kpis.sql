-- 017 Time ledger and KPIs (Phase 3a, step 3a.7; ADR-0008, ADR-0009).
--
-- 1. hist.fn_time_ledger         every slice of a line's time in a period,
--                                with its waterfall position (ADR-0009)
-- 2. hist.fn_line_kpi            the line's waterfall and KPIs for a period
--                                (ADR-0008): positions 1-13 and unaccounted,
--                                OEE = A x P x Q, GE, LU, TEEP, downtime
--    hist.fn_line_kpi_series     the same per hour, day, week or month,
--                                bounded in the site's local time
-- 3. hist.fn_machine_reliability per machine: running time, breakdowns,
--                                MTBF, MTTR
-- 4. hist.fn_live_line_kpi       the current hour, today and the running
--                                order of every line, for the runtime's
--                                .../kpi/{hour|day|order} topics
--
-- Everything is calculated at read time from state events, reasons, the
-- schedule, work orders and counts (ADR-0008 decision 7): a late reason or
-- a schedule correction changes every result, with no update anywhere.
-- Times are in seconds; periods [from, to) are cut at now.
-- Speed: the functions run with JIT compilation (PostgreSQL turning a large
-- query into machine code first) switched off, because for these queries
-- compiling takes seconds and running them a fraction of that. Measured on
-- a simulated busy week (25 000 state events): KPIs of a day 0.2 s, of a
-- week 0.7 s, a day by hour 1.6 s.

-- ---------------------------------------------------------------------------
-- 0. The line's stop list, same results as migration 016, faster: each
-- machine's state is carried forward along the slices in one sorted pass
-- instead of being looked up slice by slice (16 s -> about 0.1 s a day on a
-- simulated busy line). The rules are unchanged; see migration 016.
-- ---------------------------------------------------------------------------
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
cut AS (
  SELECT DISTINCT x.t FROM lim, (SELECT t FROM ev UNION ALL SELECT t0 FROM lim UNION ALL SELECT valid_from FROM rules) x
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
orders AS (SELECT o.started_at, coalesce(o.completed_at, 'infinity'::timestamptz) AS ended FROM hist.vw_work_order_interval o WHERE o.line_id = p_line_id),
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

-- ---------------------------------------------------------------------------
-- 1. The time ledger (ADR-0009 decisions 2 and 5). The period is cut wherever
-- anything that matters changes: a schedule window, a changeover window, the
-- constraint machine's state, a slice of the stop list (hist.fn_line_stops),
-- a KPI rule. Each slice gets, first match wins:
--   no_activity      outside every schedule window              -> 2
--   unknown          the constraint's state unknown, or none     -> 90
--   running          the constraint running                      -> NULL
--                    (split into 10, 11, 13 by counts: fn_line_kpi)
--   reason / attributed / waiting_for_order                       -> the reason's position
--   flow             starved or blocked, neighbours running      -> 12
--   changeover       inside a changeover window (ADR-0010)       -> 6
--   planned_window   inside a maintenance, cleaning or other planned
--                    window of the schedule                      -> 4, 5, 7
--   minor_stop       a stop shorter than the KPI rule's threshold -> 12
--                    (a stop = the constraint's whole continuous
--                    non-running period, whatever states it passed)
--   unaccounted      anything else, until someone codes it       -> 90
-- Scheduled time is every schedule window together (production and planned).
-- ---------------------------------------------------------------------------
CREATE FUNCTION hist.fn_time_ledger(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (
  slice_start timestamptz, slice_end timestamptz, duration_s double precision,
  loss_category_id integer, rule text, state text,
  reason_code text, reason_name text, cause_machine_name text,
  stop_s double precision, kpi_rule_id integer)
LANGUAGE sql STABLE
SET enable_nestloop = off        -- as in fn_line_stops
SET jit = off
AS $$
WITH
lim AS (
  SELECT p_from AS t0, greatest(p_from, least(p_to, now())) AS t1,
         make_interval(secs => coalesce((SELECT max(minor_stop_threshold_s) FROM config.line_kpi_rule WHERE line_id = p_line_id), 0) + 1) AS ext
),
win AS (SELECT w.kind, w.starts_at, w.ends_at FROM lim, config.fn_line_schedule(p_line_id, lim.t0, lim.t1) w WHERE w.ends_at > w.starts_at),
cw AS (                                              -- changeover windows: start -> first changeover_end, or completion
  SELECT o.started_at AS s, coalesce(o.changeover_end_at, o.completed_at, 'infinity'::timestamptz) AS e
  FROM hist.vw_work_order_interval o, lim
  WHERE o.line_id = p_line_id AND o.started_at < lim.t1
    AND coalesce(o.changeover_end_at, o.completed_at, 'infinity'::timestamptz) > lim.t0
),
rules AS (
  SELECT r.id, r.constraint_machine_id, r.minor_stop_threshold_s, r.valid_from,
         coalesce(lead(r.valid_from) OVER (ORDER BY r.valid_from), 'infinity'::timestamptz) AS valid_to
  FROM config.line_kpi_rule r WHERE r.line_id = p_line_id
),
stops_wide AS (                                      -- the stop list, widened so that a stop's whole length is seen
  SELECT s.* FROM lim, hist.fn_line_stops(p_line_id, lim.t0 - lim.ext, least(p_to + lim.ext, now())) s
),
stops AS (
  SELECT g.*, extract(epoch FROM max(g.slice_end) OVER (PARTITION BY g.stop_no) - min(g.slice_start) OVER (PARTITION BY g.stop_no)) AS stop_len
  FROM (SELECT j.*, sum(CASE WHEN j.joins THEN 0 ELSE 1 END) OVER (ORDER BY j.slice_start) AS stop_no
        FROM (SELECT s.*, coalesce(lag(s.slice_end) OVER (ORDER BY s.slice_start) = s.slice_start, false) AS joins
              FROM stops_wide s) j) g
),
cons_ev AS (                                         -- the constraint machines' state events in range, and before it
  SELECT e.machine_id, e.ts, e.state_id FROM hist.machine_state_event e, lim
  WHERE e.machine_id IN (SELECT constraint_machine_id FROM rules) AND e.ts > lim.t0 AND e.ts < lim.t1
  UNION ALL
  SELECT * FROM (
    SELECT DISTINCT ON (e.machine_id) e.machine_id, e.ts, e.state_id FROM hist.machine_state_event e, lim
    WHERE e.machine_id IN (SELECT constraint_machine_id FROM rules) AND e.ts <= lim.t0
    ORDER BY e.machine_id, e.ts DESC) before_range
),
civ AS (
  SELECT c.machine_id, c.state_id, greatest(c.ts, lim.t0) AS s,
         least(coalesce(lead(c.ts) OVER (PARTITION BY c.machine_id ORDER BY c.ts), lim.t1), lim.t1) AS e
  FROM cons_ev c, lim
),
cut AS (
  SELECT DISTINCT x.t FROM lim, (
    SELECT t0 AS t FROM lim
    UNION ALL SELECT starts_at FROM win UNION ALL SELECT ends_at FROM win
    UNION ALL SELECT s FROM cw UNION ALL SELECT e FROM cw
    UNION ALL SELECT slice_start FROM stops UNION ALL SELECT slice_end FROM stops
    UNION ALL SELECT s FROM civ UNION ALL SELECT e FROM civ
    UNION ALL SELECT valid_from FROM rules) x
  WHERE x.t >= lim.t0 AND x.t < lim.t1
),
piece AS (SELECT c.t AS s, coalesce(lead(c.t) OVER (ORDER BY c.t), (SELECT t1 FROM lim)) AS e FROM cut c),
stop_at AS (                                         -- the stop slice each piece lies in, carried forward
  SELECT c.s, c.stop_row FROM (
    SELECT g.s, g.kind, first_value(g.stop_row) OVER (PARTITION BY g.grp ORDER BY g.t, g.kind) AS stop_row
    FROM (SELECT mk.*, count(mk.stop_row) OVER (ORDER BY mk.t, mk.kind) AS grp
          FROM (SELECT p.s AS t, 1 AS kind, p.s, NULL::jsonb AS stop_row FROM piece p
                UNION ALL
                SELECT st.slice_start, 0, NULL, to_jsonb(st) FROM stops st) mk) g) c
  WHERE c.kind = 1                                   -- after carrying, not before
),
cons_at AS (                                         -- each constraint machine's state at each piece, carried forward
  SELECT c.machine_id, c.s, c.state_id, c.e_civ FROM (
    SELECT g.machine_id, g.s, g.kind,
           first_value(g.state_id) OVER (PARTITION BY g.machine_id, g.grp ORDER BY g.t, g.kind) AS state_id,
           first_value(g.e_civ) OVER (PARTITION BY g.machine_id, g.grp ORDER BY g.t, g.kind) AS e_civ
    FROM (SELECT mk.*, count(mk.state_id) OVER (PARTITION BY mk.machine_id ORDER BY mk.t, mk.kind) AS grp
          FROM (SELECT cm.constraint_machine_id AS machine_id, p.s AS t, 1 AS kind, p.s, NULL::integer AS state_id, NULL::timestamptz AS e_civ
                FROM piece p CROSS JOIN (SELECT DISTINCT constraint_machine_id FROM rules) cm
                UNION ALL
                SELECT civ.machine_id, civ.s, 0, NULL, civ.state_id, civ.e FROM civ) mk) g) c
  WHERE c.kind = 1                                   -- after carrying, not before
),
facts AS (
  SELECT p.s, p.e, r.id AS rule_id, r.minor_stop_threshold_s AS threshold,
         EXISTS (SELECT 1 FROM win WHERE win.starts_at <= p.s AND p.s < win.ends_at) AS scheduled,
         (SELECT min(CASE win.kind WHEN 'maintenance' THEN 4 WHEN 'cleaning' THEN 5 WHEN 'other_planned' THEN 7 END)
          FROM win WHERE win.kind <> 'production' AND win.starts_at <= p.s AND p.s < win.ends_at) AS planned_pos,
         EXISTS (SELECT 1 FROM cw WHERE cw.s <= p.s AND p.s < cw.e) AS in_changeover,
         CASE WHEN ca.e_civ > p.s THEN ca.state_id END AS cons_state,
         st.stop_row->>'state' AS state, st.stop_row->>'cause' AS cause, (st.stop_row->>'loss_category_id')::int AS reason_pos,
         st.stop_row->>'reason_code' AS reason_code, st.stop_row->>'reason_name' AS reason_name,
         st.stop_row->>'cause_machine_name' AS cause_machine_name, (st.stop_row->>'stop_len')::double precision AS stop_len
  FROM piece p
  LEFT JOIN rules r ON r.valid_from <= p.s AND p.s < r.valid_to
  LEFT JOIN cons_at ca ON ca.machine_id = r.constraint_machine_id AND ca.s = p.s
  LEFT JOIN stop_at sa ON sa.s = p.s
  LEFT JOIN LATERAL (SELECT sa.stop_row WHERE (sa.stop_row->>'slice_end')::timestamptz > p.s) st ON true
  WHERE p.e > p.s
),
classified AS (
  SELECT f.*,
    CASE
      WHEN NOT f.scheduled THEN 'no_activity'
      WHEN f.rule_id IS NULL OR f.cons_state IS NULL OR f.cons_state = 9 THEN 'unknown'
      WHEN f.cons_state = 1 THEN 'running'
      WHEN f.cause IN ('reason', 'attributed', 'waiting_for_order') AND f.reason_pos IS NOT NULL THEN f.cause
      WHEN f.cause = 'flow' THEN 'flow'
      WHEN f.in_changeover THEN 'changeover'
      WHEN f.planned_pos IS NOT NULL THEN 'planned_window'
      WHEN f.stop_len IS NOT NULL AND f.stop_len < f.threshold THEN 'minor_stop'
      ELSE 'unaccounted'
    END AS rule_name
  FROM facts f
),
positioned AS (
  SELECT c.*,
    CASE c.rule_name
      WHEN 'no_activity' THEN 2 WHEN 'unknown' THEN 90 WHEN 'running' THEN NULL
      WHEN 'reason' THEN c.reason_pos WHEN 'attributed' THEN c.reason_pos WHEN 'waiting_for_order' THEN c.reason_pos
      WHEN 'flow' THEN 12 WHEN 'changeover' THEN 6 WHEN 'planned_window' THEN c.planned_pos
      WHEN 'minor_stop' THEN 12 ELSE 90
    END AS pos,
    CASE WHEN c.rule_name IN ('reason', 'attributed', 'waiting_for_order') THEN c.reason_code END AS r_code,
    CASE WHEN c.rule_name IN ('reason', 'attributed', 'waiting_for_order') THEN c.reason_name END AS r_name,
    CASE WHEN c.rule_name IN ('reason', 'attributed', 'waiting_for_order', 'changeover', 'planned_window', 'minor_stop', 'unaccounted')
         THEN c.cause_machine_name END AS charged_to,
    CASE WHEN c.rule_name NOT IN ('no_activity', 'unknown', 'running') THEN c.stop_len END AS stop_seconds,
    CASE WHEN c.rule_name <> 'no_activity' THEN (SELECT name FROM config.machine_state WHERE id = c.cons_state) END AS state_name
  FROM classified c
),
grouped AS (                                         -- join neighbouring pieces that say the same
  SELECT p.*, sum(CASE WHEN same THEN 0 ELSE 1 END) OVER (ORDER BY p.s) AS grp
  FROM (SELECT p.*,
               lag(p.e) OVER w = p.s AND
               (lag(p.pos) OVER w, lag(p.rule_name) OVER w, lag(p.state_name) OVER w, lag(p.r_code) OVER w,
                lag(p.charged_to) OVER w, lag(p.stop_seconds) OVER w, lag(p.rule_id) OVER w)
               IS NOT DISTINCT FROM (p.pos, p.rule_name, p.state_name, p.r_code, p.charged_to, p.stop_seconds, p.rule_id) AS same
        FROM positioned p WINDOW w AS (ORDER BY p.s)) p
)
SELECT min(s), max(e), extract(epoch FROM max(e) - min(s))::double precision,
       pos, rule_name, state_name, r_code, r_name, charged_to, stop_seconds::double precision, rule_id
FROM grouped
GROUP BY grp, pos, rule_name, state_name, r_code, r_name, charged_to, stop_seconds, rule_id
ORDER BY min(s)
$$;
COMMENT ON FUNCTION hist.fn_time_ledger(integer, timestamptz, timestamptz) IS
  'The line''s time ledger (ADR-0009): every slice of [from, to) - cut at now - with its waterfall position (loss_category_id; NULL = running, split by counts in fn_line_kpi) and the rule that gave it.';

-- ---------------------------------------------------------------------------
-- 2. The waterfall and KPIs (ADR-0008 decisions 1-4). Counts are the line's
-- good and reject per minute (hist.vw_line_count), only in scheduled minutes;
-- ICT = 3600 / rated speed of the product at that minute: the running
-- order's, or between orders the last order's (no order ever: no ICT, so
-- positions 10, 11, 13 and the KPIs that need them are empty).
--   running time  = Pos 8 - Pos 9 - Pos 12 - unaccounted
--   Pos 13 = good x ICT, Pos 11 = reject x ICT, Pos 10 = running - total x ICT
--   A = running / Pos 8, P = total x ICT / running, Q = good / total,
--   OEE = Pos 13 / Pos 8 = A x P x Q, GE = Pos 13 / Pos 3, LU = Pos 3 / Pos 1,
--   TEEP = Pos 13 / Pos 1, downtime = Pos 9 + Pos 12 + unaccounted.
-- Performance above 1 (negative speed loss) is reported as it is and
-- flagged: the rated speed is set too low (decision 4).
-- kpi_rule_id: the KPI definition version at the start of the period;
-- kpi_rule_changed: another one came into force within it.
-- ---------------------------------------------------------------------------
CREATE FUNCTION hist.fn_line_kpi(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (
  period_start timestamptz, period_end timestamptz,
  pos1_s double precision, pos2_s double precision, pos3_s double precision,
  pos4_s double precision, pos5_s double precision, pos6_s double precision, pos7_s double precision,
  pos8_s double precision, pos9_s double precision, pos10_s double precision, pos11_s double precision,
  pos12_s double precision, unaccounted_s double precision, pos13_s double precision,
  running_s double precision, good double precision, reject double precision,
  availability double precision, performance double precision, quality double precision,
  oee double precision, ge double precision, lu double precision, teep double precision,
  downtime_h double precision, kpi_rule_id integer, kpi_rule_changed boolean, performance_over_100 boolean)
LANGUAGE sql STABLE
SET jit = off
AS $$
WITH
lim AS (SELECT p_from AS t0, greatest(p_from, least(p_to, now())) AS t1),
led AS (SELECT * FROM lim, hist.fn_time_ledger(p_line_id, lim.t0, lim.t1)),
pos AS (
  SELECT
    coalesce(sum(duration_s) FILTER (WHERE loss_category_id = 2), 0)  AS p2,
    coalesce(sum(duration_s) FILTER (WHERE loss_category_id = 4), 0)  AS p4,
    coalesce(sum(duration_s) FILTER (WHERE loss_category_id = 5), 0)  AS p5,
    coalesce(sum(duration_s) FILTER (WHERE loss_category_id = 6), 0)  AS p6,
    coalesce(sum(duration_s) FILTER (WHERE loss_category_id = 7), 0)  AS p7,
    coalesce(sum(duration_s) FILTER (WHERE loss_category_id = 9), 0)  AS p9,
    coalesce(sum(duration_s) FILTER (WHERE loss_category_id = 12), 0) AS p12,
    coalesce(sum(duration_s) FILTER (WHERE loss_category_id = 90), 0) AS p90,
    coalesce(sum(duration_s) FILTER (WHERE rule = 'running'), 0)       AS run
  FROM led
),
win AS (SELECT w.starts_at, w.ends_at FROM lim, config.fn_line_schedule(p_line_id, lim.t0, lim.t1) w),
cnt AS (
  SELECT c.good, c.reject,
         3600.0 / nullif(config.fn_material_rate(p_line_id, last_order.material_id, c.ts), 0) AS ict
  FROM lim, hist.vw_line_count c
  LEFT JOIN LATERAL (
    SELECT o.material_id FROM hist.vw_work_order_interval o
    WHERE o.line_id = p_line_id AND o.started_at <= c.ts
    ORDER BY o.started_at DESC, o.work_order_id DESC LIMIT 1) last_order ON true
  WHERE c.line_id = p_line_id AND c.ts >= lim.t0 AND c.ts < lim.t1
    AND EXISTS (SELECT 1 FROM win WHERE win.starts_at <= c.ts AND c.ts < win.ends_at)
),
units AS (
  SELECT coalesce(sum(good), 0) AS good, coalesce(sum(reject), 0) AS reject,
         CASE WHEN bool_and(ict IS NOT NULL) OR count(*) = 0 THEN coalesce(sum(good * ict), 0) END AS good_s,
         CASE WHEN bool_and(ict IS NOT NULL) OR count(*) = 0 THEN coalesce(sum(reject * ict), 0) END AS reject_s,
         count(*) FILTER (WHERE (good > 0 OR reject > 0)) AS minutes_with_units,
         bool_or(ict IS NOT NULL) AS any_ict
  FROM cnt
),
ver AS (
  SELECT (SELECT id FROM config.line_kpi_rule WHERE line_id = p_line_id AND valid_from <= lim.t0 ORDER BY valid_from DESC LIMIT 1) AS rule_id,
         EXISTS (SELECT 1 FROM config.line_kpi_rule WHERE line_id = p_line_id AND valid_from > lim.t0 AND valid_from < lim.t1) AS changed
  FROM lim
),
w AS (
  SELECT lim.t0, lim.t1, extract(epoch FROM lim.t1 - lim.t0)::double precision AS p1, pos.*, units.*,
         -- no rated speed for the units made: positions 10, 11, 13 unknown;
         -- no units and no product either: nothing to judge speed by
         CASE WHEN units.good_s IS NULL OR (units.minutes_with_units = 0 AND NOT coalesce(units.any_ict, false)
                                             AND NOT EXISTS (SELECT 1 FROM hist.vw_work_order_interval o
                                                             WHERE o.line_id = p_line_id AND o.started_at < lim.t1))
              THEN false ELSE true END AS has_ict,
         ver.rule_id, ver.changed
  FROM lim, pos, units, ver
),
k AS (
  SELECT w.*, w.p1 - w.p2 AS p3, w.p1 - w.p2 - w.p4 - w.p5 - w.p6 - w.p7 AS p8,
         CASE WHEN w.has_ict THEN w.good_s END AS p13, CASE WHEN w.has_ict THEN w.reject_s END AS p11,
         CASE WHEN w.has_ict THEN w.run - w.good_s - w.reject_s END AS p10
  FROM w
)
SELECT k.t0, k.t1, k.p1, k.p2, k.p3, k.p4, k.p5, k.p6, k.p7, k.p8, k.p9, k.p10, k.p11, k.p12, k.p90, k.p13,
       k.run, k.good::double precision, k.reject::double precision,
       k.run / nullif(k.p8, 0),
       (k.p13 + k.p11) / nullif(k.run, 0),
       k.good / nullif(k.good + k.reject, 0),
       k.p13 / nullif(k.p8, 0),
       k.p13 / nullif(k.p3, 0),
       k.p3 / nullif(k.p1, 0),
       k.p13 / nullif(k.p1, 0),
       (k.p9 + k.p12 + k.p90) / 3600.0,
       k.rule_id, k.changed,
       coalesce(k.p10 < 0, false)
FROM k
$$;
COMMENT ON FUNCTION hist.fn_line_kpi(integer, timestamptz, timestamptz) IS
  'The line''s loss waterfall (ADR-0008) for [from, to), cut at now: positions in seconds (pos1 = elapsed, they close: 2+4+5+6+7+9+10+11+12+unaccounted+13 = 1), counts, A, P, Q, OEE, GE, LU, TEEP, downtime in hours, KPI definition version.';

-- Per hour, day, week or month, bounded in the site's local time; a
-- daylight-saving day has 23 or 25 hours. Hours step in real hours.
CREATE FUNCTION hist.fn_line_kpi_series(p_line_id integer, p_from timestamptz, p_to timestamptz, p_bucket text)
RETURNS TABLE (
  period_start timestamptz, period_end timestamptz,
  pos1_s double precision, pos2_s double precision, pos3_s double precision,
  pos4_s double precision, pos5_s double precision, pos6_s double precision, pos7_s double precision,
  pos8_s double precision, pos9_s double precision, pos10_s double precision, pos11_s double precision,
  pos12_s double precision, unaccounted_s double precision, pos13_s double precision,
  running_s double precision, good double precision, reject double precision,
  availability double precision, performance double precision, quality double precision,
  oee double precision, ge double precision, lu double precision, teep double precision,
  downtime_h double precision, kpi_rule_id integer, kpi_rule_changed boolean, performance_over_100 boolean)
LANGUAGE plpgsql STABLE
SET jit = off
AS $$
DECLARE
  tz text;
  b timestamptz;
  local_b timestamp;
  nxt timestamptz;
BEGIN
  IF p_bucket NOT IN ('hour', 'day', 'week', 'month') THEN
    RAISE EXCEPTION 'bucket must be hour, day, week or month, not %', p_bucket USING ERRCODE = 'invalid_parameter_value';
  END IF;
  SELECT s.time_zone INTO tz FROM config.line l JOIN config.area a ON a.id = l.area_id JOIN config.site s ON s.id = a.site_id
  WHERE l.id = p_line_id;
  IF tz IS NULL THEN RETURN; END IF;
  local_b := date_trunc(p_bucket, p_from AT TIME ZONE tz);
  b := local_b AT TIME ZONE tz;
  WHILE b < least(p_to, now()) LOOP
    IF p_bucket = 'hour' THEN
      nxt := b + interval '1 hour';
    ELSE
      local_b := local_b + ('1 ' || p_bucket)::interval;
      nxt := local_b AT TIME ZONE tz;
    END IF;
    RETURN QUERY SELECT * FROM hist.fn_line_kpi(p_line_id, greatest(b, p_from), least(nxt, p_to));
    b := nxt;
  END LOOP;
END $$;
COMMENT ON FUNCTION hist.fn_line_kpi_series(integer, timestamptz, timestamptz, text) IS
  'hist.fn_line_kpi per hour, day, week or month of [from, to), bounded in the site''s local time (ADR-0008 decision 6).';

-- ---------------------------------------------------------------------------
-- 3. Reliability per machine (ADR-0008 decision 3, ADR-0009 decision 3): a
-- breakdown is a machine's own stop whose effective reason is Pos 9.
-- running_s = the machine's running time in the period; MTBF = running time
-- / breakdowns (hours), MTTR = breakdown time / breakdowns (minutes).
-- Breakdowns are counted where they start.
-- ---------------------------------------------------------------------------
CREATE FUNCTION hist.fn_machine_reliability(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (machine_id integer, machine_name text, running_s double precision, breakdowns integer,
               breakdown_s double precision, mtbf_h double precision, mttr_min double precision)
LANGUAGE sql STABLE
SET jit = off
AS $$
WITH
lim AS (SELECT p_from AS t0, greatest(p_from, least(p_to, now())) AS t1),
mach AS (SELECT id, name FROM config.machine WHERE line_id = p_line_id AND retired_at IS NULL),
ev AS (
  SELECT e.machine_id, e.ts, e.state_id FROM hist.machine_state_event e, lim
  WHERE e.machine_id IN (SELECT id FROM mach) AND e.ts > lim.t0 AND e.ts < lim.t1
  UNION ALL
  SELECT * FROM (
    SELECT DISTINCT ON (e.machine_id) e.machine_id, e.ts, e.state_id FROM hist.machine_state_event e, lim
    WHERE e.machine_id IN (SELECT id FROM mach) AND e.ts <= lim.t0
    ORDER BY e.machine_id, e.ts DESC) before_range
),
iv AS (
  SELECT ev.machine_id, ev.ts, ev.state_id,
         extract(epoch FROM least(coalesce(lead(ev.ts) OVER (PARTITION BY ev.machine_id ORDER BY ev.ts), lim.t1), lim.t1)
                           - greatest(ev.ts, lim.t0)) AS dur
  FROM ev, lim
),
per AS (
  SELECT iv.machine_id,
         coalesce(sum(iv.dur) FILTER (WHERE iv.state_id = 1), 0) AS run,
         count(*) FILTER (WHERE er.loss_category_id = 9 AND iv.ts >= (SELECT t0 FROM lim)) AS brk,
         coalesce(sum(iv.dur) FILTER (WHERE er.loss_category_id = 9 AND iv.ts >= (SELECT t0 FROM lim)), 0) AS brk_s
  FROM iv
  LEFT JOIN hist.vw_effective_reason er ON er.machine_id = iv.machine_id AND er.event_ts = iv.ts
  GROUP BY iv.machine_id
)
SELECT m.id, m.name, coalesce(per.run, 0)::double precision, coalesce(per.brk, 0)::integer, coalesce(per.brk_s, 0)::double precision,
       per.run / 3600.0 / nullif(per.brk, 0), per.brk_s / 60.0 / nullif(per.brk, 0)
FROM mach m LEFT JOIN per ON per.machine_id = m.id
ORDER BY m.id
$$;
COMMENT ON FUNCTION hist.fn_machine_reliability(integer, timestamptz, timestamptz) IS
  'Per machine of the line, in [from, to): running time, breakdowns (own stops with a Pos 9 reason), their duration, MTBF (h), MTTR (min).';

-- ---------------------------------------------------------------------------
-- 4. Live KPIs (step 3a.7): for every line with a KPI rule in force, the
-- current hour and today in the site's local time, and its running order
-- since its start. The runtime reads this once a minute and publishes it on
-- {line}/kpi/hour, /kpi/day and /kpi/order (schemas/line-kpi.schema.json).
-- ---------------------------------------------------------------------------
CREATE FUNCTION hist.fn_live_line_kpi()
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
FROM periods p CROSS JOIN LATERAL hist.fn_line_kpi(p.id, p.s, now()) k
$$;
COMMENT ON FUNCTION hist.fn_live_line_kpi() IS
  'Every line''s current hour, today and running order (fn_line_kpi), for the runtime''s .../kpi topics.';

-- The runtime reads the KPIs (through these functions) to publish them; it
-- needs the line counts they are made of.
GRANT SELECT ON hist.vw_line_count TO ofm_runtime;

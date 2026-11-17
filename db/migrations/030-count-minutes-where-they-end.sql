-- 030 Count a minute's units in the period where the minute ends (fix, 2026-11-17).
--
-- Units are stored per minute (ADR-0026), stamped with the minute's start.
-- hist.fn_line_kpi (migration 017) counted a minute in a period when the
-- minute started inside it. An order that starts part-way through a minute
-- (18:54:20) lost that minute's units: its good count, performance and OEE
-- were too low, and This order showed 0 good for its first minute. Now a
-- minute counts in the period in which it ends: the 18:54 minute (ending
-- 18:55) belongs to the order started at 18:54:20, and its rated speed is
-- the new order's product. Hours, days and shifts start on whole minutes and
-- do not change. The line view's progress already counts this way
-- (migrations 020, 027, 029), so the two now agree. KPIs are calculated at
-- read time (ADR-0008), so past orders are corrected at once.
-- Limit: when one order is completed and the next started while the line
-- keeps running, that minute's units all go to the new order (at most one
-- minute's units; normally the line stops for the changeover). ADR-0026
-- amendment of 2026-11-17.

CREATE OR REPLACE FUNCTION hist.fn_line_kpi(p_line_id integer, p_from timestamptz, p_to timestamptz)
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
    WHERE o.line_id = p_line_id AND o.started_at < c.ts + interval '1 minute'      -- the order at the minute's end (migration 030)
    ORDER BY o.started_at DESC, o.work_order_id DESC LIMIT 1) last_order ON true
  -- a minute's units belong to the period in which the minute ends (migration 030)
  WHERE c.line_id = p_line_id AND c.ts + interval '1 minute' > lim.t0 AND c.ts + interval '1 minute' <= lim.t1
    -- in a scheduled minute; the windows are cut at the period's start, so a minute that overlaps one counts
    AND EXISTS (SELECT 1 FROM win WHERE win.starts_at < c.ts + interval '1 minute' AND c.ts < win.ends_at)
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
  'The line''s loss waterfall (ADR-0008) for [from, to), cut at now: positions in seconds (pos1 = elapsed, they close: 2+4+5+6+7+9+10+11+12+unaccounted+13 = 1), counts (a minute''s units in the period where the minute ends, migration 030), A, P, Q, OEE, GE, LU, TEEP, downtime in hours, KPI definition version.';

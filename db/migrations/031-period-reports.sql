-- 031 Period reports (step R1, ADR-0033), 2026-11-22.
--
-- The OFM Report page (https://<server>:1882/dashboard/report) and Grafana
-- *Line OEE* show any period of a line: KPIs with the previous period of
-- the same length, OEE per day or week, the losses ranked, the orders, the
-- products, the shifts and the machines. Nothing here changes how a KPI is
-- defined (ADR-0008): every figure comes from the same time ledger and
-- counts as hist.fn_line_kpi; this migration only groups them.
--
--   1. config.line.oee_target   the line's OEE target (fraction, default 0.65)
--   2. hist.fn_line_kpi         same result, faster: a month went from about
--                               8 s to well under 1 s (the order and rated speed
--                               of each counted minute are joined, not looked up)
--   3. hist.fn_report_kpi       KPIs per day, week, shift, order or product of
--                               a period, from ONE pass over the ledger
--   4. hist.fn_report_ledger    the ledger with the reason and machine named
--                               as on the dashboard (internal)
--   5. hist.fn_report_losses    the losses ranked: stop reasons per machine,
--                               speed loss, quality loss, not accounted for; each
--                               with stops, hours, share of the lost time and
--                               OEE points (they add up to 100 - OEE)
--   6. hist.fn_report_orders    the orders of the period, with changeover,
--                               plan attainment and their biggest loss
--   7. hist.fn_report_machines  MTBF, MTTR and line stop charged per machine
--   8. hist.fn_report_summary   the line's names, time zone, target and flags
-- Periods are limited to 400 days. OEE over several orders, days or shifts is
-- never an average of percentages: positions are added up in seconds and
-- divided at the end (ADR-0008), so long periods weigh more.

-- ---------------------------------------------------------------------------
-- 1. OEE target per line, edited in Mathesar (display only: no KPI uses it).
-- ---------------------------------------------------------------------------
ALTER TABLE config.line ADD COLUMN oee_target double precision NOT NULL DEFAULT 0.65
  CONSTRAINT line_oee_target_check CHECK (oee_target > 0 AND oee_target <= 1);
COMMENT ON COLUMN config.line.oee_target IS
  'The line''s OEE target as a fraction (0.65 = 65 %): the target line and colours of the report page and dashboards (step R1). Display only.';

-- ---------------------------------------------------------------------------
-- 2. hist.fn_line_kpi: unchanged result, faster count step.
-- ---------------------------------------------------------------------------
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
-- the order at each minute's end and its rated speed, found by joining
-- (migration 031: the same result as a lookup per minute, about 100 times faster)
ord AS MATERIALIZED (
  SELECT o.material_id, o.started_at,
         lead(o.started_at) OVER (ORDER BY o.started_at, o.work_order_id) AS next_start
  FROM hist.vw_work_order_interval o WHERE o.line_id = p_line_id
),
rate AS MATERIALIZED (
  SELECT r.material_id, r.valid_from, r.rate_per_hour,
         lead(r.valid_from) OVER (PARTITION BY r.material_id ORDER BY r.valid_from) AS valid_to
  FROM config.material_line_rate r WHERE r.line_id = p_line_id
),
cnt AS (
  SELECT c.good, c.reject, 3600.0 / nullif(r.rate_per_hour, 0) AS ict
  FROM lim, hist.vw_line_count c
  -- the newest order started before the minute's end (migration 030)
  LEFT JOIN ord o ON o.started_at < c.ts + interval '1 minute'
                 AND (o.next_start IS NULL OR o.next_start >= c.ts + interval '1 minute')
  LEFT JOIN rate r ON r.material_id = o.material_id AND r.valid_from <= c.ts AND (r.valid_to IS NULL OR c.ts < r.valid_to)
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

-- ---------------------------------------------------------------------------
-- 3. KPIs per group of a period from one pass over the ledger. p_group:
--      total       the whole period
--      day, week   local days, weeks from Monday (site time zone)
--      shift       per shift name, added up over the period (all A shifts ...)
--      shift_each  each shift on its own
--      order       each work order, cut to the period
--      product     per product, its orders added up
--    A group may hold several intervals (shift, product): their positions
--    and units are added up before dividing. The figures equal
--    hist.fn_line_kpi of each interval, added up the same way.
-- ---------------------------------------------------------------------------
CREATE FUNCTION hist.fn_report_kpi(p_line_id integer, p_from timestamptz, p_to timestamptz, p_group text)
RETURNS TABLE (
  group_key text, label text, period_start timestamptz, period_end timestamptz,
  pos1_s double precision, pos2_s double precision, pos3_s double precision,
  pos4_s double precision, pos5_s double precision, pos6_s double precision, pos7_s double precision,
  pos8_s double precision, pos9_s double precision, pos10_s double precision, pos11_s double precision,
  pos12_s double precision, unaccounted_s double precision, pos13_s double precision,
  running_s double precision, good double precision, reject double precision,
  availability double precision, performance double precision, quality double precision,
  oee double precision, ge double precision, lu double precision, teep double precision,
  downtime_h double precision, performance_over_100 boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET jit = off
AS $$
BEGIN
  IF p_group NOT IN ('total', 'day', 'week', 'shift', 'shift_each', 'order', 'product') THEN
    RAISE EXCEPTION 'group must be total, day, week, shift, shift_each, order or product, not %', p_group
      USING ERRCODE = 'invalid_parameter_value';
  END IF;
  IF p_to - p_from > interval '400 days' THEN
    RAISE EXCEPTION 'a report covers at most 400 days' USING ERRCODE = 'invalid_parameter_value';
  END IF;
  RETURN QUERY
  WITH
  lim AS (SELECT p_from AS t0, greatest(p_from, least(p_to, now())) AS t1),
  zone AS (
    SELECT s.time_zone AS tz FROM config.line l JOIN config.area a ON a.id = l.area_id JOIN config.site s ON s.id = a.site_id
    WHERE l.id = p_line_id
  ),
  ord AS MATERIALIZED (
    SELECT o.work_order_id, o.wo_number, o.material_id, o.sku, o.started_at, o.completed_at,
           lead(o.started_at) OVER (ORDER BY o.started_at, o.work_order_id) AS next_start
    FROM hist.vw_work_order_interval o WHERE o.line_id = p_line_id
  ),
  bk AS (
    SELECT 'total'::text AS k, 'Total'::text AS lbl, lim.t0 AS b0, lim.t1 AS b1 FROM lim WHERE p_group = 'total'
    UNION ALL
    SELECT to_char(d, 'YYYY-MM-DD'), to_char(d, 'Dy DD/MM'),
           greatest(d AT TIME ZONE zone.tz, lim.t0), least((d + interval '1 day') AT TIME ZONE zone.tz, lim.t1)
    FROM lim, zone, generate_series(date_trunc('day', lim.t0 AT TIME ZONE zone.tz), lim.t1 AT TIME ZONE zone.tz, interval '1 day') d
    WHERE p_group = 'day'
    UNION ALL
    SELECT to_char(d, 'YYYY-MM-DD'), 'w/c ' || to_char(d, 'DD/MM'),
           greatest(d AT TIME ZONE zone.tz, lim.t0), least((d + interval '7 days') AT TIME ZONE zone.tz, lim.t1)
    FROM lim, zone, generate_series(date_trunc('week', lim.t0 AT TIME ZONE zone.tz), lim.t1 AT TIME ZONE zone.tz, interval '7 days') d
    WHERE p_group = 'week'
    UNION ALL
    SELECT s.name, s.name, s.starts_at, s.ends_at FROM lim, config.fn_line_shifts(p_line_id, lim.t0, lim.t1) s WHERE p_group = 'shift'
    UNION ALL
    SELECT s.name || ' ' || to_char(s.shift_day, 'YYYY-MM-DD'), s.name || ' ' || to_char(s.shift_day, 'Dy DD/MM'), s.starts_at, s.ends_at
    FROM lim, config.fn_line_shifts(p_line_id, lim.t0, lim.t1) s WHERE p_group = 'shift_each'
    UNION ALL
    SELECT CASE WHEN p_group = 'order' THEN o.work_order_id::text ELSE o.material_id::text END,
           CASE WHEN p_group = 'order' THEN o.wo_number ELSE o.sku END,
           greatest(o.started_at, lim.t0), least(coalesce(o.completed_at, now()), lim.t1)
    FROM ord o, lim
    WHERE p_group IN ('order', 'product') AND o.started_at < lim.t1 AND coalesce(o.completed_at, 'infinity') > lim.t0
  ),
  b AS (SELECT * FROM bk WHERE bk.b1 > bk.b0),
  span AS (
    SELECT b.k, min(b.lbl) AS lbl, min(b.b0) AS s, max(b.b1) AS e, sum(extract(epoch FROM b.b1 - b.b0))::double precision AS p1
    FROM b GROUP BY b.k
  ),
  led AS (SELECT l.* FROM lim, hist.fn_time_ledger(p_line_id, lim.t0, lim.t1) l),
  pos AS (
    SELECT b.k,
      coalesce(sum(x.d) FILTER (WHERE l.loss_category_id = 2), 0)  AS p2,
      coalesce(sum(x.d) FILTER (WHERE l.loss_category_id = 4), 0)  AS p4,
      coalesce(sum(x.d) FILTER (WHERE l.loss_category_id = 5), 0)  AS p5,
      coalesce(sum(x.d) FILTER (WHERE l.loss_category_id = 6), 0)  AS p6,
      coalesce(sum(x.d) FILTER (WHERE l.loss_category_id = 7), 0)  AS p7,
      coalesce(sum(x.d) FILTER (WHERE l.loss_category_id = 9), 0)  AS p9,
      coalesce(sum(x.d) FILTER (WHERE l.loss_category_id = 12), 0) AS p12,
      coalesce(sum(x.d) FILTER (WHERE l.loss_category_id = 90), 0) AS p90,
      coalesce(sum(x.d) FILTER (WHERE l.rule = 'running'), 0)       AS run
    FROM b JOIN led l ON l.slice_start < b.b1 AND l.slice_end > b.b0
    CROSS JOIN LATERAL (SELECT extract(epoch FROM least(l.slice_end, b.b1) - greatest(l.slice_start, b.b0))::double precision AS d) x
    GROUP BY b.k
  ),
  win AS (SELECT w.starts_at, w.ends_at FROM lim, config.fn_line_schedule(p_line_id, lim.t0, lim.t1) w),
  rate AS MATERIALIZED (
    SELECT r.material_id, r.valid_from, r.rate_per_hour,
           lead(r.valid_from) OVER (PARTITION BY r.material_id ORDER BY r.valid_from) AS valid_to
    FROM config.material_line_rate r WHERE r.line_id = p_line_id
  ),
  cnt AS (
    SELECT b.k, c.good, c.reject, 3600.0 / nullif(r.rate_per_hour, 0) AS ict
    FROM lim, hist.vw_line_count c
    JOIN b ON c.ts + interval '1 minute' > b.b0 AND c.ts + interval '1 minute' <= b.b1
    LEFT JOIN ord o ON o.started_at < c.ts + interval '1 minute'
                   AND (o.next_start IS NULL OR o.next_start >= c.ts + interval '1 minute')
    LEFT JOIN rate r ON r.material_id = o.material_id AND r.valid_from <= c.ts AND (r.valid_to IS NULL OR c.ts < r.valid_to)
    WHERE c.line_id = p_line_id AND c.ts + interval '1 minute' > lim.t0 AND c.ts + interval '1 minute' <= lim.t1
      AND EXISTS (SELECT 1 FROM win WHERE win.starts_at < c.ts + interval '1 minute' AND c.ts < win.ends_at)
  ),
  units AS (
    SELECT cnt.k, sum(cnt.good) AS good, sum(cnt.reject) AS reject,
           CASE WHEN bool_and(cnt.ict IS NOT NULL) THEN sum(cnt.good * cnt.ict) END AS good_s,
           CASE WHEN bool_and(cnt.ict IS NOT NULL) THEN sum(cnt.reject * cnt.ict) END AS reject_s,
           count(*) FILTER (WHERE cnt.good > 0 OR cnt.reject > 0) AS mwu,
           bool_or(cnt.ict IS NOT NULL) AS any_ict
    FROM cnt GROUP BY cnt.k
  ),
  w AS (
    SELECT sp.k, sp.lbl, sp.s, sp.e, sp.p1,
           coalesce(pos.p2, 0) AS p2, coalesce(pos.p4, 0) AS p4, coalesce(pos.p5, 0) AS p5, coalesce(pos.p6, 0) AS p6,
           coalesce(pos.p7, 0) AS p7, coalesce(pos.p9, 0) AS p9, coalesce(pos.p12, 0) AS p12, coalesce(pos.p90, 0) AS p90,
           coalesce(pos.run, 0) AS run,
           coalesce(u.good, 0) AS good, coalesce(u.reject, 0) AS reject,
           CASE WHEN u.k IS NULL THEN 0 ELSE u.good_s END AS good_s,
           CASE WHEN u.k IS NULL THEN 0 ELSE u.reject_s END AS reject_s,
           CASE WHEN u.k IS NOT NULL AND u.good_s IS NULL THEN false
                WHEN coalesce(u.mwu, 0) = 0 AND NOT coalesce(u.any_ict, false)
                     AND NOT EXISTS (SELECT 1 FROM ord o WHERE o.started_at < sp.e) THEN false
                ELSE true END AS has_ict
    FROM span sp LEFT JOIN pos ON pos.k = sp.k LEFT JOIN units u ON u.k = sp.k
  ),
  kk AS (
    SELECT w.*, w.p1 - w.p2 AS p3, w.p1 - w.p2 - w.p4 - w.p5 - w.p6 - w.p7 AS p8,
           CASE WHEN w.has_ict THEN w.good_s END AS p13, CASE WHEN w.has_ict THEN w.reject_s END AS p11,
           CASE WHEN w.has_ict THEN w.run - w.good_s - w.reject_s END AS p10
    FROM w
  )
  SELECT kk.k, kk.lbl, kk.s, kk.e, kk.p1, kk.p2, kk.p3, kk.p4, kk.p5, kk.p6, kk.p7, kk.p8, kk.p9, kk.p10, kk.p11, kk.p12, kk.p90, kk.p13,
         kk.run, kk.good::double precision, kk.reject::double precision,
         kk.run / nullif(kk.p8, 0),
         (kk.p13 + kk.p11) / nullif(kk.run, 0),
         kk.good / nullif(kk.good + kk.reject, 0),
         kk.p13 / nullif(kk.p8, 0),
         kk.p13 / nullif(kk.p3, 0),
         kk.p3 / nullif(kk.p1, 0),
         kk.p13 / nullif(kk.p1, 0),
         (kk.p9 + kk.p12 + kk.p90) / 3600.0,
         coalesce(kk.p10 < 0, false)
  FROM kk
  ORDER BY CASE WHEN p_group = 'shift' THEN kk.k END, kk.s, kk.k;
END $$;
COMMENT ON FUNCTION hist.fn_report_kpi(integer, timestamptz, timestamptz, text) IS
  'Line KPIs of [from, to) per total, day, week, shift, shift_each, order or product, from one pass over the time ledger; positions added up before dividing (step R1).';

-- ---------------------------------------------------------------------------
-- 4. The ledger with each slice's reason and machine named as on the
--    dashboard (hist.fn_line_losses). Internal: used by 5 to 7.
-- ---------------------------------------------------------------------------
CREATE FUNCTION hist.fn_report_ledger(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (slice_start timestamptz, slice_end timestamptz, duration_s double precision, loss_category_id integer,
               rule text, reason text, machine text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET jit = off
AS $$
  WITH cons AS (
    SELECT coalesce(m.display_name, m.name) AS name
    FROM config.machine m WHERE m.id = (config.fn_line_kpi_rule(p_line_id, least(p_to, now()))).constraint_machine_id
  ),
  mach AS (SELECT m.name, coalesce(m.display_name, m.name) AS shown FROM config.machine m WHERE m.line_id = p_line_id AND m.retired_at IS NULL)
  SELECT l.slice_start, l.slice_end, l.duration_s, l.loss_category_id, l.rule,
         coalesce(l.reason_name, CASE l.rule
           WHEN 'changeover' THEN 'Changeover (order)'
           WHEN 'planned_window' THEN 'Planned window'
           WHEN 'minor_stop' THEN 'Minor stops'
           WHEN 'flow' THEN 'Buffer and flow'
           WHEN 'unaccounted' THEN 'Not accounted for'
           WHEN 'unknown' THEN 'No data (state unknown)'
           WHEN 'no_activity' THEN 'Not scheduled'
           WHEN 'running' THEN 'Running'
           ELSE l.rule END),
         CASE WHEN l.rule IN ('unknown', 'no_activity', 'running') THEN NULL
              ELSE coalesce((SELECT mach.shown FROM mach WHERE mach.name = l.cause_machine_name), (SELECT cons.name FROM cons)) END
  FROM hist.fn_time_ledger(p_line_id, p_from, p_to) l
$$;
COMMENT ON FUNCTION hist.fn_report_ledger(integer, timestamptz, timestamptz) IS
  'The time ledger of [from, to) with each slice''s reason and the machine charged named as on the dashboard (step R1, internal).';

-- ---------------------------------------------------------------------------
-- 5. The losses ranked. Stop reasons per machine (positions 9, 12 and not
--    accounted for) with their number of stops (touching slices of the same
--    reason and machine are one stop), plus speed loss (10) and quality loss
--    (11) of the period. share_of_lost: of all lost time (production hours
--    minus operating time); oee_points: of the production hours, so the
--    points add up to 100 - OEE. Speed loss is negative when the line ran
--    above its rated speed.
-- ---------------------------------------------------------------------------
CREATE FUNCTION hist.fn_report_losses(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (loss_category_id integer, loss_category text, kind text, reason text, machine text,
               stops integer, seconds double precision, share_of_lost double precision, oee_points double precision)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET jit = off
AS $$
  WITH led AS MATERIALIZED (SELECT * FROM hist.fn_report_ledger(p_line_id, p_from, p_to)),
  seq AS (
    SELECT led.*,
           CASE WHEN lag(led.slice_end) OVER o = led.slice_start
                 AND lag(led.loss_category_id) OVER o IS NOT DISTINCT FROM led.loss_category_id
                 AND lag(led.reason) OVER o IS NOT DISTINCT FROM led.reason
                 AND lag(led.machine) OVER o IS NOT DISTINCT FROM led.machine THEN 0 ELSE 1 END AS new_stop
    FROM led WINDOW o AS (ORDER BY led.slice_start)
  ),
  items AS (
    SELECT seq.loss_category_id AS cat, seq.reason, seq.machine, sum(seq.new_stop)::integer AS stops, sum(seq.duration_s) AS s
    FROM seq WHERE seq.loss_category_id IN (9, 12, 90) GROUP BY 1, 2, 3
  ),
  k AS (SELECT * FROM hist.fn_report_kpi(p_line_id, p_from, p_to, 'total')),
  all_items AS (
    SELECT items.cat, items.reason, items.machine, items.stops, items.s FROM items
    UNION ALL SELECT 10, 'Speed loss', NULL, NULL, k.pos10_s FROM k WHERE coalesce(k.pos10_s, 0) <> 0
    UNION ALL SELECT 11, 'Quality loss (rejects)', NULL, NULL, k.pos11_s FROM k WHERE coalesce(k.pos11_s, 0) <> 0
  )
  SELECT a.cat, lc.display_name,
         CASE a.cat WHEN 9 THEN 'breakdown' WHEN 12 THEN CASE WHEN a.reason = 'Minor stops' THEN 'minor_stop' ELSE 'other_unplanned' END
                    WHEN 10 THEN 'speed' WHEN 11 THEN 'quality' ELSE 'not_accounted' END,
         a.reason, a.machine, a.stops, a.s,
         a.s / nullif(k.pos8_s - k.pos13_s, 0),
         a.s / nullif(k.pos8_s, 0) * 100
  FROM all_items a CROSS JOIN k LEFT JOIN config.loss_category lc ON lc.id = a.cat
  ORDER BY a.s DESC, a.reason
$$;
COMMENT ON FUNCTION hist.fn_report_losses(integer, timestamptz, timestamptz) IS
  'Losses of [from, to) ranked: stop reasons per machine with stops, speed and quality loss; seconds, share of the lost time, OEE points (adding up to 100 - OEE) (step R1).';

-- ---------------------------------------------------------------------------
-- 6. The orders of the period (cut to it), newest first: product, plan,
--    planned and actual start, time in the period, changeover, KPIs and the
--    biggest single loss (a stop reason, or speed or quality loss).
-- ---------------------------------------------------------------------------
CREATE FUNCTION hist.fn_report_orders(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (work_order_id integer, wo_number text, sku text, product text, planned_qty integer,
               planned_start timestamptz, started_at timestamptz, completed_at timestamptz, started_by text,
               partly_outside boolean, duration_s double precision, scheduled_s double precision, changeover_s double precision,
               good double precision, reject double precision, availability double precision, performance double precision,
               quality double precision, oee double precision, pos8_s double precision, pos13_s double precision,
               biggest_loss text, biggest_loss_s double precision)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET jit = off
AS $$
  WITH lim AS (SELECT p_from AS t0, greatest(p_from, least(p_to, now())) AS t1),
  k AS (SELECT * FROM hist.fn_report_kpi(p_line_id, p_from, p_to, 'order')),
  o AS (
    SELECT i.*, w.planned_start, m.name AS product,
           greatest(i.started_at, lim.t0) AS b0, least(coalesce(i.completed_at, now()), lim.t1) AS b1,
           (i.started_at < lim.t0 OR coalesce(i.completed_at, 'infinity') > lim.t1) AS outside
    FROM hist.vw_work_order_interval i
    JOIN config.work_order w ON w.id = i.work_order_id
    JOIN config.material m ON m.id = i.material_id
    CROSS JOIN lim
    WHERE i.line_id = p_line_id AND i.started_at < lim.t1 AND coalesce(i.completed_at, 'infinity') > lim.t0
  ),
  led AS MATERIALIZED (SELECT * FROM hist.fn_report_ledger(p_line_id, p_from, p_to) WHERE loss_category_id IN (9, 12, 90)),
  ol AS (
    SELECT o.work_order_id AS id, led.reason, led.machine,
           sum(extract(epoch FROM least(led.slice_end, o.b1) - greatest(led.slice_start, o.b0)))::double precision AS s
    FROM o JOIN led ON led.slice_start < o.b1 AND led.slice_end > o.b0
    GROUP BY 1, 2, 3
  ),
  best AS (SELECT DISTINCT ON (ol.id) ol.* FROM ol ORDER BY ol.id, ol.s DESC, ol.reason)
  SELECT o.work_order_id, o.wo_number, o.sku, o.product, o.planned_qty, o.planned_start, o.started_at, o.completed_at, o.started_by,
         o.outside, k.pos1_s, k.pos3_s, k.pos6_s, k.good, k.reject, k.availability, k.performance, k.quality, k.oee, k.pos8_s, k.pos13_s,
         CASE WHEN coalesce(k.pos10_s, 0) > coalesce(best.s, 0) AND coalesce(k.pos10_s, 0) >= coalesce(k.pos11_s, 0) THEN 'Speed loss'
              WHEN coalesce(k.pos11_s, 0) > coalesce(best.s, 0) THEN 'Quality loss (rejects)'
              WHEN best.reason IS NULL THEN NULL
              WHEN best.machine IS NULL OR position(':' IN best.reason) > 0 THEN best.reason
              ELSE best.reason || ' (' || best.machine || ')' END,
         greatest(coalesce(best.s, 0), coalesce(k.pos10_s, 0), coalesce(k.pos11_s, 0))
  FROM o
  LEFT JOIN k ON k.group_key = o.work_order_id::text
  LEFT JOIN best ON best.id = o.work_order_id
  ORDER BY o.started_at DESC, o.work_order_id DESC
$$;
COMMENT ON FUNCTION hist.fn_report_orders(integer, timestamptz, timestamptz) IS
  'Work orders of [from, to), newest first, cut to the period: plan, planned and actual start, changeover, KPIs and the biggest loss (step R1).';

-- ---------------------------------------------------------------------------
-- 7. Per machine: line stop charged to it (positions 9, 12, not accounted
--    for, as in the Machines table of Line OEE), breakdowns, MTBF, MTTR.
-- ---------------------------------------------------------------------------
CREATE FUNCTION hist.fn_report_machines(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (machine_id integer, machine text, is_constraint boolean, charged_s double precision, running_s double precision,
               breakdowns integer, breakdown_s double precision, mtbf_h double precision, mttr_min double precision)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET jit = off
AS $$
  WITH ch AS (
    SELECT l.machine, sum(l.duration_s) AS s FROM hist.fn_report_ledger(p_line_id, p_from, p_to) l
    WHERE l.loss_category_id IN (9, 12, 90) AND l.machine IS NOT NULL GROUP BY l.machine
  )
  SELECT r.machine_id, coalesce(m.display_name, m.name),
         m.id = (config.fn_line_kpi_rule(p_line_id, least(p_to, now()))).constraint_machine_id,
         coalesce(ch.s, 0), r.running_s, r.breakdowns, r.breakdown_s, r.mtbf_h, r.mttr_min
  FROM hist.fn_machine_reliability(p_line_id, p_from, p_to) r
  JOIN config.machine m ON m.id = r.machine_id
  LEFT JOIN ch ON ch.machine = coalesce(m.display_name, m.name)
  ORDER BY r.machine_id
$$;
COMMENT ON FUNCTION hist.fn_report_machines(integer, timestamptz, timestamptz) IS
  'Per machine of the line in [from, to): line stop charged, running time, breakdowns, MTBF (h), MTTR (min) (step R1).';

-- ---------------------------------------------------------------------------
-- 8. The report's header: names, time zone, target and what to warn about.
-- ---------------------------------------------------------------------------
CREATE FUNCTION hist.fn_report_summary(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (line_name text, line_path text, time_zone text, oee_target double precision,
               kpi_rule_changed boolean, test_data boolean, has_rule boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT l.display_name, e.name || '/' || s.name || '/' || a.name, s.time_zone, l.oee_target,
         EXISTS (SELECT 1 FROM config.line_kpi_rule r WHERE r.line_id = l.id AND r.valid_from > p_from AND r.valid_from < least(p_to, now())),
         EXISTS (SELECT 1 FROM hist.test_data_range t
                 JOIN config.machine_property p ON p.id = t.property_id
                 JOIN config.machine m ON m.id = p.machine_id
                 WHERE m.line_id = l.id AND t.from_ts < p_to AND t.to_ts > p_from),
         EXISTS (SELECT 1 FROM config.line_kpi_rule r WHERE r.line_id = l.id AND r.valid_from < p_to)
  FROM config.line l
  JOIN config.area a ON a.id = l.area_id
  JOIN config.site s ON s.id = a.site_id
  JOIN config.enterprise e ON e.id = s.enterprise_id
  WHERE l.id = p_line_id
$$;
COMMENT ON FUNCTION hist.fn_report_summary(integer, timestamptz, timestamptz) IS
  'The report header of a line and period: names, time zone, OEE target, KPI rule changed, made-up test data present (step R1).';

REVOKE ALL ON FUNCTION hist.fn_report_kpi(integer, timestamptz, timestamptz, text),
  hist.fn_report_ledger(integer, timestamptz, timestamptz),
  hist.fn_report_losses(integer, timestamptz, timestamptz),
  hist.fn_report_orders(integer, timestamptz, timestamptz),
  hist.fn_report_machines(integer, timestamptz, timestamptz),
  hist.fn_report_summary(integer, timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hist.fn_report_kpi(integer, timestamptz, timestamptz, text),
  hist.fn_report_losses(integer, timestamptz, timestamptz),
  hist.fn_report_orders(integer, timestamptz, timestamptz),
  hist.fn_report_machines(integer, timestamptz, timestamptz),
  hist.fn_report_summary(integer, timestamptz, timestamptz)
TO ofm_screens, ofm_reader;

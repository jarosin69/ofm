-- 019 Shifts and the Line OEE dashboard (step 3a.8b, ADR-0008 decision 6).
--   1. config.line_shift: each line's shifts, weekly, in the site's local
--      time, edited in Mathesar (e.g. A 06:00-14:00, B 14:00-22:00,
--      C 22:00-06:00); config.fn_line_shifts() gives them as real intervals
--   2. config.vw_line_shift_problem: shifts of a line that overlap
--   3. What the Grafana dashboard "OFM · Line OEE" reads, all calculated
--      from the history at read time (ADR-0009 decision 5):
--      hist.fn_dashboard_period  the period: the time picker, or one shift
--      hist.fn_line_kpi_by_shift KPIs per shift
--      hist.fn_line_losses       where the time went: per reason and machine
--      hist.fn_line_stop_list    the line's stops with reason and who coded it
--      hist.fn_line_orders       the orders of a period with their KPIs
-- Shifts change no KPI: they are only another way to cut the time, like
-- hours and days. Scheduled time stays config.line_schedule.

-- ---------------------------------------------------------------------------
-- 1. Shifts. A shift belongs to the day it starts on; one that ends at or
-- before its start time ends the next day (C 22:00-06:00). Change shifts
-- like the schedule: end the old rows (valid_to) and add new ones, so past
-- shifts keep their times.
-- ---------------------------------------------------------------------------
CREATE TABLE config.line_shift (
  id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  line_id       integer NOT NULL REFERENCES config.line (id) ON DELETE RESTRICT,
  name          text NOT NULL CHECK (name ~ '^[A-Za-z0-9][A-Za-z0-9 _-]{0,15}$'),
  mon           boolean NOT NULL DEFAULT true,
  tue           boolean NOT NULL DEFAULT true,
  wed           boolean NOT NULL DEFAULT true,
  thu           boolean NOT NULL DEFAULT true,
  fri           boolean NOT NULL DEFAULT true,
  sat           boolean NOT NULL DEFAULT false,
  sun           boolean NOT NULL DEFAULT false,
  start_time    time NOT NULL,
  end_time      time NOT NULL,
  valid_from    date NOT NULL DEFAULT current_date,   -- first day a shift starts on
  valid_to      date,                                 -- last day; NULL = no end
  note          text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text        NOT NULL DEFAULT current_user,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    text        NOT NULL DEFAULT current_user,
  CONSTRAINT line_shift_some_day CHECK (mon OR tue OR wed OR thu OR fri OR sat OR sun),
  CONSTRAINT line_shift_dates CHECK (valid_to IS NULL OR valid_to >= valid_from)
);
COMMENT ON TABLE config.line_shift IS
  'Shifts of a line, weekly, in the site''s local time (ADR-0008 decision 6): name (A, B, C), start and end (end at or before start = next day), the days a shift starts on. For KPIs per shift; scheduled time is config.line_schedule.';
CALL audit.fn_enable('config.line_shift');

-- The shifts overlapping [p_from, p_to) as real intervals (daylight saving
-- included), cut to the range; shift_day = the local day the shift started.
CREATE FUNCTION config.fn_line_shifts(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (shift_id integer, name text, shift_day date, starts_at timestamptz, ends_at timestamptz)
LANGUAGE sql STABLE
AS $$
  WITH zone AS (
    SELECT s.time_zone AS tz
    FROM config.line l JOIN config.area a ON a.id = l.area_id JOIN config.site s ON s.id = a.site_id
    WHERE l.id = p_line_id
  ),
  local_day AS (
    SELECT d::date AS day, extract(isodow FROM d)::int AS dow
    FROM zone, generate_series((p_from AT TIME ZONE zone.tz)::date - 1, (p_to AT TIME ZONE zone.tz)::date, interval '1 day') d
  ),
  shift_ AS (
    SELECT w.id, w.name, ld.day,
           (ld.day + w.start_time) AT TIME ZONE zone.tz AS starts_at,
           ((ld.day + CASE WHEN w.end_time > w.start_time THEN 0 ELSE 1 END) + w.end_time) AT TIME ZONE zone.tz AS ends_at
    FROM config.line_shift w
    CROSS JOIN zone
    JOIN local_day ld ON (ARRAY[w.mon, w.tue, w.wed, w.thu, w.fri, w.sat, w.sun])[ld.dow]
                     AND ld.day >= w.valid_from AND (w.valid_to IS NULL OR ld.day <= w.valid_to)
    WHERE w.line_id = p_line_id
  )
  SELECT id, name, day, greatest(starts_at, p_from), least(ends_at, p_to)
  FROM shift_
  WHERE starts_at < p_to AND ends_at > p_from
  ORDER BY 4, 2
$$;
COMMENT ON FUNCTION config.fn_line_shifts(integer, timestamptz, timestamptz) IS
  'The line''s shifts overlapping [p_from, p_to) as UTC intervals, cut to the range; shift_day = the local day each started.';

-- ---------------------------------------------------------------------------
-- 2. Shifts that overlap on a line (in the coming week): their time would
-- count in both. Shown on the dashboard; fix them in Mathesar.
-- ---------------------------------------------------------------------------
CREATE VIEW config.vw_line_shift_problem AS
SELECT l.id AS line_id, l.name AS line_name, a.name AS shift, a.shift_day, b.name AS overlaps_shift, b.shift_day AS overlaps_day
FROM config.line l
CROSS JOIN LATERAL config.fn_line_shifts(l.id, now() - interval '1 day', now() + interval '8 days') a
JOIN LATERAL config.fn_line_shifts(l.id, now() - interval '1 day', now() + interval '8 days') b
  ON (b.starts_at, b.shift_id) > (a.starts_at, a.shift_id) AND b.starts_at < a.ends_at
WHERE l.retired_at IS NULL;
COMMENT ON VIEW config.vw_line_shift_problem IS
  'Shifts of a line that overlap in the coming week (config.line_shift): fix their times or days in Mathesar.';

-- ---------------------------------------------------------------------------
-- 3. What the Line OEE dashboard reads.
-- The period of every panel: the dashboard's time picker, or - when a shift
-- is chosen ("<start ms>-<end ms>", from the dashboard's shift list) - that
-- shift.
-- ---------------------------------------------------------------------------
CREATE FUNCTION hist.fn_dashboard_period(p_shift text, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (t0 timestamptz, t1 timestamptz)
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE WHEN p_shift ~ '^[0-9]+-[0-9]+$' THEN to_timestamp(split_part(p_shift, '-', 1)::bigint / 1000.0) ELSE p_from END,
         CASE WHEN p_shift ~ '^[0-9]+-[0-9]+$' THEN to_timestamp(split_part(p_shift, '-', 2)::bigint / 1000.0) ELSE p_to END
$$;

-- KPIs per shift: hist.fn_line_kpi for each shift in [p_from, p_to) (cut to
-- the range and to now), oldest first.
CREATE FUNCTION hist.fn_line_kpi_by_shift(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (
  shift_name text, shift_day date, starts_at timestamptz, ends_at timestamptz,
  pos8_s double precision, running_s double precision, good double precision, reject double precision,
  availability double precision, performance double precision, quality double precision, oee double precision,
  downtime_h double precision, unaccounted_s double precision)
LANGUAGE sql STABLE
SET jit = off
AS $$
  SELECT s.name, s.shift_day, s.starts_at, s.ends_at,
         k.pos8_s, k.running_s, k.good, k.reject, k.availability, k.performance, k.quality, k.oee, k.downtime_h, k.unaccounted_s
  FROM config.fn_line_shifts(p_line_id, p_from, least(p_to, now())) s
  CROSS JOIN LATERAL hist.fn_line_kpi(p_line_id, s.starts_at, s.ends_at) k
  ORDER BY s.starts_at
$$;
COMMENT ON FUNCTION hist.fn_line_kpi_by_shift(integer, timestamptz, timestamptz) IS
  'Line KPIs (hist.fn_line_kpi) per shift of config.line_shift in [from, to), cut to the range and to now.';

-- Where the line's time went (ADR-0008, ADR-0009): the time ledger added up
-- per loss position, reason and machine. reason: the coded reason, or what
-- the rule says (changeover window, minor stops, not accounted for ...);
-- machine: (display name of) the machine the time is charged to - the stopped machine that
-- starved or blocked the constraint (ADR-0024), else the constraint itself;
-- empty for time without data or outside the schedule. Running time (no
-- position) is left out.
CREATE FUNCTION hist.fn_line_losses(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (loss_category_id integer, loss_category text, reason text, machine text, seconds double precision)
LANGUAGE sql STABLE
SET jit = off
AS $$
  WITH cons AS (
    SELECT coalesce(m.display_name, m.name) AS name
    FROM config.machine m WHERE m.id = (config.fn_line_kpi_rule(p_line_id, least(p_to, now()))).constraint_machine_id
  )
  SELECT l.loss_category_id, lc.display_name,
         coalesce(l.reason_name, CASE l.rule
           WHEN 'changeover' THEN 'Changeover (order)'
           WHEN 'planned_window' THEN 'Planned window (' || lower(lc.display_name) || ')'
           WHEN 'minor_stop' THEN 'Minor stops'
           WHEN 'flow' THEN 'Buffer and flow'
           WHEN 'unaccounted' THEN 'Not accounted for'
           WHEN 'unknown' THEN 'No data (state unknown)'
           WHEN 'no_activity' THEN 'Not scheduled'
           ELSE l.rule END),
         CASE WHEN l.rule IN ('unknown', 'no_activity') THEN NULL
              ELSE coalesce((SELECT coalesce(m.display_name, m.name) FROM config.machine m
                             WHERE m.line_id = p_line_id AND m.name = l.cause_machine_name AND m.retired_at IS NULL), (SELECT name FROM cons)) END,
         sum(l.duration_s)
  FROM hist.fn_time_ledger(p_line_id, p_from, p_to) l
  JOIN config.loss_category lc ON lc.id = l.loss_category_id
  WHERE l.loss_category_id IS NOT NULL
  GROUP BY 1, 2, 3, 4
$$;
COMMENT ON FUNCTION hist.fn_line_losses(integer, timestamptz, timestamptz) IS
  'The time ledger of [from, to) added up per loss position, reason and the machine charged (ADR-0008, ADR-0009, ADR-0024); running time left out.';

-- The line's stops in [p_from, p_to): every piece of the time ledger that
-- is not running, with its position, reason, the machine charged and who
-- coded it (plc, ofm or a person's name); newest first.
CREATE FUNCTION hist.fn_line_stop_list(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (started timestamptz, seconds double precision, state text, loss_category_id integer, loss_category text,
               reason text, machine text, assigned_by text, rule text)
LANGUAGE sql STABLE
SET enable_nestloop = off
SET jit = off
AS $$
  WITH led AS (SELECT * FROM hist.fn_time_ledger(p_line_id, p_from, p_to) WHERE rule NOT IN ('running', 'no_activity')),
  st AS (SELECT * FROM hist.fn_line_stops(p_line_id, p_from - interval '1 day', p_to)),
  cons AS (
    SELECT coalesce(m.display_name, m.name) AS name
    FROM config.machine m WHERE m.id = (config.fn_line_kpi_rule(p_line_id, least(p_to, now()))).constraint_machine_id
  )
  SELECT l.slice_start, l.duration_s, l.state, l.loss_category_id, lc.display_name,
         coalesce(l.reason_name, CASE l.rule
           WHEN 'changeover' THEN 'Changeover (order)' WHEN 'planned_window' THEN 'Planned window'
           WHEN 'minor_stop' THEN 'Minor stop' WHEN 'flow' THEN 'Buffer and flow'
           WHEN 'unaccounted' THEN 'Not accounted for' WHEN 'unknown' THEN 'No data (state unknown)' ELSE l.rule END),
         CASE WHEN l.rule = 'unknown' THEN NULL
              ELSE coalesce((SELECT coalesce(m.display_name, m.name) FROM config.machine m
                             WHERE m.line_id = p_line_id AND m.name = l.cause_machine_name AND m.retired_at IS NULL), (SELECT name FROM cons)) END,
         CASE WHEN l.rule IN ('reason', 'attributed', 'waiting_for_order') THEN
           (SELECT s.assigned_by FROM st s WHERE s.slice_start <= l.slice_start AND l.slice_start < s.slice_end LIMIT 1) END,
         l.rule
  FROM led l
  LEFT JOIN config.loss_category lc ON lc.id = l.loss_category_id
  ORDER BY l.slice_start DESC
$$;
COMMENT ON FUNCTION hist.fn_line_stop_list(integer, timestamptz, timestamptz) IS
  'The line''s stops in [from, to) from the time ledger: position, reason, machine charged and who coded it; newest first.';

-- The work orders that ran in [p_from, p_to), with their KPIs inside the range.
CREATE FUNCTION hist.fn_line_orders(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (work_order_id integer, wo_number text, sku text, planned_qty integer, started_at timestamptz,
               completed_at timestamptz, started_by text, good double precision, reject double precision,
               availability double precision, performance double precision, quality double precision, oee double precision)
LANGUAGE sql STABLE
SET jit = off
AS $$
  SELECT i.work_order_id, i.wo_number, i.sku, i.planned_qty, i.started_at, i.completed_at, i.started_by,
         k.good, k.reject, k.availability, k.performance, k.quality, k.oee
  FROM hist.vw_work_order_interval i
  CROSS JOIN LATERAL hist.fn_line_kpi(p_line_id, greatest(i.started_at, p_from), least(coalesce(i.completed_at, now()), p_to)) k
  WHERE i.line_id = p_line_id AND i.started_at < least(p_to, now()) AND coalesce(i.completed_at, 'infinity') > p_from
    AND greatest(i.started_at, p_from) < least(coalesce(i.completed_at, now()), p_to)
  ORDER BY i.started_at DESC
$$;
COMMENT ON FUNCTION hist.fn_line_orders(integer, timestamptz, timestamptz) IS
  'Work orders that ran in [from, to), newest first, with their KPIs inside the range (hist.fn_line_kpi).';

-- 026 Trend bands and periods (step H2b, ADR-0029): what the trend page
-- draws under the trends and offers as periods.
--   1. A colour per machine state (config.machine_state.colour), edited in
--      Mathesar; the trend page's state bands use it.
--   2. hist.fn_trend_states: each machine's states over a period; over long
--      periods the state that took most of each pixel's time, so a year
--      stays readable and quick.
--   3. hist.fn_trend_orders: the work orders over a period (with their
--      changeover), and hist.fn_trend_order_list: a line's recent orders,
--      to choose one as the period; hist.fn_trend_shifts: the lines' shifts
--      over a period (config.fn_line_shifts of migration 019, for the trend
--      page's role).

-- ---------------------------------------------------------------------------
-- 1. State colours
-- ---------------------------------------------------------------------------
ALTER TABLE config.machine_state
  ADD COLUMN colour text NOT NULL DEFAULT '#9e9e9e' CHECK (colour ~ '^#[0-9a-fA-F]{6}$');
COMMENT ON COLUMN config.machine_state.colour IS 'Colour of the state on charts (trend page state bands), #rrggbb.';
GRANT UPDATE (colour) ON config.machine_state TO ofm_config;   -- like display_name (migration 013): edited in Mathesar
UPDATE config.machine_state SET colour = CASE name
  WHEN 'running'     THEN '#2e7d32'
  WHEN 'idle'        THEN '#b0b5bd'
  WHEN 'fault'       THEN '#c62828'
  WHEN 'starved'     THEN '#f2b705'
  WHEN 'blocked'     THEN '#ef6c00'
  WHEN 'setup'       THEN '#1e6fd9'
  WHEN 'cleaning'    THEN '#8e6cb0'
  WHEN 'maintenance' THEN '#283593'
  WHEN 'unknown'     THEN '#616161'
  ELSE colour END;

-- ---------------------------------------------------------------------------
-- 2. States over a period
-- ---------------------------------------------------------------------------
-- Per machine (at most 6): the state intervals touching [p_from, p_to),
-- starting with the state in force at p_from, the last one ending at p_to
-- or now; with the reason assigned to a stop (latest assignment). When a
-- machine has more than 3,000 state changes in the period, the period is
-- cut into p_buckets equal parts, each part gets the state that took most
-- of its time, and equal neighbours are joined (dominant = true; no
-- reasons then).
CREATE FUNCTION hist.fn_trend_states(p_machine_ids integer[], p_from timestamptz, p_to timestamptz, p_buckets integer DEFAULT 1500)
RETURNS TABLE (machine_id integer, t0_ms bigint, t1_ms bigint, state text, state_name text, colour text, reason text, dominant boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET jit = off
AS $$
DECLARE
  m integer;
  n bigint;
  b interval;
  bs double precision;
  t_end timestamptz := least(p_to, now());
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN RETURN; END IF;
  FOREACH m IN ARRAY coalesce(p_machine_ids[1:6], '{}'::integer[]) LOOP
    SELECT count(*) INTO n FROM hist.machine_state_event e WHERE e.machine_id = m AND e.ts >= p_from AND e.ts < p_to;
    IF n <= 3000 THEN
      RETURN QUERY
      WITH ev AS (
        (SELECT e.ts, e.state_id FROM hist.machine_state_event e WHERE e.machine_id = m AND e.ts < p_from ORDER BY e.ts DESC LIMIT 1)
        UNION ALL
        (SELECT e.ts, e.state_id FROM hist.machine_state_event e WHERE e.machine_id = m AND e.ts >= p_from AND e.ts < p_to)
      ), iv AS (
        SELECT ev.ts, coalesce(lead(ev.ts) OVER (ORDER BY ev.ts), t_end) AS te, ev.state_id FROM ev
      )
      SELECT m, floor(extract(epoch FROM greatest(iv.ts, p_from)) * 1000)::bigint, floor(extract(epoch FROM iv.te) * 1000)::bigint,
             s.name, s.display_name, s.colour,
             (SELECT r.code || ' · ' || r.display_name FROM hist.state_reason sr JOIN config.reason r ON r.id = sr.reason_id
              WHERE sr.machine_id = m AND sr.event_ts = iv.ts ORDER BY sr.assigned_at DESC LIMIT 1),
             false
      FROM iv JOIN config.machine_state s ON s.id = iv.state_id
      WHERE iv.te > iv.ts AND iv.te > p_from
      ORDER BY iv.ts;
    ELSE
      b := (p_to - p_from) / greatest(least(coalesce(p_buckets, 1500), 4000), 100);
      bs := extract(epoch FROM b);
      RETURN QUERY
      WITH ev AS (
        (SELECT e.ts, e.state_id FROM hist.machine_state_event e WHERE e.machine_id = m AND e.ts < p_from ORDER BY e.ts DESC LIMIT 1)
        UNION ALL
        (SELECT e.ts, e.state_id FROM hist.machine_state_event e WHERE e.machine_id = m AND e.ts >= p_from AND e.ts < p_to)
      ), iv AS (
        SELECT greatest(ev.ts, p_from) AS ts, coalesce(lead(ev.ts) OVER (ORDER BY ev.ts), t_end) AS te, ev.state_id FROM ev
      ), parts AS (                               -- each interval's seconds in each part
        SELECT g.k, iv.state_id,
               extract(epoch FROM least(iv.te, p_from + g.k * b) - greatest(iv.ts, p_from + (g.k - 1) * b)) AS sec
        FROM iv
        CROSS JOIN LATERAL generate_series(floor(extract(epoch FROM iv.ts - p_from) / bs)::integer + 1,
                                           ceil(extract(epoch FROM iv.te - p_from) / bs)::integer) AS g (k)
        WHERE iv.te > iv.ts
      ), dom AS (                                 -- the state with most time in each part
        SELECT DISTINCT ON (x.k) x.k, x.state_id FROM (SELECT parts.k, parts.state_id, sum(parts.sec) AS s FROM parts GROUP BY 1, 2) x
        ORDER BY x.k, x.s DESC
      ), runs AS (                                -- neighbours with the same state join
        SELECT dom.k, dom.state_id, dom.k - row_number() OVER (PARTITION BY dom.state_id ORDER BY dom.k) AS grp FROM dom
      )
      SELECT m, floor(extract(epoch FROM p_from + (min(runs.k) - 1) * b) * 1000)::bigint,
             floor(extract(epoch FROM least(p_from + max(runs.k) * b, t_end)) * 1000)::bigint,
             s.name, s.display_name, s.colour, NULL::text, true
      FROM runs JOIN config.machine_state s ON s.id = runs.state_id
      GROUP BY runs.state_id, runs.grp, s.name, s.display_name, s.colour
      ORDER BY min(runs.k);
    END IF;
  END LOOP;
END $$;
COMMENT ON FUNCTION hist.fn_trend_states(integer[], timestamptz, timestamptz, integer) IS
  'Machine states over [from, to) for the trend page''s bands: intervals with reasons, or over more than 3,000 changes the dominant state per part (ADR-0029, step H2b).';

-- ---------------------------------------------------------------------------
-- 3. Orders over a period, and a line's recent orders
-- ---------------------------------------------------------------------------
CREATE FUNCTION hist.fn_trend_orders(p_line_ids integer[], p_from timestamptz, p_to timestamptz)
RETURNS TABLE (line_id integer, work_order_id integer, wo_number text, sku text, t0_ms bigint, setup_end_ms bigint, t1_ms bigint, running boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT o.line_id, o.work_order_id, o.wo_number, o.sku,
         floor(extract(epoch FROM o.started_at) * 1000)::bigint,
         floor(extract(epoch FROM o.changeover_end_at) * 1000)::bigint,
         floor(extract(epoch FROM coalesce(o.completed_at, greatest(now(), o.started_at))) * 1000)::bigint,
         o.completed_at IS NULL
  FROM hist.vw_work_order_interval o
  WHERE o.line_id = ANY (p_line_ids) AND o.started_at < p_to AND coalesce(o.completed_at, now()) > p_from
  ORDER BY o.started_at
  LIMIT 2000
$$;
COMMENT ON FUNCTION hist.fn_trend_orders(integer[], timestamptz, timestamptz) IS
  'Work orders touching [from, to) on these lines, with the end of their changeover, for the trend page''s order band (step H2b).';

CREATE FUNCTION hist.fn_trend_order_list(p_line_ids integer[], p_limit integer DEFAULT 60)
RETURNS TABLE (line_id integer, work_order_id integer, wo_number text, sku text, t0_ms bigint, t1_ms bigint, running boolean)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT o.line_id, o.work_order_id, o.wo_number, o.sku,
         floor(extract(epoch FROM o.started_at) * 1000)::bigint,
         floor(extract(epoch FROM coalesce(o.completed_at, greatest(now(), o.started_at))) * 1000)::bigint,
         o.completed_at IS NULL
  FROM hist.vw_work_order_interval o
  WHERE o.line_id = ANY (p_line_ids)
  ORDER BY o.started_at DESC
  LIMIT least(greatest(coalesce(p_limit, 60), 1), 500)
$$;
COMMENT ON FUNCTION hist.fn_trend_order_list(integer[], integer) IS
  'The most recent work orders of these lines, newest first, to choose one as the trend page''s period (step H2b).';

-- The lines' shifts touching [p_from, p_to), whole (config.fn_line_shifts
-- cuts them at the period's ends; a shift is at most a day), a running shift
-- ending now: for the shift band and to choose a shift as the period. At most
-- the last 31 days of the period.
CREATE FUNCTION hist.fn_trend_shifts(p_line_ids integer[], p_from timestamptz, p_to timestamptz)
RETURNS TABLE (line_id integer, name text, shift_day date, t0_ms bigint, t1_ms bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT l.id, w.name, w.shift_day, floor(extract(epoch FROM w.starts_at) * 1000)::bigint,
         floor(extract(epoch FROM least(w.ends_at, greatest(now(), w.starts_at))) * 1000)::bigint
  FROM unnest(p_line_ids[1:4]) AS l (id)
  CROSS JOIN LATERAL config.fn_line_shifts(l.id, greatest(p_from, p_to - interval '31 days') - interval '1 day', p_to + interval '1 day') w
  WHERE w.starts_at < p_to AND w.ends_at > greatest(p_from, p_to - interval '31 days')
    AND w.starts_at > greatest(p_from, p_to - interval '31 days') - interval '1 day'      -- not cut at the widened start
  ORDER BY w.starts_at, l.id
$$;
COMMENT ON FUNCTION hist.fn_trend_shifts(integer[], timestamptz, timestamptz) IS
  'Whole shifts of these lines touching [from, to) (at most the last 31 days of it), a running one ending now, for the trend page (step H2b).';

REVOKE ALL ON FUNCTION hist.fn_trend_states(integer[], timestamptz, timestamptz, integer),
  hist.fn_trend_orders(integer[], timestamptz, timestamptz), hist.fn_trend_order_list(integer[], integer),
  hist.fn_trend_shifts(integer[], timestamptz, timestamptz) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION hist.fn_trend_states(integer[], timestamptz, timestamptz, integer),
  hist.fn_trend_orders(integer[], timestamptz, timestamptz), hist.fn_trend_order_list(integer[], integer),
  hist.fn_trend_shifts(integer[], timestamptz, timestamptz)
TO ofm_screens, ofm_reader;

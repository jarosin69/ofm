-- 022 Line OEE dashboard: a work order as the period (step 3a.8b, asked on
-- the laptop 2026-11-10).
-- Besides the time picker and a shift, the dashboard's period can be a work
-- order: the running one ("current", which follows to the next order by
-- itself) or one of the last two weeks. An order wins over a shift, a shift
-- over the time picker. The function also says in words which period is
-- shown, for the dashboard's "Period shown" panel.
-- The three-argument version of migration 019 stays for queries written
-- against it.

CREATE FUNCTION hist.fn_dashboard_period(p_line_id integer, p_shift text, p_order text, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (t0 timestamptz, t1 timestamptz, label text)
LANGUAGE sql STABLE
AS $$
  WITH zone AS (
    SELECT s.time_zone AS tz
    FROM config.line l JOIN config.area a ON a.id = l.area_id JOIN config.site s ON s.id = a.site_id
    WHERE l.id = p_line_id
  ),
  ord AS (                                    -- the chosen order: by ID, or the running (else the last) one
    SELECT o.wo_number, o.sku, o.started_at, o.completed_at
    FROM hist.vw_work_order_interval o
    WHERE o.line_id = p_line_id
      AND (o.work_order_id = CASE WHEN p_order ~ '^[0-9]{1,9}$' THEN p_order::integer END OR p_order = 'current')
    ORDER BY (o.completed_at IS NULL) DESC, o.started_at DESC
    LIMIT 1
  ),
  shift_ AS (
    SELECT to_timestamp(CASE WHEN p_shift ~ '^[0-9]{1,15}-[0-9]{1,15}$' THEN split_part(p_shift, '-', 1)::bigint END / 1000.0) AS t0,
           to_timestamp(CASE WHEN p_shift ~ '^[0-9]{1,15}-[0-9]{1,15}$' THEN split_part(p_shift, '-', 2)::bigint END / 1000.0) AS t1
    WHERE p_shift ~ '^[0-9]{1,15}-[0-9]{1,15}$'          -- the CASEs keep PostgreSQL from converting other text
  ),
  chosen AS (
    SELECT o.started_at AS t0, coalesce(o.completed_at, 'infinity') AS t1,
           'Order ' || o.wo_number || ' (' || o.sku || ')' || CASE WHEN o.completed_at IS NULL THEN ', running' ELSE '' END AS what, 1 AS pref
    FROM ord o
    UNION ALL
    SELECT s.t0, s.t1, 'Shift ' || coalesce((SELECT w.name FROM config.fn_line_shifts(p_line_id, s.t0, s.t1) w WHERE w.starts_at = s.t0 LIMIT 1), ''), 2
    FROM shift_ s
    UNION ALL
    SELECT p_from, p_to, 'Time picker', 3
  ),
  best AS (SELECT * FROM chosen ORDER BY pref LIMIT 1),
  cut AS (SELECT b.what, b.t0, greatest(b.t0, least(b.t1, hist.fn_counted_until())) AS t1, b.t1 AS t1_planned FROM best b)
  SELECT c.t0, c.t1,
         c.what || ' · ' || to_char(c.t0 AT TIME ZONE z.tz, 'Dy DD/MM HH24:MI') || ' – ' ||
         CASE WHEN c.t1_planned > now() THEN 'now'
              WHEN (c.t1 AT TIME ZONE z.tz)::date = (c.t0 AT TIME ZONE z.tz)::date THEN to_char(c.t1 AT TIME ZONE z.tz, 'HH24:MI')
              ELSE to_char(c.t1 AT TIME ZONE z.tz, 'Dy DD/MM HH24:MI') END
  FROM cut c, zone z
$$;
COMMENT ON FUNCTION hist.fn_dashboard_period(integer, text, text, timestamptz, timestamptz) IS
  'The Line OEE dashboard''s period: a work order (an ID, or current = the running one), else a shift (''<start ms>-<end ms>''), else the time picker; ends at the last counted minute; label in the site''s local time.';

-- 023 Trends (step H1, ADR-0029): what the trend page OFM Trend reads.
--   1. HiHi and LoLo limits beside the existing Hi and Lo (alarm_high,
--      alarm_low): four alarm limits per property, edited in Mathesar and
--      published in _meta (alarmHighHigh, alarmLowLow).
--   2. hist.test_data_range: periods of made-up history (the test-history
--      tool, step H1), so that every chart can mark them and the tool can
--      remove exactly them.
--   3. The trend functions. The trend page (role ofm_screens, ADR-0027)
--      reads the historian only through them; ofm_reader may call them too,
--      for Grafana, Power BI or Python.
--      config.fn_trend_tags()      the historised numeric signals, as a tree
--      hist.fn_trend_data()        one signal over a period, at most about
--                                  the number of points the chart can show:
--                                  raw values, or minimum, average and
--                                  maximum per interval (raw data, 1-minute
--                                  or 1-hour averages, chosen by the period)
--      hist.fn_trend_stats()       minimum, maximum, time-weighted average
--                                  and time beyond each limit
--      hist.fn_trend_export()      raw values as CSV lines, in pages
--      hist.fn_historian_tags()    per signal: last value, values in the
--                                  last 24 hours, stored since
--   4. Compression of the 1-minute and 1-hour averages.
-- Times in and out are timestamptz or epoch milliseconds (ADR-0003); local
-- time appears only in the CSV, in the site's time zone, beside UTC.

-- ---------------------------------------------------------------------------
-- 1. HiHi and LoLo
-- ---------------------------------------------------------------------------
ALTER TABLE config.machine_property
  ADD COLUMN alarm_low_low   double precision,
  ADD COLUMN alarm_high_high double precision;
ALTER TABLE config.machine_property ADD CONSTRAINT machine_property_alarm_order CHECK (
  (alarm_low_low IS NULL OR alarm_low IS NULL OR alarm_low_low <= alarm_low) AND
  (alarm_low_low IS NULL OR alarm_high IS NULL OR alarm_low_low < alarm_high) AND
  (alarm_high_high IS NULL OR alarm_high IS NULL OR alarm_high_high >= alarm_high) AND
  (alarm_high_high IS NULL OR alarm_low IS NULL OR alarm_high_high > alarm_low) AND
  (alarm_low_low IS NULL OR alarm_high_high IS NULL OR alarm_low_low < alarm_high_high));
COMMENT ON COLUMN config.machine_property.alarm_low       IS 'Lo limit: below it the trend line turns amber (ADR-0029).';
COMMENT ON COLUMN config.machine_property.alarm_high      IS 'Hi limit: above it the trend line turns amber (ADR-0029).';
COMMENT ON COLUMN config.machine_property.alarm_low_low   IS 'LoLo limit, at or below Lo: below it the trend line turns red (ADR-0029).';
COMMENT ON COLUMN config.machine_property.alarm_high_high IS 'HiHi limit, at or above Hi: above it the trend line turns red (ADR-0029).';

-- The runtime publishes the two new limits in _meta: the view gains them as
-- its last two columns (a view's columns can only be added at the end).
CREATE OR REPLACE VIEW config.vw_runtime_model AS
SELECT
  p.id                         AS property_id,
  m.id                         AS machine_id,
  sa.id                        AS sub_asset_id,
  l.id                         AS line_id,
  a.id                         AS area_id,
  s.id                         AS site_id,
  e.id                         AS enterprise_id,
  concat_ws('/', e.name, s.name, a.name, l.name, m.name, sa.name, p.name) AS topic,
  p.name                       AS property_name,
  p.display_name,
  p.description,
  p.datatype,
  u.code                       AS unit,
  p.low,
  p.high,
  p.alarm_low,
  p.alarm_high,
  p.deadband,
  p.max_publish_interval_ms,
  p.is_historised,
  s.time_zone,
  src.id                       AS source_id,
  src.name                     AS source_name,
  src.protocol,
  src.endpoint,
  src.settings                 AS source_settings,
  src.runtime_name,
  pm.address,
  pm.scale_factor,
  pm.scale_offset,
  CASE WHEN pm.id IS NOT NULL THEN src.name || '|' || pm.address END AS cache_key,
  p.role,
  CASE WHEN p.role = 'heartbeat' THEN coalesce(p.heartbeat_timeout_ms, 5000) END AS heartbeat_timeout_ms,
  concat_ws('/', e.name, s.name, a.name, l.name, m.name) AS machine_topic,
  (SELECT jsonb_agg(jsonb_build_object('priority', r.priority, 'operator', r.operator,
                                       'value', r.value, 'state', ms.name) ORDER BY r.priority)
   FROM config.machine_state_rule r
   JOIN config.machine_state ms ON ms.id = r.state_id
   WHERE r.property_id = p.id) AS state_rules,
  CASE WHEN p.role = 'fault_code' THEN
    (SELECT jsonb_object_agg(fc.fault_code::text, fc.reason_id)
     FROM config.fault_code_reason fc JOIN config.reason rr ON rr.id = fc.reason_id AND rr.retired_at IS NULL
     WHERE fc.machine_id = p.machine_id)
  END AS fault_reasons,
  p.alarm_low_low,
  p.alarm_high_high
FROM config.machine_property p
JOIN config.machine     m  ON m.id = p.machine_id     AND m.retired_at IS NULL
JOIN config.line        l  ON l.id = m.line_id        AND l.retired_at IS NULL
JOIN config.area        a  ON a.id = l.area_id        AND a.retired_at IS NULL
JOIN config.site        s  ON s.id = a.site_id        AND s.retired_at IS NULL
JOIN config.enterprise  e  ON e.id = s.enterprise_id  AND e.retired_at IS NULL
LEFT JOIN config.sub_asset        sa ON sa.id = p.sub_asset_id
LEFT JOIN config.engineering_unit u  ON u.id = p.engineering_unit_id
LEFT JOIN config.plc_mapping      pm ON pm.property_id = p.id
                                    AND pm.retired_at IS NULL AND pm.is_enabled
LEFT JOIN config.source           src ON src.id = pm.source_id
                                    AND src.retired_at IS NULL AND src.is_enabled
WHERE p.retired_at IS NULL
  AND (p.sub_asset_id IS NULL OR sa.retired_at IS NULL)
  AND (pm.id IS NULL OR src.id IS NOT NULL);

-- ---------------------------------------------------------------------------
-- 2. Periods of made-up history
-- ---------------------------------------------------------------------------
CREATE TABLE hist.test_data_range (
  property_id  integer     NOT NULL REFERENCES config.machine_property (id) ON DELETE CASCADE,
  from_ts      timestamptz NOT NULL,
  to_ts        timestamptz NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  note         text,
  PRIMARY KEY (property_id, from_ts),
  CHECK (to_ts > from_ts)
);
COMMENT ON TABLE hist.test_data_range IS
  'Periods in which a property''s history is made up for testing (migrate test-history), not measured. Charts mark them; migrate test-history-remove deletes exactly these values.';
REVOKE ALL ON hist.test_data_range FROM ofm_runtime;
GRANT SELECT ON hist.test_data_range TO ofm_reader;

-- ---------------------------------------------------------------------------
-- 3. Trend functions
-- ---------------------------------------------------------------------------

-- The historised numeric signals (float, int, bool) with their place in the
-- plant, unit, range, four limits and periods of made-up history; for the
-- trend page's tag tree.
CREATE FUNCTION config.fn_trend_tags()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
  SELECT coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
           'id', p.id, 'topic', concat_ws('/', e.name, s.name, a.name, l.name, m.name, sa.name, p.name),
           'enterprise', e.name, 'site', s.name, 'area', a.name,
           'lineId', l.id, 'line', l.name, 'lineName', l.display_name,
           'machineId', m.id, 'machine', m.name, 'machineName', m.display_name, 'subAsset', sa.name,
           'name', p.name, 'displayName', p.display_name, 'description', p.description,
           'datatype', p.datatype, 'unit', u.code, 'low', p.low, 'high', p.high,
           'lo', p.alarm_low, 'hi', p.alarm_high, 'lolo', p.alarm_low_low, 'hihi', p.alarm_high_high,
           'maxIntervalMs', p.max_publish_interval_ms, 'timeZone', s.time_zone,
           'test', (SELECT jsonb_agg(jsonb_build_array(floor(extract(epoch FROM r.from_ts) * 1000)::bigint,
                                                       floor(extract(epoch FROM r.to_ts) * 1000)::bigint) ORDER BY r.from_ts)
                    FROM hist.test_data_range r WHERE r.property_id = p.id)))
         ORDER BY e.name, s.name, a.name, l.name, m.name, sa.name NULLS FIRST, p.name), '[]'::jsonb)
  FROM config.machine_property p
  JOIN config.machine     m  ON m.id = p.machine_id     AND m.retired_at IS NULL
  JOIN config.line        l  ON l.id = m.line_id        AND l.retired_at IS NULL
  JOIN config.area        a  ON a.id = l.area_id        AND a.retired_at IS NULL
  JOIN config.site        s  ON s.id = a.site_id        AND s.retired_at IS NULL
  JOIN config.enterprise  e  ON e.id = s.enterprise_id  AND e.retired_at IS NULL
  LEFT JOIN config.sub_asset        sa ON sa.id = p.sub_asset_id
  LEFT JOIN config.engineering_unit u  ON u.id = p.engineering_unit_id
  WHERE p.retired_at IS NULL AND p.is_historised AND p.datatype IN ('float', 'int', 'bool')
    AND (p.sub_asset_id IS NULL OR sa.retired_at IS NULL)
$$;
COMMENT ON FUNCTION config.fn_trend_tags() IS
  'The historised numeric signals for the trend page: place in the plant, unit, range, limits (lo, hi, lolo, hihi), periods of made-up history (ADR-0029).';

-- The interval of one point when a period is shown with about p_points
-- points: the next "round" interval (1 s, 2 s, 5 s ... 1 day, 1 week).
CREATE FUNCTION hist.fn_trend_bucket(p_from timestamptz, p_to timestamptz, p_points integer)
RETURNS interval
LANGUAGE sql IMMUTABLE
AS $$
  SELECT make_interval(secs => coalesce(
    (SELECT s FROM unnest(ARRAY[1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 10800,
                                21600, 43200, 86400, 172800, 604800]) AS s
     WHERE s >= extract(epoch FROM p_to - p_from) / greatest(coalesce(p_points, 1000), 1)
     ORDER BY s LIMIT 1), 604800))
$$;
COMMENT ON FUNCTION hist.fn_trend_bucket(timestamptz, timestamptz, integer) IS
  'The round interval (1 s ... 1 week) that shows a period with at most about p_points points.';

-- One signal over [p_from, p_to). Returns either
--   source 'raw': every stored value (v), plus the last value before p_from,
--     so the line starts at the left edge; when the period holds at most
--     4 x p_points values;
--   or one row per interval (bucket_s seconds): average v, minimum v_min,
--     maximum v_max, worst quality q, number of values n; from raw values
--     (source 'raw'), 1-minute averages ('1m') or 1-hour averages ('1h'),
--     the coarsest that still gives the interval. Raw values older than the
--     raw retention are gone: then the 1-minute averages are used.
-- p_bucket forces the interval (for an export "as shown"). Intervals of an
-- hour or more follow the site's local day (time zone of the site).
CREATE FUNCTION hist.fn_trend_data(p_property_id integer, p_from timestamptz, p_to timestamptz,
                                   p_points integer DEFAULT 1000, p_bucket interval DEFAULT NULL)
RETURNS TABLE (t_ms bigint, v double precision, v_min double precision, v_max double precision,
               q smallint, n bigint, source text, bucket_s integer)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET jit = off
AS $$
DECLARE
  pts integer := least(greatest(coalesce(p_points, 1000), 10), 10000);
  b   interval;
  bs  integer;
  tz  text;
  raw_n bigint := 1;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN RETURN; END IF;
  IF p_to - p_from > interval '20 years' THEN
    RAISE EXCEPTION 'a trend period may be at most 20 years';
  END IF;
  b := coalesce(p_bucket, hist.fn_trend_bucket(p_from, p_to, pts));
  IF b < interval '1 second' THEN b := interval '1 second'; END IF;
  SELECT st.time_zone INTO tz
  FROM config.machine_property p JOIN config.machine m ON m.id = p.machine_id JOIN config.line l ON l.id = m.line_id
  JOIN config.area a ON a.id = l.area_id JOIN config.site st ON st.id = a.site_id
  WHERE p.id = p_property_id;
  IF tz IS NULL THEN RETURN; END IF;

  IF b < interval '1 minute' THEN
    IF p_bucket IS NULL THEN
      SELECT count(*) INTO raw_n
      FROM (SELECT 1 FROM hist.measurement m
            WHERE m.property_id = p_property_id AND m.ts >= p_from AND m.ts < p_to LIMIT pts * 4 + 1) x;
      IF raw_n BETWEEN 1 AND pts * 4 THEN
        RETURN QUERY
        (SELECT floor(extract(epoch FROM m.ts) * 1000)::bigint, m.value, NULL::double precision, NULL::double precision,
                m.quality, 1::bigint, 'raw'::text, 0
         FROM hist.measurement m
         WHERE m.property_id = p_property_id AND m.ts < p_from AND m.ts >= p_from - interval '1 day'
         ORDER BY m.ts DESC LIMIT 1)
        UNION ALL
        (SELECT floor(extract(epoch FROM m.ts) * 1000)::bigint, m.value, NULL, NULL, m.quality, 1::bigint, 'raw', 0
         FROM hist.measurement m
         WHERE m.property_id = p_property_id AND m.ts >= p_from AND m.ts < p_to
         ORDER BY m.ts);
        RETURN;
      END IF;
    ELSE
      SELECT count(*) INTO raw_n
      FROM (SELECT 1 FROM hist.measurement m
            WHERE m.property_id = p_property_id AND m.ts >= p_from AND m.ts < p_to LIMIT 1) x;
    END IF;
    IF raw_n > 0 THEN
      bs := extract(epoch FROM b)::integer;
      RETURN QUERY
      SELECT floor(extract(epoch FROM public.time_bucket(b, m.ts)) * 1000)::bigint, avg(m.value), min(m.value), max(m.value),
             max(m.quality), count(*), 'raw'::text, bs
      FROM hist.measurement m
      WHERE m.property_id = p_property_id AND m.ts >= p_from AND m.ts < p_to
      GROUP BY 1 ORDER BY 1;
      RETURN;
    END IF;
    b := interval '1 minute';
  END IF;

  bs := extract(epoch FROM b)::integer;
  IF b < interval '1 hour' THEN
    RETURN QUERY
    SELECT floor(extract(epoch FROM public.time_bucket(b, g.bucket)) * 1000)::bigint,
           sum(g.avg_value * g.samples) / nullif(sum(g.samples) FILTER (WHERE g.avg_value IS NOT NULL), 0),
           min(g.min_value), max(g.max_value), max(g.worst_quality)::smallint, sum(g.samples)::bigint, '1m'::text, bs
    FROM hist.measurement_1m g
    WHERE g.property_id = p_property_id AND g.bucket >= public.time_bucket(b, p_from) AND g.bucket < p_to
    GROUP BY 1 ORDER BY 1;
  ELSE
    RETURN QUERY
    SELECT floor(extract(epoch FROM public.time_bucket(b, g.bucket, tz)) * 1000)::bigint,
           sum(g.avg_value * g.samples) / nullif(sum(g.samples) FILTER (WHERE g.avg_value IS NOT NULL), 0),
           min(g.min_value), max(g.max_value), max(g.worst_quality)::smallint, sum(g.samples)::bigint, '1h'::text, bs
    FROM hist.measurement_1h g
    WHERE g.property_id = p_property_id AND g.bucket >= public.time_bucket(b, p_from, tz) AND g.bucket < p_to
    GROUP BY 1 ORDER BY 1;
  END IF;
END $$;
COMMENT ON FUNCTION hist.fn_trend_data(integer, timestamptz, timestamptz, integer, interval) IS
  'One signal over [from, to) for a chart of about p_points points: raw values, or avg/min/max per interval from raw, 1-minute or 1-hour data (ADR-0029).';

-- Statistics of one signal over [p_from, p_to): number of values, minimum,
-- maximum, time-weighted average, and seconds with a value, above Hi and
-- HiHi, below Lo and LoLo (today's limits). Up to 7 days from the raw
-- values: each value counts until the next one, but at most twice the
-- signal's publish interval (after that the signal was silent: no time is
-- counted). Longer periods from the 1-minute averages (source '1m'): each
-- minute with values counts 60 s, beyond a limit when its average is (an
-- approximation, so the page shows these figures with "≈").
CREATE FUNCTION hist.fn_trend_stats(p_property_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (source text, n bigint, v_min double precision, v_max double precision, v_avg double precision,
               s_covered double precision, s_above_hi double precision, s_above_hihi double precision,
               s_below_lo double precision, s_below_lolo double precision)
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET jit = off
AS $$
DECLARE
  lim record;
  raw_any boolean;
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN RETURN; END IF;
  SELECT p.alarm_low AS lo, p.alarm_high AS hi, p.alarm_low_low AS lolo, p.alarm_high_high AS hihi,
         make_interval(secs => 2 * p.max_publish_interval_ms / 1000.0) AS hold
  INTO lim FROM config.machine_property p WHERE p.id = p_property_id;
  IF NOT FOUND THEN RETURN; END IF;
  raw_any := EXISTS (SELECT 1 FROM hist.measurement m WHERE m.property_id = p_property_id AND m.ts >= p_from AND m.ts < p_to);
  IF p_to - p_from <= interval '7 days' AND raw_any THEN
    RETURN QUERY
    WITH pts AS (
      (SELECT m.ts, m.value FROM hist.measurement m
       WHERE m.property_id = p_property_id AND m.ts < p_from AND m.ts >= p_from - interval '1 day'
       ORDER BY m.ts DESC LIMIT 1)
      UNION ALL
      (SELECT m.ts, m.value FROM hist.measurement m
       WHERE m.property_id = p_property_id AND m.ts >= p_from AND m.ts < p_to)
    ), seg AS (
      SELECT x.ts, x.value,
             extract(epoch FROM greatest(least(coalesce(lead(x.ts) OVER (ORDER BY x.ts), p_to), p_to, x.ts + lim.hold, now())
                                         - greatest(x.ts, p_from), interval '0'))::double precision AS d
      FROM pts x
    )
    SELECT 'raw'::text, count(*) FILTER (WHERE seg.ts >= p_from), min(seg.value), max(seg.value),
           sum(seg.value * seg.d) / nullif(sum(seg.d) FILTER (WHERE seg.value IS NOT NULL), 0),
           coalesce(sum(seg.d) FILTER (WHERE seg.value IS NOT NULL), 0),
           coalesce(sum(seg.d) FILTER (WHERE seg.value > lim.hi), 0), coalesce(sum(seg.d) FILTER (WHERE seg.value > lim.hihi), 0),
           coalesce(sum(seg.d) FILTER (WHERE seg.value < lim.lo), 0), coalesce(sum(seg.d) FILTER (WHERE seg.value < lim.lolo), 0)
    FROM seg;
  ELSE
    RETURN QUERY
    SELECT '1m'::text, coalesce(sum(g.samples), 0)::bigint, min(g.min_value), max(g.max_value),
           sum(g.avg_value * g.samples) / nullif(sum(g.samples) FILTER (WHERE g.avg_value IS NOT NULL), 0),
           60.0::double precision * count(*) FILTER (WHERE g.avg_value IS NOT NULL),
           60.0::double precision * count(*) FILTER (WHERE g.avg_value > lim.hi), 60.0::double precision * count(*) FILTER (WHERE g.avg_value > lim.hihi),
           60.0::double precision * count(*) FILTER (WHERE g.avg_value < lim.lo), 60.0::double precision * count(*) FILTER (WHERE g.avg_value < lim.lolo)
    FROM hist.measurement_1m g
    WHERE g.property_id = p_property_id AND g.bucket >= p_from AND g.bucket < p_to;
  END IF;
END $$;
COMMENT ON FUNCTION hist.fn_trend_stats(integer, timestamptz, timestamptz) IS
  'Count, min, max, time-weighted average and seconds beyond each limit of one signal over [from, to); raw up to 7 days, else from 1-minute averages (approximate) (ADR-0029).';

-- Raw values of several signals over [p_from, p_to) as CSV lines, signal by
-- signal and in time order: local time (site), UTC epoch ms, topic, name,
-- value, unit, quality. In pages: the next page starts after the last
-- (property_id, ts) of the previous one.
CREATE FUNCTION hist.fn_trend_export(p_property_ids integer[], p_from timestamptz, p_to timestamptz,
                                     p_after_id integer DEFAULT NULL, p_after_ts timestamptz DEFAULT NULL,
                                     p_limit integer DEFAULT 50000)
RETURNS TABLE (property_id integer, ts timestamptz, csv text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET jit = off
AS $$
  WITH t AS (
    SELECT p.id, st.time_zone AS tz,
           '"' || replace(concat_ws('/', e.name, st.name, a.name, l.name, m.name, sa.name, p.name), '"', '""') || '"' AS topic,
           '"' || replace(p.display_name, '"', '""') || '"' AS dn,
           '"' || replace(coalesce(u.code, ''), '"', '""') || '"' AS unit
    FROM config.machine_property p
    JOIN config.machine m ON m.id = p.machine_id JOIN config.line l ON l.id = m.line_id
    JOIN config.area a ON a.id = l.area_id JOIN config.site st ON st.id = a.site_id
    JOIN config.enterprise e ON e.id = st.enterprise_id
    LEFT JOIN config.sub_asset sa ON sa.id = p.sub_asset_id
    LEFT JOIN config.engineering_unit u ON u.id = p.engineering_unit_id
    WHERE p.id = ANY (p_property_ids)
  )
  SELECT m.property_id, m.ts,
         to_char(m.ts AT TIME ZONE t.tz, 'YYYY-MM-DD HH24:MI:SS.MS') || ',' ||
         floor(extract(epoch FROM m.ts) * 1000)::bigint || ',' || t.topic || ',' || t.dn || ',' ||
         coalesce(m.value::text, '') || ',' || t.unit || ',' ||
         CASE m.quality WHEN 0 THEN 'good' WHEN 1 THEN 'uncertain' ELSE 'bad' END
  FROM hist.measurement m JOIN t ON t.id = m.property_id
  WHERE m.property_id = ANY (p_property_ids) AND m.ts >= p_from AND m.ts < p_to
    AND (p_after_id IS NULL OR (m.property_id, m.ts) > (p_after_id, p_after_ts))
  ORDER BY m.property_id, m.ts
  LIMIT least(greatest(coalesce(p_limit, 50000), 1), 100000)
$$;
COMMENT ON FUNCTION hist.fn_trend_export(integer[], timestamptz, timestamptz, integer, timestamptz, integer) IS
  'Raw values as CSV lines (local time, UTC ms, topic, name, value, unit, quality), by signal then time, in pages after (property_id, ts) (ADR-0029).';

-- The historian's signals at a glance: per historised signal its last
-- stored value and when, the number of values in the last 24 hours, and
-- since when it has history (from the 1-hour averages, which are kept
-- longest).
CREATE FUNCTION hist.fn_historian_tags()
RETURNS TABLE (property_id integer, last_ms bigint, last_value double precision, last_quality smallint,
               values_24h bigint, since_ms bigint)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET jit = off
AS $$
  SELECT p.id, floor(extract(epoch FROM lv.ts) * 1000)::bigint, lv.value, lv.quality,
         (SELECT count(*) FROM hist.measurement m WHERE m.property_id = p.id AND m.ts >= now() - interval '24 hours'),
         (SELECT floor(extract(epoch FROM min(h.bucket)) * 1000)::bigint FROM hist.measurement_1h h WHERE h.property_id = p.id)
  FROM config.machine_property p
  LEFT JOIN LATERAL (SELECT m.ts, m.value, m.quality FROM hist.measurement m
                     WHERE m.property_id = p.id AND m.ts >= now() - interval '7 days'
                     ORDER BY m.ts DESC LIMIT 1) lv ON true
  WHERE p.retired_at IS NULL AND p.is_historised AND p.datatype IN ('float', 'int', 'bool')
$$;
COMMENT ON FUNCTION hist.fn_historian_tags() IS
  'Per historised numeric signal: last value of the last 7 days and its time, values in the last 24 hours, history since (ADR-0029).';

-- Who may call them: the trend page (ofm_screens) and readers.
REVOKE ALL ON FUNCTION config.fn_trend_tags(), hist.fn_trend_data(integer, timestamptz, timestamptz, integer, interval),
  hist.fn_trend_stats(integer, timestamptz, timestamptz),
  hist.fn_trend_export(integer[], timestamptz, timestamptz, integer, timestamptz, integer), hist.fn_historian_tags()
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION config.fn_trend_tags(), hist.fn_trend_data(integer, timestamptz, timestamptz, integer, interval),
  hist.fn_trend_stats(integer, timestamptz, timestamptz),
  hist.fn_trend_export(integer[], timestamptz, timestamptz, integer, timestamptz, integer), hist.fn_historian_tags()
TO ofm_screens, ofm_reader;

-- ---------------------------------------------------------------------------
-- 4. Compress the 1-minute and 1-hour averages (found with the made-up year,
--    step H1): migration 011 compressed the raw values but not the averages,
--    so a year of one signal's minutes took about 20 times the space of its
--    compressed raw values (2.6 GB against 129 MB for the demo line). Like
--    the raw values, averages are now stored in column format, by signal,
--    once they are older than 35 days: beyond the 30-day window the refresh
--    policy recalculates, so recent averages stay quick to update. Typically
--    8 times smaller; queries are unchanged.
-- ---------------------------------------------------------------------------
ALTER MATERIALIZED VIEW hist.measurement_1m SET (
  timescaledb.enable_columnstore = true,
  timescaledb.segmentby = 'property_id',
  timescaledb.orderby = 'bucket DESC'
);
ALTER MATERIALIZED VIEW hist.measurement_1h SET (
  timescaledb.enable_columnstore = true,
  timescaledb.segmentby = 'property_id',
  timescaledb.orderby = 'bucket DESC'
);
CALL add_columnstore_policy('hist.measurement_1m', after => INTERVAL '35 days');
CALL add_columnstore_policy('hist.measurement_1h', after => INTERVAL '35 days');

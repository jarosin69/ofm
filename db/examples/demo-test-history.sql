-- Made-up history for the simulated packing line (step H1, ADR-0029): one
-- year of plausible values, so that trends of a month or a year, the
-- 1-minute and 1-hour averages and the retention can be tried before the
-- real history is that long. Run with
--   docker compose run --rm migrate test-history
-- and remove with
--   docker compose run --rm migrate test-history-remove
-- (migrate demo-remove removes it too, with the rest of the demo).
--
-- What is made up: one value per minute for the year that ends where the
-- demo line's real history begins, for each machine's speed, speed
-- setpoint, state code and counters, the checkweigher's last weight and the
-- palletiser's pallets: about 20 million values. Only values in
-- hist.measurement: no machine state events, counts, work orders or
-- reasons, so OEE, downtime and the line view are not affected. Every
-- period is recorded in hist.test_data_range, and the trend page marks it
-- "made-up test data".
--
-- The pattern follows the demo (demo/packing-line/README.md): Monday to
-- Friday 06:00-21:30 production and 21:30-22:00 cleaning, Melbourne time;
-- one product a day (mix150, mix250 or mix500); speed 88-96 % of the rate;
-- about 7 % of ten-minute blocks stopped by a fault; on about one day in 40
-- the filler runs too fast (107-111 cartons/min) from 10:00 to 11:00, so its
-- Hi and HiHi limits (105, 110) show. Repeatable: the same year gives the
-- same values (pseudo-random from hashes of the time, not random()).

CREATE TEMP TABLE th_prop AS
SELECT p.id, m.name AS machine, p.name AS prop
FROM config.machine_property p
JOIN config.machine m ON m.id = p.machine_id AND m.retired_at IS NULL
JOIN config.line l ON l.id = m.line_id AND l.name = 'packline01' AND l.retired_at IS NULL
JOIN config.area a ON a.id = l.area_id AND a.name = 'packing'
JOIN config.site s ON s.id = a.site_id AND s.name = 'melbourne'
JOIN config.enterprise e ON e.id = s.enterprise_id AND e.name = 'acme'
WHERE p.retired_at IS NULL
  AND p.name IN ('speed', 'speed_setpoint', 'state_code', 'count_in', 'count_good', 'count_reject', 'last_weight', 'pallets');

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM th_prop) THEN
    RAISE EXCEPTION 'The demo line is not in the model: run "migrate demo" first';
  END IF;
  IF EXISTS (SELECT 1 FROM hist.test_data_range r JOIN th_prop p ON p.id = r.property_id) THEN
    RAISE EXCEPTION 'The demo line already has made-up history: run "migrate test-history-remove" first';
  END IF;
END $$;

-- The year ends where the real history of these signals begins (or now).
CREATE TEMP TABLE th_span AS
SELECT t1 - interval '365 days' AS t0, t1
FROM (SELECT date_trunc('minute', coalesce(min(f.ts), now())) AS t1
      FROM th_prop p
      LEFT JOIN LATERAL (SELECT m.ts FROM hist.measurement m WHERE m.property_id = p.id ORDER BY m.ts LIMIT 1) f ON true) x;

-- Pseudo-random 0..1 from a text (repeatable).
CREATE FUNCTION pg_temp.th_rand(k text) RETURNS double precision LANGUAGE sql IMMUTABLE AS
$$ SELECT (('x' || substr(md5(k), 1, 8))::bit(32)::bigint) / 4294967296.0 $$;

-- One row per minute: what the line does.
CREATE TEMP TABLE th_minute AS
WITH g AS (
  SELECT t, (t AT TIME ZONE 'Australia/Melbourne') AS lt
  FROM th_span, generate_series(t0, t1 - interval '1 minute', interval '1 minute') AS t
), d AS (
  SELECT t, lt, lt::date AS day, extract(isodow FROM lt) AS dow, lt::time AS tod,
         floor(pg_temp.th_rand('product' || lt::date) * 3)::int AS product,
         0.88 + 0.08 * pg_temp.th_rand('perf' || lt::date) AS perf,
         pg_temp.th_rand('stop' || floor(extract(epoch FROM t) / 600)) < 0.07 AS stopped,
         pg_temp.th_rand('fast' || lt::date) < 0.025 AND lt::time >= time '10:00' AND lt::time < time '11:00' AS too_fast,
         pg_temp.th_rand('n' || t) AS r1, pg_temp.th_rand('m' || t) AS r2, pg_temp.th_rand('o' || t) AS r3
  FROM g
)
SELECT t, product,
       CASE product WHEN 2 THEN 80.0 ELSE 100.0 END AS rate,           -- filler cartons/min (4,800 or 6,000 an hour)
       CASE product WHEN 0 THEN 150.0 WHEN 1 THEN 250.0 ELSE 500.0 END AS target_g,
       CASE WHEN dow > 5 OR tod < time '06:00' OR tod >= time '22:00' THEN 'idle'
            WHEN tod >= time '21:30' THEN 'cleaning'
            WHEN stopped THEN 'fault'
            ELSE 'running' END AS state,
       perf, too_fast, r1, r2, r3
FROM d;

-- One row per machine and minute.
CREATE TEMP TABLE th_machine AS
SELECT mm.machine, x.t, x.state,
       CASE WHEN x.state <> 'running' THEN 0
            WHEN mm.machine = 'filler' AND x.too_fast THEN 107 + 4 * x.r1
            ELSE x.rate * x.perf * (0.99 + 0.02 * x.r1) * mm.ratio END AS speed,
       CASE WHEN mm.machine = 'filler' THEN x.rate ELSE mm.rated END AS setpoint,
       mm.reject, x.target_g, x.r2, x.r3
FROM th_minute x
CROSS JOIN (VALUES ('erector', 1.0, 120.0, 0.005), ('filler', 1.0, 0.0, 0.010), ('checkweigher', 1.0, 120.0, 0.015),
                   ('closer', 1.0, 120.0, 0.005), ('case_packer', 0.1, 12.0, 0.0), ('palletiser', 0.1, 15.0, 0.0))
           AS mm (machine, ratio, rated, reject);

CREATE TEMP TABLE th_count AS
SELECT machine, t, state, speed, setpoint, target_g, r2, r3,
       sum(speed) OVER w AS c_in,
       sum(speed * (1 - reject)) OVER w AS c_good,
       sum(speed * reject) OVER w AS c_reject
FROM th_machine
WINDOW w AS (PARTITION BY machine ORDER BY t);

-- The checkweigher's last weight: around the product's target, held while
-- the line stands.
CREATE TEMP TABLE th_weight AS
SELECT t, first_value(w) OVER (PARTITION BY grp ORDER BY t) AS w
FROM (SELECT t, w, count(w) OVER (ORDER BY t) AS grp
      FROM (SELECT t, CASE WHEN state = 'running'
                           THEN round((target_g * (1 + 0.012 * ((r2 + r3) - 1) * 1.7))::numeric, 1)::double precision END AS w
            FROM th_count WHERE machine = 'checkweigher') a) b;

INSERT INTO hist.measurement (ts, property_id, value, quality, ts_source)
SELECT c.t, p.id,
       CASE p.prop
         WHEN 'speed'          THEN round(c.speed::numeric, 1)::double precision
         WHEN 'speed_setpoint' THEN c.setpoint
         WHEN 'state_code'     THEN CASE c.state WHEN 'running' THEN 1 WHEN 'idle' THEN 2 WHEN 'fault' THEN 5 ELSE 7 END
         WHEN 'count_in'       THEN floor(c.c_in)
         WHEN 'count_good'     THEN floor(c.c_good)
         WHEN 'count_reject'   THEN floor(c.c_reject)
       END,
       0, 1
FROM th_count c JOIN th_prop p ON p.machine = c.machine
WHERE p.prop IN ('speed', 'speed_setpoint', 'state_code', 'count_in', 'count_good', 'count_reject');

INSERT INTO hist.measurement (ts, property_id, value, quality, ts_source)
SELECT w.t, p.id, w.w, 0, 1
FROM th_weight w JOIN th_prop p ON p.machine = 'checkweigher' AND p.prop = 'last_weight'
WHERE w.w IS NOT NULL;

INSERT INTO hist.measurement (ts, property_id, value, quality, ts_source)
SELECT c.t, p.id, floor(c.c_good / 60), 0, 1
FROM th_count c JOIN th_prop p ON p.machine = 'palletiser' AND p.prop = 'pallets'
WHERE c.machine = 'palletiser';

INSERT INTO hist.test_data_range (property_id, from_ts, to_ts, note)
SELECT p.id, s.t0, s.t1, 'migrate test-history: one value a minute, made up'
FROM th_prop p, th_span s;

SELECT 'Made-up history: ' || count(DISTINCT r.property_id) || ' signals, '
       || to_char(min(r.from_ts) AT TIME ZONE 'Australia/Melbourne', 'DD/MM/YYYY HH24:MI') || ' to '
       || to_char(max(r.to_ts) AT TIME ZONE 'Australia/Melbourne', 'DD/MM/YYYY HH24:MI') || ' (Melbourne)' AS result
FROM hist.test_data_range r JOIN th_prop p ON p.id = r.property_id;

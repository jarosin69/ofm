-- Made-up operations history for the simulated packing line (step R1
-- follow-up, migration 032): months of machine states, stops with their
-- reasons, work orders with changeovers and per-minute counts, so that the
-- report page, Grafana Line OEE and the trend's bands have history before the
-- line's real history begins. Run with
--   docker compose run --rm migrate test-operations [months]   (1-12, default 3)
-- and remove with
--   docker compose run --rm migrate test-operations-remove
-- (migrate demo-remove removes it too, with the rest of the demo). The number
-- of months comes in as the setting ofm.test_months.
--
-- Where: the whole months before the local day on which the demo line's real
-- history begins (its first state event, count or work order event; today
-- if it has none), so it never mixes with real history. Refused while
-- made-up operations exist: remove them first. Recorded in
-- hist.test_operation_range; the report and Grafana mark the period.
--
-- How the line runs (demo/packing-line/README.md): the line's own schedule
-- (Monday to Friday 06:00-21:30 production, 21:30-22:00 cleaning); orders of
-- 20,000-40,000 cartons in the cycle mix250, mix500, mix150, mix250, mix150,
-- mix500, mix250, with changeovers of 31-46 minutes by product pair; speed
-- 86 % (mix150), 89.5 % (mix250) and 95 % (mix500) of the rated speed;
-- 2.5 % rejects at the checkweigher. Stops, as on the simulator: a stop of a
-- machine after the filler blocks the filler, one before it starves it. Per
-- production hour about 0.75 closer carton jams (5 min), 0.12 case packer
-- servo faults (22 min), 0.07 checkweigher load cell faults (28 min), 0.1
-- pallets waiting for removal (12 min), 0.03 erector glue faults (36 min),
-- 0.05 filler counting head faults (17 min), 1.9 short filler stops nobody
-- codes (1.2 min) and 0.06 longer case packer stops nobody codes (13 min).
-- About 70 % of reasons come from the PLC, the rest from the demo people.
-- A story for the comparison: from the middle of the period the closer jams
-- half as often, with an annotation "Closer guide rail replaced" that day.
-- Repeatable: the same period gives the same history (pseudo-random from
-- hashes of the time, not random()).

DROP TABLE IF EXISTS pg_temp.to_ev, pg_temp.to_rs, pg_temp.to_ord, pg_temp.to_run;
CREATE TEMP TABLE to_ev (machine_id integer, ts timestamptz, state_id smallint, PRIMARY KEY (machine_id, ts)) ON COMMIT DROP;
CREATE TEMP TABLE to_rs (machine_id integer, ts timestamptz, reason_id integer, by_name text) ON COMMIT DROP;
CREATE TEMP TABLE to_ord (n integer, wo text, material_id integer, qty integer, planned_start timestamptz,
                          started timestamptz, co_end timestamptz, completed timestamptz) ON COMMIT DROP;
CREATE TEMP TABLE to_run (t0 timestamptz, t1 timestamptz, rate_h double precision) ON COMMIT DROP;

-- a pseudo-random number in [0, 1) from a text
CREATE OR REPLACE FUNCTION pg_temp.u(k text) RETURNS double precision LANGUAGE sql IMMUTABLE AS
$$ SELECT (('x' || substr(md5(k), 1, 8))::bit(32)::bigint) / 4294967296.0 $$;

DO $$
DECLARE
  v_line integer; v_tz text;
  er integer; fi integer; cw integer; cl integer; cp integer; pa integer;
  p_good integer; p_rej integer;
  v_months integer := coalesce(nullif(current_setting('ofm.test_months', true), ''), '3')::integer;
  v_first timestamptz; v_end timestamptz; v_start timestamptz; v_mid timestamptz;
  d date;
  w record;
  t timestamptz; run_end timestamptz; prod_end timestamptz; fin timestamptz;
  cur_sku text := NULL; cur_mat integer; cur_left double precision := 0; cur_n integer := 0;
  rate double precision; factor double precision; good_rate double precision;
  cycle text[] := ARRAY['mix250', 'mix500', 'mix150', 'mix250', 'mix150', 'mix500', 'mix250'];
  qi integer := 0;
  speed jsonb := '{"mix150": 0.86, "mix250": 0.895, "mix500": 0.95}';
  co jsonb := '{"mix500>mix150": 44, "mix150>mix500": 46, "mix250>mix500": 41, "mix500>mix250": 38, "mix150>mix250": 33, "mix250>mix150": 31}';
  kinds jsonb;
  total double precision; pick double precision; dt double precision; dur double precision;
  k jsonb; kk jsonb; m_id integer; m_name text;
  s timestamptz; e timestamptz; key text; i integer;
  down integer[];
  people text[] := ARRAY['Alex Demo', 'Billie Demo', 'Chris Demo'];
  co_min integer; sku text; mat integer;
  n_ev integer; n_rs integer; n_ord integer; n_cnt integer;
BEGIN
  SELECT l.id, s2.time_zone INTO v_line, v_tz
  FROM config.line l JOIN config.area a ON a.id = l.area_id AND a.name = 'packing'
  JOIN config.site s2 ON s2.id = a.site_id AND s2.name = 'melbourne'
  JOIN config.enterprise en ON en.id = s2.enterprise_id AND en.name = 'acme'
  WHERE l.name = 'packline01' AND l.retired_at IS NULL;
  IF v_line IS NULL THEN
    RAISE EXCEPTION 'the demo line is not loaded: run "docker compose run --rm migrate demo" first';
  END IF;
  IF v_months NOT BETWEEN 1 AND 12 THEN
    RAISE EXCEPTION 'months must be 1 to 12, not %', v_months;
  END IF;
  IF EXISTS (SELECT 1 FROM hist.test_operation_range WHERE line_id = v_line) THEN
    RAISE EXCEPTION 'made-up operations already exist for the demo line: remove them first ("docker compose run --rm migrate test-operations-remove")';
  END IF;
  SELECT max(id) FILTER (WHERE name = 'erector'), max(id) FILTER (WHERE name = 'filler'), max(id) FILTER (WHERE name = 'checkweigher'),
         max(id) FILTER (WHERE name = 'closer'), max(id) FILTER (WHERE name = 'case_packer'), max(id) FILTER (WHERE name = 'palletiser')
    INTO er, fi, cw, cl, cp, pa
  FROM config.machine WHERE line_id = v_line AND retired_at IS NULL;
  SELECT max(p.id) FILTER (WHERE m.name = 'closer' AND p.name = 'count_good'), max(p.id) FILTER (WHERE m.name = 'checkweigher' AND p.name = 'count_reject')
    INTO p_good, p_rej
  FROM config.machine_property p JOIN config.machine m ON m.id = p.machine_id
  WHERE m.line_id = v_line AND p.retired_at IS NULL;
  IF fi IS NULL OR cl IS NULL OR p_good IS NULL OR p_rej IS NULL THEN
    RAISE EXCEPTION 'the demo line is not complete: run "docker compose run --rm migrate demo" again';
  END IF;
  down := ARRAY[cw, cl, cp, pa];

  -- the period: whole months up to the local day of the first real history
  v_first := least(
    (SELECT min(ev.ts) FROM hist.machine_state_event ev WHERE ev.machine_id IN (er, fi, cw, cl, cp, pa)),
    (SELECT min(c.ts) FROM hist.production_count c WHERE c.property_id IN
       (SELECT p.id FROM config.machine_property p JOIN config.machine m ON m.id = p.machine_id WHERE m.line_id = v_line)),
    (SELECT min(x.ts) FROM hist.work_order_event x JOIN config.work_order o ON o.id = x.work_order_id WHERE o.line_id = v_line));
  v_end := (date_trunc('day', coalesce(v_first, now()) AT TIME ZONE v_tz)) AT TIME ZONE v_tz;
  v_start := (date_trunc('day', v_end AT TIME ZONE v_tz) - make_interval(months => v_months)) AT TIME ZONE v_tz;
  v_mid := v_start + (v_end - v_start) / 2;

  kinds := jsonb_build_array(
    jsonb_build_object('m', cl, 'r', 'closer_carton_jam', 'rate', 0.75, 'min', 5.2),
    jsonb_build_object('m', cp, 'r', 'case_packer_servo_fault', 'rate', 0.12, 'min', 22.0),
    jsonb_build_object('m', cw, 'r', 'checkweigher_load_cell_fault', 'rate', 0.07, 'min', 28.0),
    jsonb_build_object('m', pa, 'r', 'palletiser_waiting_for_removal', 'rate', 0.10, 'min', 11.8),
    jsonb_build_object('m', er, 'r', 'erector_glue_system_fault', 'rate', 0.03, 'min', 36.0),
    jsonb_build_object('m', fi, 'r', 'filler_counting_head_fault', 'rate', 0.05, 'min', 16.7),
    jsonb_build_object('m', fi, 'r', NULL, 'rate', 1.9, 'min', 1.2),
    jsonb_build_object('m', cp, 'r', NULL, 'rate', 0.06, 'min', 13.0));

  FOR w IN
    SELECT p.starts_at AS ws, p.ends_at AS we,
           (SELECT min(c.starts_at) FROM config.fn_line_schedule(v_line, v_start, v_end) c
            WHERE c.kind = 'cleaning' AND c.starts_at >= p.starts_at AND c.starts_at < p.ends_at) AS clean_at
    FROM config.fn_line_schedule(v_line, v_start, v_end) p
    WHERE p.kind = 'production' AND p.ends_at > p.starts_at
    ORDER BY p.starts_at
  LOOP
    t := w.ws;
    prod_end := coalesce(w.clean_at, w.we);
    FOREACH m_id IN ARRAY ARRAY[er, fi, cw, cl, cp, pa] LOOP
      INSERT INTO to_ev VALUES (m_id, t, 1) ON CONFLICT DO NOTHING;
    END LOOP;
    -- no order yet (the first day): start one, with its changeover
    IF cur_sku IS NULL THEN
      qi := qi + 1; sku := cycle[1 + (qi - 1) % 7];
      SELECT id INTO cur_mat FROM config.material WHERE code = sku;
      cur_sku := sku; cur_n := cur_n + 1;
      cur_left := CASE WHEN sku = 'mix500' THEN 20000 + 4000 * floor(pg_temp.u('q' || cur_n) * 2) ELSE 24000 + 6000 * floor(pg_temp.u('q' || cur_n) * 3) END;
      INSERT INTO to_ord (n, material_id, qty, planned_start, started)
        VALUES (cur_n, cur_mat, cur_left::integer, CASE WHEN pg_temp.u('ps' || cur_n) < 0.65 THEN t - make_interval(mins => floor(pg_temp.u('pd' || cur_n) * 31)::integer - 5) END, t);
      INSERT INTO to_ev VALUES (fi, t + interval '1 second', 6) ON CONFLICT DO NOTHING;
      t := t + interval '30 minutes';
      UPDATE to_ord SET co_end = t WHERE n = cur_n;
      INSERT INTO to_ev VALUES (fi, t, 1) ON CONFLICT DO NOTHING;
    END IF;
    i := 0;
    WHILE t < prod_end LOOP
      i := i + 1;
      key := extract(epoch FROM t)::bigint || ':' || i;
      -- the next stop: one draw for when, one for which
      total := 0;
      FOR k IN SELECT * FROM jsonb_array_elements(kinds) LOOP
        total := total + (k->>'rate')::double precision * CASE WHEN k->>'r' = 'closer_carton_jam' AND t >= v_mid THEN 0.45 ELSE 1 END;
      END LOOP;
      dt := -ln(1 - pg_temp.u('t' || key)) / total * 3600;
      pick := pg_temp.u('k' || key) * total;
      kk := NULL;
      FOR k IN SELECT * FROM jsonb_array_elements(kinds) LOOP
        pick := pick - (k->>'rate')::double precision * CASE WHEN k->>'r' = 'closer_carton_jam' AND t >= v_mid THEN 0.45 ELSE 1 END;
        IF pick <= 0 AND kk IS NULL THEN kk := k; END IF;
      END LOOP;
      kk := coalesce(kk, kinds->0);
      rate := config.fn_material_rate(v_line, cur_mat, t);
      factor := (speed->>cur_sku)::double precision * (0.97 + 0.06 * pg_temp.u('f' || key));
      good_rate := rate * factor * 0.975;
      run_end := least(t + make_interval(secs => dt), prod_end);
      -- the order ends in this run: changeover to the next one
      IF good_rate > 0 AND t + make_interval(secs => cur_left / good_rate * 3600) < run_end THEN
        fin := date_trunc('second', t + make_interval(secs => cur_left / good_rate * 3600));
        INSERT INTO to_run VALUES (t, fin, rate * factor);
        UPDATE to_ord SET completed = fin WHERE n = cur_n;
        qi := qi + 1; sku := cycle[1 + (qi - 1) % 7];
        co_min := coalesce((co->>(cur_sku || '>' || sku))::integer, 35) - 8 + floor(pg_temp.u('c' || key) * 23)::integer;
        SELECT id INTO mat FROM config.material WHERE code = sku;
        cur_sku := sku; cur_mat := mat; cur_n := cur_n + 1;
        cur_left := CASE WHEN sku = 'mix500' THEN 20000 + 4000 * floor(pg_temp.u('q' || cur_n) * 2) ELSE 24000 + 6000 * floor(pg_temp.u('q' || cur_n) * 3) END;
        INSERT INTO to_ord (n, material_id, qty, planned_start, started)
          VALUES (cur_n, cur_mat, cur_left::integer, CASE WHEN pg_temp.u('ps' || cur_n) < 0.65 THEN fin - make_interval(mins => floor(pg_temp.u('pd' || cur_n) * 31)::integer - 5) END, fin);
        INSERT INTO to_ev VALUES (fi, fin, 6) ON CONFLICT DO NOTHING;
        t := least(fin + make_interval(mins => greatest(10, co_min)), prod_end);
        IF t < prod_end THEN
          UPDATE to_ord SET co_end = t WHERE n = cur_n;
          INSERT INTO to_ev VALUES (fi, t, 1) ON CONFLICT DO NOTHING;
        END IF;
        CONTINUE;
      END IF;
      INSERT INTO to_run VALUES (t, run_end, rate * factor);
      cur_left := cur_left - good_rate * extract(epoch FROM run_end - t) / 3600;
      EXIT WHEN run_end >= prod_end;
      -- the stop: lognormal around its mean, at least 20 s
      dur := greatest(20, exp(ln((kk->>'min')::double precision * 60) - 0.18
                              + 0.6 * sqrt(-2 * ln(1 - pg_temp.u('d1' || key))) * cos(2 * pi() * pg_temp.u('d2' || key))));
      s := date_trunc('second', run_end);
      e := least(date_trunc('second', s + make_interval(secs => dur)), prod_end);
      m_id := (kk->>'m')::integer;
      IF m_id = fi THEN
        INSERT INTO to_ev VALUES (fi, s, 5) ON CONFLICT DO NOTHING;
        INSERT INTO to_ev VALUES (fi, e, 1) ON CONFLICT DO NOTHING;
      ELSIF m_id = er THEN
        INSERT INTO to_ev VALUES (er, s, 5), (fi, s + interval '3 seconds', 4), (er, e, 1), (fi, e + interval '3 seconds', 1) ON CONFLICT DO NOTHING;
      ELSE
        INSERT INTO to_ev VALUES (m_id, s, 5), (m_id, e, 1), (fi, s + interval '3 seconds', 3), (fi, e + interval '3 seconds', 1) ON CONFLICT DO NOTHING;
        FOR j IN 1 .. array_position(down, m_id) - 1 LOOP
          INSERT INTO to_ev VALUES (down[j], s + interval '2 seconds', 3), (down[j], e + interval '2 seconds', 1) ON CONFLICT DO NOTHING;
        END LOOP;
      END IF;
      IF kk->>'r' IS NOT NULL THEN
        INSERT INTO to_rs SELECT m_id, s, r.id,
          CASE WHEN pg_temp.u('p' || key) < 0.7 THEN 'plc' ELSE people[1 + floor(pg_temp.u('w' || key) * 3)::integer] END
        FROM config.reason r WHERE r.code = kk->>'r';
      END IF;
      t := e + interval '4 seconds';
    END LOOP;
    IF w.clean_at IS NOT NULL THEN
      INSERT INTO to_ev VALUES (fi, w.clean_at, 7) ON CONFLICT DO NOTHING;
    END IF;
    FOREACH m_id IN ARRAY ARRAY[er, fi, cw, cl, cp, pa] LOOP
      INSERT INTO to_ev VALUES (m_id, w.we, 2) ON CONFLICT DO NOTHING;
    END LOOP;
  END LOOP;
  IF cur_n = 0 THEN
    RAISE EXCEPTION 'the demo line has no production time in % - %', v_start, v_end;
  END IF;
  UPDATE to_ord SET completed = (SELECT max(ts) FROM to_ev WHERE machine_id = fi AND state_id = 2) WHERE completed IS NULL;

  -- the made-up history, all at once
  UPDATE to_ord SET wo = 'TEST-' || to_char(started AT TIME ZONE v_tz, 'YYMM') || '-' || lpad(n::text, 3, '0');
  INSERT INTO config.work_order (wo_number, line_id, material_id, planned_qty, planned_start, note)
  SELECT wo, v_line, material_id, qty, planned_start, 'made-up (migrate test-operations)' FROM to_ord ORDER BY n;
  INSERT INTO hist.work_order_event (work_order_id, event_type, ts, entered_by)
  SELECT o.id, x.t, x.ts, x.by_ FROM to_ord t2 JOIN config.work_order o ON o.wo_number = t2.wo
  CROSS JOIN LATERAL (VALUES ('start', t2.started, 'auto-operator'), ('changeover_end', t2.co_end, 'ofm'), ('complete', t2.completed, 'auto-operator')) x (t, ts, by_)
  WHERE x.ts IS NOT NULL
  ORDER BY x.ts, x.t <> 'complete';
  INSERT INTO hist.machine_state_event (machine_id, ts, state_id, cause) SELECT machine_id, ts, state_id, 'rule' FROM to_ev;
  INSERT INTO hist.state_reason (machine_id, event_ts, reason_id, assigned_by, assigned_at, person_id)
  SELECT r.machine_id, r.ts, r.reason_id, r.by_name, r.ts + interval '3 minutes',
         (SELECT p.id FROM config.person p WHERE p.display_name = r.by_name AND p.retired_at IS NULL LIMIT 1)
  FROM to_rs r JOIN to_ev ev ON ev.machine_id = r.machine_id AND ev.ts = r.ts;
  -- counts per minute from the running time: good at the closer, rejects at the checkweigher
  WITH mins AS (
    SELECT m.ts, sum(extract(epoch FROM least(r.t1, m.ts + interval '1 minute') - greatest(r.t0, m.ts)) * r.rate_h / 3600) AS units
    FROM to_run r
    CROSS JOIN LATERAL generate_series(date_trunc('minute', r.t0), r.t1 - interval '1 microsecond', interval '1 minute') m (ts)
    WHERE r.t1 > r.t0
    GROUP BY m.ts
  ),
  cum AS (
    SELECT ts, floor(sum(units * 0.975) OVER (ORDER BY ts)) AS g, floor(sum(units * 0.025) OVER (ORDER BY ts)) AS rj FROM mins
  ),
  inc AS (
    SELECT ts, g, rj, g - coalesce(lag(g) OVER (ORDER BY ts), 0) AS dg, rj - coalesce(lag(rj) OVER (ORDER BY ts), 0) AS dr FROM cum
  )
  INSERT INTO hist.production_count (ts, property_id, increment, last_value, resets)
  SELECT ts, p_good, dg, g, 0 FROM inc WHERE dg > 0
  UNION ALL
  SELECT ts, p_rej, dr, rj, 0 FROM inc WHERE dr > 0;
  GET DIAGNOSTICS n_cnt = ROW_COUNT;
  -- the day the closer improved
  INSERT INTO hist.annotation (ts, line_id, category_id, text, person_id)
  SELECT (date_trunc('day', v_mid AT TIME ZONE v_tz) + interval '6 hours') AT TIME ZONE v_tz, v_line, c.id,
         'Closer guide rail replaced (made-up test operations)', p.id
  FROM config.annotation_category c, config.person p
  WHERE c.name = 'process_change' AND p.display_name = 'Alex Demo' AND p.retired_at IS NULL
  LIMIT 1;
  SELECT count(*) INTO n_ev FROM to_ev;
  SELECT count(*) INTO n_rs FROM to_rs;
  SELECT count(*) INTO n_ord FROM to_ord;
  INSERT INTO hist.test_operation_range (line_id, from_ts, to_ts, note)
  VALUES (v_line, v_start, v_end, n_ev || ' state changes, ' || n_rs || ' coded stops, ' || n_ord || ' orders, ' || n_cnt || ' count rows');
  RAISE NOTICE 'Made-up operations for the demo line: % to % (Melbourne): % state changes, % coded stops, % orders, % count rows',
    to_char(v_start AT TIME ZONE v_tz, 'DD/MM/YYYY'), to_char(v_end AT TIME ZONE v_tz - interval '1 day', 'DD/MM/YYYY'), n_ev, n_rs, n_ord, n_cnt;
END $$;

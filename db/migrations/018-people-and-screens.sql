-- 018 People and operator screens (step 3a.8, ADR-0027, ADR-0028).
-- People sign in on the shared line screens with their employee number and
-- a PIN of 4 to 8 digits; what they record carries their ID (person_id) and
-- their name as it was (entered_by / assigned_by). The screens run in their
-- own Node-RED container as the role ofm_screens, which can do nothing but
-- call the functions of section 5 and 6: it reads no table directly.
--   1. config.person: the people (edited in Mathesar)
--   2. config.person_pin: their PINs, as hashes only (bcrypt, pgcrypto)
--   3. hist.person_sign_in: every sign-in attempt, append-only; lockout
--   4. person_id on work order events and reasons
--   5. Signing in and acting as a person
--   6. What the line view reads: lines, machines, reasons, products,
--      planned orders; stops waiting for a reason
--   7. The role ofm_screens

CREATE EXTENSION IF NOT EXISTS pgcrypto;     -- crypt() and gen_salt(): one-way PIN hashes

-- ---------------------------------------------------------------------------
-- 1. People. employee_no is what they type on the screen (badge or payroll
-- number); retire someone instead of deleting them once they have recorded
-- anything. A sign-in is personal, so names may repeat but numbers may not.
-- ---------------------------------------------------------------------------
CREATE TABLE config.person (
  id            integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_no   text NOT NULL CHECK (employee_no ~ '^[0-9A-Za-z]{1,16}$'),
  display_name  text NOT NULL CHECK (length(btrim(display_name)) BETWEEN 1 AND 64),
  note          text,
  retired_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text        NOT NULL DEFAULT current_user,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    text        NOT NULL DEFAULT current_user
);
CREATE UNIQUE INDEX person_employee_no_active_uq ON config.person (employee_no) WHERE retired_at IS NULL;
COMMENT ON TABLE config.person IS
  'People who sign in on operator screens (ADR-0028): employee number (typed on the screen) and name. Retire, do not delete: history refers to the ID.';

-- ---------------------------------------------------------------------------
-- 2. PINs. Only a bcrypt hash is stored: nobody can read a PIN back. A person
-- without a row chooses their PIN at their next sign-in; to reset a forgotten
-- PIN, delete the person's row here (Mathesar). Hidden from the runtime and
-- from Grafana.
-- ---------------------------------------------------------------------------
CREATE TABLE config.person_pin (
  person_id  integer PRIMARY KEY REFERENCES config.person (id) ON DELETE CASCADE,
  pin_hash   text        NOT NULL CHECK (pin_hash LIKE '$2a$%'),
  set_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE config.person_pin IS
  'PIN hashes (ADR-0028). Delete a row to reset that person''s PIN: they choose a new one at their next sign-in.';
REVOKE ALL ON config.person_pin FROM ofm_runtime, ofm_reader, ofm_config;
GRANT SELECT, DELETE ON config.person_pin TO ofm_config;

-- People are not part of the runtime model: editing them must not make the
-- runtime reload it (as work orders, migration 015). Audit log for people;
-- none for PINs (it would copy the hashes into the log).
CALL audit.fn_enable('config.person');
DROP TRIGGER trg_notify_model_changed ON config.person;

-- ---------------------------------------------------------------------------
-- 3. Sign-in attempts, never changed. Five wrong PINs within 10 minutes
-- (since the person's last good sign-in) lock that person for 10 minutes.
-- ---------------------------------------------------------------------------
CREATE TABLE hist.person_sign_in (
  ts           timestamptz NOT NULL DEFAULT clock_timestamp(),
  employee_no  text        NOT NULL,
  person_id    integer REFERENCES config.person (id) ON DELETE RESTRICT,
  result       text        NOT NULL CHECK (result IN ('ok', 'pin_set', 'wrong_pin', 'locked', 'unknown_person',
                                                      'no_pin', 'bad_pin', 'pin_exists')),
  screen       text
);
CREATE INDEX person_sign_in_person_ts_idx ON hist.person_sign_in (person_id, ts DESC);
COMMENT ON TABLE hist.person_sign_in IS
  'Every sign-in attempt on an operator screen (ADR-0028), append-only: ok, pin_set (first PIN chosen), wrong_pin, locked, unknown_person, no_pin (asked to choose one), bad_pin (not 4-8 digits), pin_exists.';
REVOKE INSERT, UPDATE, DELETE ON hist.person_sign_in FROM ofm_runtime;

-- ---------------------------------------------------------------------------
-- 4. Who did it, by ID. entered_by / assigned_by keep the name as it was, for
-- reading; person_id is the identity (history is keyed by ID, ADR-0004).
-- Filled from the transaction setting ofm.person_id, which only the
-- functions of section 5 set: the recording functions of migrations 015 and
-- 016 stay unchanged. Empty for plc, ofm and the auto-operator.
-- ---------------------------------------------------------------------------
ALTER TABLE hist.work_order_event ADD COLUMN person_id integer REFERENCES config.person (id) ON DELETE RESTRICT;
ALTER TABLE hist.state_reason     ADD COLUMN person_id integer REFERENCES config.person (id) ON DELETE RESTRICT;
COMMENT ON COLUMN hist.work_order_event.person_id IS 'The person who recorded it on an operator screen (ADR-0028); empty for ofm and the auto-operator.';
COMMENT ON COLUMN hist.state_reason.person_id IS 'The person who coded the stop on an operator screen (ADR-0028); empty for plc.';

CREATE FUNCTION hist.fn_set_person_id()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.person_id := coalesce(NEW.person_id, nullif(current_setting('ofm.person_id', true), '')::integer);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_set_person_id BEFORE INSERT ON hist.work_order_event
  FOR EACH ROW EXECUTE FUNCTION hist.fn_set_person_id();
CREATE TRIGGER trg_set_person_id BEFORE INSERT ON hist.state_reason
  FOR EACH ROW EXECUTE FUNCTION hist.fn_set_person_id();

-- ---------------------------------------------------------------------------
-- 5. Signing in, and acting as a person. All with fixed rights (SECURITY
-- DEFINER) and the database's clock.
-- Sign-in result: ok | wrong_pin | locked (retry_at says when) |
-- unknown_person | no_pin (the screen asks the person to choose one).
-- ---------------------------------------------------------------------------
CREATE FUNCTION config.fn_person_sign_in(p_employee_no text, p_pin text, p_screen text DEFAULT NULL)
RETURNS TABLE (result text, person_id integer, display_name text, retry_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
  p config.person;
  h text;
  last_good timestamptz;
  fifth timestamptz;
  res text;
BEGIN
  SELECT * INTO p FROM config.person WHERE employee_no = btrim(p_employee_no) AND retired_at IS NULL;
  IF NOT FOUND THEN
    INSERT INTO hist.person_sign_in (employee_no, result, screen) VALUES (left(coalesce(btrim(p_employee_no), ''), 32), 'unknown_person', p_screen);
    RETURN QUERY SELECT 'unknown_person'::text, NULL::integer, NULL::text, NULL::timestamptz;
    RETURN;
  END IF;
  PERFORM 1 FROM config.person WHERE id = p.id FOR UPDATE;          -- one attempt at a time per person
  SELECT max(s.ts) INTO last_good FROM hist.person_sign_in s WHERE s.person_id = p.id AND s.result IN ('ok', 'pin_set');
  SELECT s.ts INTO fifth FROM hist.person_sign_in s
  WHERE s.person_id = p.id AND s.result = 'wrong_pin' AND s.ts > clock_timestamp() - interval '10 minutes'
    AND (last_good IS NULL OR s.ts > last_good)
  ORDER BY s.ts DESC OFFSET 4 LIMIT 1;
  IF FOUND THEN
    INSERT INTO hist.person_sign_in (employee_no, person_id, result, screen) VALUES (p.employee_no, p.id, 'locked', p_screen);
    RETURN QUERY SELECT 'locked'::text, p.id, p.display_name, fifth + interval '10 minutes';
    RETURN;
  END IF;
  SELECT pin_hash INTO h FROM config.person_pin WHERE config.person_pin.person_id = p.id;
  IF NOT FOUND THEN
    res := 'no_pin';
  ELSIF p_pin IS NOT NULL AND public.crypt(p_pin, h) = h THEN
    res := 'ok';
  ELSE
    res := 'wrong_pin';
  END IF;
  INSERT INTO hist.person_sign_in (employee_no, person_id, result, screen) VALUES (p.employee_no, p.id, res, p_screen);
  RETURN QUERY SELECT res, p.id, CASE WHEN res = 'ok' THEN p.display_name END, NULL::timestamptz;
END $$;

-- A person without a PIN chooses one (4 to 8 digits); this signs them in.
-- Result: pin_set | bad_pin | pin_exists | unknown_person.
CREATE FUNCTION config.fn_person_set_pin(p_employee_no text, p_new_pin text, p_screen text DEFAULT NULL)
RETURNS TABLE (result text, person_id integer, display_name text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE p config.person; res text;
BEGIN
  SELECT * INTO p FROM config.person WHERE employee_no = btrim(p_employee_no) AND retired_at IS NULL;
  IF NOT FOUND THEN
    INSERT INTO hist.person_sign_in (employee_no, result, screen) VALUES (left(coalesce(btrim(p_employee_no), ''), 32), 'unknown_person', p_screen);
    RETURN QUERY SELECT 'unknown_person'::text, NULL::integer, NULL::text;
    RETURN;
  END IF;
  IF p_new_pin IS NULL OR p_new_pin !~ '^[0-9]{4,8}$' THEN
    res := 'bad_pin';
  ELSE
    INSERT INTO config.person_pin (person_id, pin_hash) VALUES (p.id, public.crypt(p_new_pin, public.gen_salt('bf', 8)))
    ON CONFLICT DO NOTHING;
    res := CASE WHEN FOUND THEN 'pin_set' ELSE 'pin_exists' END;
  END IF;
  INSERT INTO hist.person_sign_in (employee_no, person_id, result, screen) VALUES (p.employee_no, p.id, res, p_screen);
  RETURN QUERY SELECT res, p.id, CASE WHEN res = 'pin_set' THEN p.display_name END;
END $$;

-- The screens keep a person signed in (ADR-0028: until sign-out or 5 minutes
-- untouched); the database checks the person is active and signed in within
-- the last 12 hours, and records the action under their ID and name.
CREATE FUNCTION config.fn_person_acting(p_person_id integer)
RETURNS text
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE nm text;
BEGIN
  SELECT p.display_name INTO nm FROM config.person p WHERE p.id = p_person_id AND p.retired_at IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'person % does not exist or is retired', p_person_id USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM hist.person_sign_in s WHERE s.person_id = p_person_id AND s.result IN ('ok', 'pin_set')
                   AND s.ts > clock_timestamp() - interval '12 hours') THEN
    RAISE EXCEPTION '% has not signed in', nm USING ERRCODE = 'insufficient_privilege';
  END IF;
  PERFORM set_config('ofm.person_id', p_person_id::text, true);   -- this transaction only (section 4)
  RETURN nm;
END $$;
REVOKE ALL ON FUNCTION config.fn_person_acting(integer) FROM PUBLIC;

CREATE FUNCTION config.fn_person_work_order_start(p_person_id integer, p_work_order_id integer)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE r timestamptz;
BEGIN
  r := config.fn_work_order_start(p_work_order_id, config.fn_person_acting(p_person_id));
  PERFORM set_config('ofm.person_id', '', true);      -- for this one action only
  RETURN r;
END $$;

CREATE FUNCTION config.fn_person_work_order_start_new(p_person_id integer, p_line_id integer, p_sku text, p_planned_qty integer)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE r integer;
BEGIN
  r := config.fn_work_order_start_new(p_line_id, p_sku, p_planned_qty, config.fn_person_acting(p_person_id));
  PERFORM set_config('ofm.person_id', '', true);      -- for this one action only
  RETURN r;
END $$;

CREATE FUNCTION config.fn_person_work_order_changeover_end(p_person_id integer, p_work_order_id integer)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE r timestamptz;
BEGIN
  r := config.fn_work_order_changeover_end(p_work_order_id, config.fn_person_acting(p_person_id));
  PERFORM set_config('ofm.person_id', '', true);      -- for this one action only
  RETURN r;
END $$;

CREATE FUNCTION config.fn_person_work_order_complete(p_person_id integer, p_work_order_id integer)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE r timestamptz;
BEGIN
  r := config.fn_work_order_complete(p_work_order_id, config.fn_person_acting(p_person_id));
  PERFORM set_config('ofm.person_id', '', true);      -- for this one action only
  RETURN r;
END $$;

CREATE FUNCTION config.fn_person_assign_reason(p_person_id integer, p_machine_id integer, p_event_ts timestamptz,
                                               p_reason_code text, p_comment text DEFAULT NULL)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE r timestamptz;
BEGIN
  r := config.fn_assign_reason(p_machine_id, p_event_ts, p_reason_code, config.fn_person_acting(p_person_id), p_comment);
  PERFORM set_config('ofm.person_id', '', true);      -- for this one action only
  RETURN r;
END $$;

-- ---------------------------------------------------------------------------
-- 6. What the line view reads.
-- config.fn_screen_model(): every active line with a KPI rule in force, as
-- one JSON document: its topic, constraint and output machine, its machines
-- in flow order (feeds links; the rest after them), each with its state
-- topic and fault code topic, the reasons that apply to each machine, the
-- products it has a rated speed for, and its planned orders not yet started.
-- ---------------------------------------------------------------------------
CREATE FUNCTION config.fn_screen_model()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
WITH lines AS (
  SELECT l.id, l.name, coalesce(l.display_name, l.name) AS display_name,
         concat_ws('/', e.name, s.name, a.name, l.name) AS topic,
         r.constraint_machine_id, r.output_machine_id, r.order_required, r.minor_stop_threshold_s
  FROM config.line l
  JOIN config.area a       ON a.id = l.area_id
  JOIN config.site s       ON s.id = a.site_id
  JOIN config.enterprise e ON e.id = s.enterprise_id
  CROSS JOIN LATERAL config.fn_line_kpi_rule(l.id, now()) r
  WHERE l.retired_at IS NULL AND r.id IS NOT NULL
),
feeds AS (
  SELECT r.from_machine_id AS a, r.to_machine_id AS b
  FROM config.asset_relationship r
  JOIN config.machine ma ON ma.id = r.from_machine_id AND ma.retired_at IS NULL
  JOIN config.machine mb ON mb.id = r.to_machine_id AND mb.retired_at IS NULL AND mb.line_id = ma.line_id
  WHERE r.relation_type = 'feeds'
),
chain AS (                                   -- from each line's first machine along the feeds links
  WITH RECURSIVE c(machine_id, pos, path) AS (
    SELECT f.a, 1, ARRAY[f.a] FROM feeds f WHERE NOT EXISTS (SELECT 1 FROM feeds g WHERE g.b = f.a)
    UNION ALL
    SELECT f.b, c.pos + 1, c.path || f.b FROM c JOIN feeds f ON f.a = c.machine_id WHERE NOT f.b = ANY (c.path)
  )
  SELECT machine_id, min(pos) AS pos FROM c GROUP BY machine_id
),
machines AS (
  SELECT m.line_id, m.id, m.name, coalesce(m.display_name, m.name) AS display_name,
         l.topic || '/' || m.name AS topic,
         (SELECT l.topic || '/' || m.name || '/' || p.name FROM config.machine_property p
          WHERE p.machine_id = m.id AND p.role = 'fault_code' AND p.retired_at IS NULL LIMIT 1) AS fault_topic,
         m.id = l.constraint_machine_id AS is_constraint,
         m.id = l.output_machine_id AS is_output,
         row_number() OVER (PARTITION BY m.line_id ORDER BY ch.pos NULLS LAST, m.id) AS pos
  FROM config.machine m
  JOIN lines l ON l.id = m.line_id
  LEFT JOIN chain ch ON ch.machine_id = m.id
  WHERE m.retired_at IS NULL
    AND EXISTS (SELECT 1 FROM config.machine_state_rule sr WHERE sr.machine_id = m.id)
)
SELECT coalesce(jsonb_agg(jsonb_build_object(
  'id', l.id, 'name', l.name, 'displayName', l.display_name, 'topic', l.topic,
  'constraintMachineId', l.constraint_machine_id, 'outputMachineId', l.output_machine_id,
  'orderRequired', l.order_required, 'minorStopS', l.minor_stop_threshold_s,
  'machines', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                  'id', m.id, 'name', m.name, 'displayName', m.display_name, 'topic', m.topic,
                  'faultTopic', m.fault_topic, 'isConstraint', m.is_constraint, 'isOutput', m.is_output)
                ORDER BY m.pos), '[]') FROM machines m WHERE m.line_id = l.id),
  'reasons', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                 'code', r.code, 'displayName', r.display_name, 'machineId', r.machine_id,
                 'lossCategoryId', r.loss_category_id, 'lossCategory', lc.display_name)
               ORDER BY r.machine_id NULLS LAST, lc.sort_order, r.display_name), '[]')
              FROM config.reason r JOIN config.loss_category lc ON lc.id = r.loss_category_id
              WHERE r.retired_at IS NULL AND NOT r.is_system
                AND (r.machine_id IS NULL OR r.machine_id IN (SELECT m.id FROM machines m WHERE m.line_id = l.id))),
  'products', (SELECT coalesce(jsonb_agg(jsonb_build_object('sku', mt.code, 'name', mt.name, 'ratePerHour', x.rate)
                 ORDER BY mt.code), '[]')
               FROM config.material mt
               CROSS JOIN LATERAL (SELECT config.fn_material_rate(l.id, mt.id, now()) AS rate) x
               WHERE mt.retired_at IS NULL AND x.rate IS NOT NULL),
  'plannedOrders', (SELECT coalesce(jsonb_agg(jsonb_build_object(
                      'id', w.id, 'woNumber', w.wo_number, 'sku', mt.code, 'productName', mt.name,
                      'plannedQty', w.planned_qty, 'plannedStart', (extract(epoch FROM w.planned_start) * 1000)::bigint)
                    ORDER BY w.planned_start NULLS LAST, w.id), '[]')
                    FROM config.work_order w JOIN config.material mt ON mt.id = w.material_id
                    WHERE w.line_id = l.id AND NOT EXISTS (SELECT 1 FROM hist.work_order_event e WHERE e.work_order_id = w.id))
) ORDER BY l.name), '[]')
FROM lines l
$$;
COMMENT ON FUNCTION config.fn_screen_model() IS
  'Everything the line view needs from the model, one JSON document (ADR-0027); live values come from the UNS.';

-- Stops waiting for a reason (ADR-0009): the line's time in the last
-- p_hours hours that the time ledger leaves unaccounted although the
-- constraint was stopped (not unknown), per state event to code: the
-- constraint's own stop, or - when it was starved or blocked by a stopped
-- machine without a reason - that machine's stop (ADR-0024). Newest first.
-- fault_code: the code the machine showed in the first 10 s of its stop.
CREATE FUNCTION hist.fn_screen_stops_to_code(p_line_id integer, p_hours integer DEFAULT 24)
RETURNS TABLE (machine_id integer, machine_name text, machine_display_name text, event_ts timestamptz, state text,
               fault_code integer, uncoded_from timestamptz, uncoded_s double precision, stop_s double precision)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
SET enable_nestloop = off
SET jit = off
AS $$
WITH win AS (SELECT clock_timestamp() - make_interval(hours => greatest(1, least(p_hours, 168))) AS t0, clock_timestamp() AS t1),
led AS (
  SELECT l.slice_start, l.slice_end, l.duration_s, l.stop_s
  FROM win, hist.fn_time_ledger(p_line_id, win.t0, win.t1) l
  WHERE l.rule = 'unaccounted'
),
st AS (SELECT s.* FROM win, hist.fn_line_stops(p_line_id, win.t0 - interval '1 day', win.t1) s),
tocode AS (
  SELECT l.slice_start, l.duration_s, l.stop_s,
         CASE WHEN s.cause = 'attributed' THEN s.cause_machine_id ELSE s.machine_id END AS mid,
         CASE WHEN s.cause = 'attributed' THEN
           (SELECT max(e.ts) FROM hist.machine_state_event e WHERE e.machine_id = s.cause_machine_id AND e.ts <= l.slice_start)
         ELSE s.event_ts END AS ets,
         s.state
  FROM led l
  JOIN st s ON s.slice_start <= l.slice_start AND l.slice_start < s.slice_end
  WHERE s.cause IN ('none', 'attributed') AND s.state <> 'unknown'
),
grouped AS (
  SELECT t.mid, t.ets, min(t.slice_start) AS uncoded_from, sum(t.duration_s) AS uncoded_s, max(t.stop_s) AS stop_s
  FROM tocode t WHERE t.ets IS NOT NULL
  GROUP BY t.mid, t.ets
)
SELECT g.mid, m.name, coalesce(m.display_name, m.name), g.ets, ms.name,
       (SELECT round(v.value)::integer FROM hist.measurement v
        JOIN config.machine_property p ON p.id = v.property_id AND p.role = 'fault_code'
        WHERE p.machine_id = g.mid AND v.ts >= g.ets - interval '1 second' AND v.ts <= g.ets + interval '10 seconds'
          AND v.value <> 0
        ORDER BY v.ts LIMIT 1),
       g.uncoded_from, g.uncoded_s, g.stop_s
FROM grouped g
JOIN config.machine m ON m.id = g.mid
JOIN hist.machine_state_event e ON e.machine_id = g.mid AND e.ts = g.ets
JOIN config.machine_state ms ON ms.id = e.state_id
WHERE ms.name NOT IN ('running', 'unknown')
  AND NOT EXISTS (SELECT 1 FROM hist.state_reason r WHERE r.machine_id = g.mid AND r.event_ts = g.ets)
ORDER BY g.uncoded_from DESC
$$;
COMMENT ON FUNCTION hist.fn_screen_stops_to_code(integer, integer) IS
  'Stops waiting for a reason on the line view (ADR-0009, ADR-0024, ADR-0027): the state events to code, newest first.';

-- ---------------------------------------------------------------------------
-- 7. The screens' role: these functions and nothing else. Its password is
-- set from deploy/.env (OFM_SCREENS_DB_PASSWORD) by the migration runner.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ofm_screens') THEN
    CREATE ROLE ofm_screens LOGIN;
  END IF;
END $$;
GRANT USAGE ON SCHEMA config, hist TO ofm_screens;

REVOKE ALL ON FUNCTION
  config.fn_person_sign_in(text, text, text), config.fn_person_set_pin(text, text, text),
  config.fn_person_work_order_start(integer, integer), config.fn_person_work_order_start_new(integer, integer, text, integer),
  config.fn_person_work_order_changeover_end(integer, integer), config.fn_person_work_order_complete(integer, integer),
  config.fn_person_assign_reason(integer, integer, timestamptz, text, text),
  config.fn_screen_model(), hist.fn_screen_stops_to_code(integer, integer)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION
  config.fn_person_sign_in(text, text, text), config.fn_person_set_pin(text, text, text),
  config.fn_person_work_order_start(integer, integer), config.fn_person_work_order_start_new(integer, integer, text, integer),
  config.fn_person_work_order_changeover_end(integer, integer), config.fn_person_work_order_complete(integer, integer),
  config.fn_person_assign_reason(integer, integer, timestamptz, text, text),
  config.fn_screen_model(), hist.fn_screen_stops_to_code(integer, integer)
TO ofm_screens;

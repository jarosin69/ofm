-- 016 Reasons (Phase 3a, step 3a.6; ADR-0006, ADR-0009, ADR-0024).
--
-- 1. config.reason              the reason catalogue: each reason carries one
--                               loss position (4, 5, 6, 7, 9 or 12)
-- 2. config.fault_code_reason   per machine: PLC fault code -> reason
-- 3. hist.state_reason          reasons assigned to state events, append-only;
--                               the newest assignment is the effective one
--    config.fn_assign_reason    how people code a stop
-- 4. line_kpi_rule.order_required   the line runs on work orders
-- 5. config.vw_line_flow_problem    lines whose flow order is not one chain
--    hist.fn_line_stops         the line's stop list: why its constraint
--                               machine was not running, slice by slice
-- 6. config.vw_runtime_model    gains each fault_code property's code map
--
-- The runtime records a PLC reason (assigned_by 'plc') for a stop as soon
-- as the machine's fault_code shows a mapped code: the first one during the
-- stop, the root cause. People correct or add reasons later; nothing is
-- ever overwritten. The waterfall positions themselves (with the shift
-- calendar, changeover windows and minor stops) follow in step 3a.7.

-- ---------------------------------------------------------------------------
-- 1. Reason catalogue (ADR-0009 decision 1). A reason applies to one machine,
-- or to every machine when machine_id is empty. Retire a reason rather than
-- delete it once it has been used. waiting_for_order is built in: the line
-- stop list uses it for stopped time without an active work order.
-- ---------------------------------------------------------------------------
CREATE TABLE config.reason (
  id                integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  code              text    NOT NULL CHECK (config.fn_is_valid_name(code)),
  display_name      text    NOT NULL,
  loss_category_id  integer NOT NULL REFERENCES config.loss_category (id) ON DELETE RESTRICT
                            CHECK (loss_category_id IN (4, 5, 6, 7, 9, 12)),
  machine_id        integer REFERENCES config.machine (id) ON DELETE RESTRICT,
  description       text,
  is_system         boolean NOT NULL DEFAULT false,
  retired_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now(),
  created_by        text        NOT NULL DEFAULT current_user,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  updated_by        text        NOT NULL DEFAULT current_user
);
CREATE UNIQUE INDEX reason_code_active_uq ON config.reason (code) WHERE retired_at IS NULL;
COMMENT ON TABLE config.reason IS
  'Reason catalogue (ADR-0009): why a machine stopped. loss_category_id = its waterfall position (4 maintenance, 5 cleaning, 6 changeover, 7 other planned, 9 breakdown, 12 other unplanned). machine_id empty = any machine.';
COMMENT ON COLUMN config.reason.is_system IS
  'Built into OFM (waiting_for_order): cannot be deleted, retired or changed except its display name and description.';

INSERT INTO config.reason (code, display_name, loss_category_id, description, is_system) VALUES
  ('waiting_for_order', 'Waiting for order', 7,
   'Automatic: the line was stopped and had no active work order (lines with order_required, step 3a.6).', true);

CREATE FUNCTION config.fn_protect_system_reason()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.is_system THEN
    RAISE EXCEPTION 'built-in reasons come with OFM; add yours with is_system false' USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'DELETE' AND OLD.is_system THEN
    RAISE EXCEPTION 'reason % is built into OFM and cannot be deleted', OLD.code USING ERRCODE = 'check_violation';
  END IF;
  IF TG_OP = 'UPDATE' AND (OLD.is_system OR NEW.is_system)
     AND (NEW.code, NEW.loss_category_id, NEW.machine_id, NEW.retired_at, NEW.is_system)
         IS DISTINCT FROM (OLD.code, OLD.loss_category_id, OLD.machine_id, OLD.retired_at, OLD.is_system) THEN
    RAISE EXCEPTION 'reason % is built into OFM: only its display name and description may change', OLD.code
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;
CREATE TRIGGER trg_protect_system_reason BEFORE INSERT OR UPDATE OR DELETE ON config.reason
  FOR EACH ROW EXECUTE FUNCTION config.fn_protect_system_reason();

-- ---------------------------------------------------------------------------
-- 2. PLC fault codes. Per machine: the code its fault_code property shows ->
-- the reason. 0 means no fault and is never mapped; an unmapped code gives
-- no reason, and the stop waits for an operator.
-- ---------------------------------------------------------------------------
CREATE TABLE config.fault_code_reason (
  id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  machine_id  integer NOT NULL REFERENCES config.machine (id) ON DELETE RESTRICT,
  fault_code  integer NOT NULL CHECK (fault_code <> 0),
  reason_id   integer NOT NULL REFERENCES config.reason (id) ON DELETE RESTRICT,
  note        text,
  created_at  timestamptz NOT NULL DEFAULT now(),
  created_by  text        NOT NULL DEFAULT current_user,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  updated_by  text        NOT NULL DEFAULT current_user,
  CONSTRAINT fault_code_reason_uq UNIQUE (machine_id, fault_code)
);
COMMENT ON TABLE config.fault_code_reason IS
  'PLC fault code -> reason, per machine (ADR-0006: assigned_by plc). The runtime records the reason of the first mapped code shown during a stop.';

-- A reason given to a machine must apply to it (its own, or one for every machine).
CREATE FUNCTION config.fn_reason_applies(p_reason_id integer, p_machine_id integer)
RETURNS boolean
LANGUAGE sql STABLE
AS $$
  SELECT EXISTS (SELECT 1 FROM config.reason r
                 WHERE r.id = p_reason_id AND r.retired_at IS NULL
                   AND (r.machine_id IS NULL OR r.machine_id = p_machine_id))
$$;
CREATE FUNCTION config.fn_check_fault_code_reason()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NOT config.fn_reason_applies(NEW.reason_id, NEW.machine_id) THEN
    RAISE EXCEPTION 'reason % does not apply to machine % (it belongs to another machine, or is retired)', NEW.reason_id, NEW.machine_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_check_fault_code_reason BEFORE INSERT OR UPDATE ON config.fault_code_reason
  FOR EACH ROW EXECUTE FUNCTION config.fn_check_fault_code_reason();

-- ---------------------------------------------------------------------------
-- 3. Reasons assigned to state events (ADR-0006 decision 3, ADR-0009
-- decision 6): append-only, the newest assigned_at is the effective reason;
-- PLC reasons, operators' and supervisors' corrections are all kept.
-- ---------------------------------------------------------------------------
CREATE TABLE hist.state_reason (
  machine_id   integer     NOT NULL,
  event_ts     timestamptz NOT NULL,
  reason_id    integer     NOT NULL REFERENCES config.reason (id) ON DELETE RESTRICT,
  assigned_by  text        NOT NULL CHECK (length(assigned_by) BETWEEN 1 AND 128),
  assigned_at  timestamptz NOT NULL,
  comment      text        CHECK (length(comment) <= 1000),
  PRIMARY KEY (machine_id, event_ts, assigned_at),
  CONSTRAINT state_reason_event_fk FOREIGN KEY (machine_id, event_ts)
    REFERENCES hist.machine_state_event (machine_id, ts) ON DELETE RESTRICT
);
COMMENT ON TABLE hist.state_reason IS
  'Why a machine was in a state (ADR-0006): reasons assigned to its state event, never changed; the newest assigned_at is the effective reason. assigned_by: plc, or the person.';

-- The effective reason of each state event.
CREATE VIEW hist.vw_effective_reason AS
SELECT DISTINCT ON (sr.machine_id, sr.event_ts)
  sr.machine_id, sr.event_ts, sr.reason_id, r.code AS reason_code, r.display_name AS reason_name,
  r.loss_category_id, sr.assigned_by, sr.assigned_at, sr.comment
FROM hist.state_reason sr
JOIN config.reason r ON r.id = sr.reason_id
ORDER BY sr.machine_id, sr.event_ts, sr.assigned_at DESC;
COMMENT ON VIEW hist.vw_effective_reason IS
  'Per state event, its effective reason: the newest assignment in hist.state_reason.';

-- People code a stop through this function (the line view, step 3a.8):
-- checked first; the time is the database's clock. Returns assigned_at.
CREATE FUNCTION config.fn_assign_reason(p_machine_id integer, p_event_ts timestamptz, p_reason_code text,
                                        p_assigned_by text, p_comment text DEFAULT NULL)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE st text; rid integer; at timestamptz := clock_timestamp();
BEGIN
  SELECT s.name INTO st FROM hist.machine_state_event e JOIN config.machine_state s ON s.id = e.state_id
  WHERE e.machine_id = p_machine_id AND e.ts = p_event_ts;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'machine % has no state event at %', p_machine_id, p_event_ts USING ERRCODE = 'no_data_found';
  END IF;
  IF st = 'running' THEN
    RAISE EXCEPTION 'machine % was running then: there is no stop to code', p_machine_id USING ERRCODE = 'check_violation';
  END IF;
  SELECT id INTO rid FROM config.reason WHERE code = p_reason_code AND retired_at IS NULL;
  IF NOT FOUND OR NOT config.fn_reason_applies(rid, p_machine_id) THEN
    RAISE EXCEPTION 'reason % does not exist or does not apply to machine %', p_reason_code, p_machine_id
      USING ERRCODE = 'check_violation';
  END IF;
  INSERT INTO hist.state_reason (machine_id, event_ts, reason_id, assigned_by, assigned_at, comment)
  VALUES (p_machine_id, p_event_ts, rid, left(p_assigned_by, 128), at, nullif(btrim(p_comment), ''));
  RETURN at;
END $$;
REVOKE ALL ON FUNCTION config.fn_assign_reason(integer, timestamptz, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION config.fn_assign_reason(integer, timestamptz, text, text, text) TO ofm_runtime;

-- ---------------------------------------------------------------------------
-- 4. The line runs on work orders: stopped time without an active order is
-- waiting_for_order (Pos 7). Part of the KPI rule, dated with it (ADR-0008).
-- ---------------------------------------------------------------------------
ALTER TABLE config.line_kpi_rule ADD COLUMN order_required boolean NOT NULL DEFAULT false;
COMMENT ON COLUMN config.line_kpi_rule.order_required IS
  'The line runs on work orders (ADR-0010): stopped time without an active order is waiting_for_order (Pos 7). Off: lines that do not use orders.';

-- ---------------------------------------------------------------------------
-- 5. Flow order and the line's stop list.
-- ADR-0024: attribution needs the line's machines in one chain of feeds
-- links. Lines that are not (a machine feeding two, fed by two, two
-- starting points, or a loop) are listed here, and get no attribution.
-- ---------------------------------------------------------------------------
CREATE VIEW config.vw_line_flow_problem AS
WITH f AS (
  SELECT ma.line_id, r.from_machine_id AS a, r.to_machine_id AS b
  FROM config.asset_relationship r
  JOIN config.machine ma ON ma.id = r.from_machine_id AND ma.retired_at IS NULL
  JOIN config.machine mb ON mb.id = r.to_machine_id AND mb.retired_at IS NULL AND mb.line_id = ma.line_id
  WHERE r.relation_type = 'feeds'
),
per_line AS (
  SELECT line_id,
         (SELECT count(*) FROM (SELECT a FROM f f2 WHERE f2.line_id = f.line_id GROUP BY a HAVING count(*) > 1) x) AS feeds_two,
         (SELECT count(*) FROM (SELECT b FROM f f2 WHERE f2.line_id = f.line_id GROUP BY b HAVING count(*) > 1) x) AS fed_by_two,
         (SELECT count(DISTINCT a) FROM f f2 WHERE f2.line_id = f.line_id
            AND NOT EXISTS (SELECT 1 FROM f f3 WHERE f3.line_id = f.line_id AND f3.b = f2.a)) AS starts
  FROM f GROUP BY line_id
)
SELECT line_id,
       concat_ws('; ',
         CASE WHEN feeds_two > 0 THEN 'a machine feeds two machines' END,
         CASE WHEN fed_by_two > 0 THEN 'a machine is fed by two machines' END,
         CASE WHEN starts <> 1 THEN CASE WHEN starts = 0 THEN 'the feeds links form a loop' ELSE starts || ' starting machines' END END) AS problem
FROM per_line
WHERE feeds_two > 0 OR fed_by_two > 0 OR starts <> 1;
COMMENT ON VIEW config.vw_line_flow_problem IS
  'Lines whose feeds links are not a single chain (ADR-0024): starved and blocked time is not attributed on them.';

-- The line's stop list (ADR-0009 rules 2-3, ADR-0024, ADR-0010): the time in
-- [p_from, p_to) - and before now - in which the line's constraint machine
-- (KPI rule in force) was not running, cut wherever any machine of the line
-- changed state, and joined again where nothing about the stop changed.
-- Each slice gets its cause, first match wins:
--   unknown            the constraint's state was unknown (unaccounted)
--   reason             the constraint's own effective reason (PLC or person)
--   attributed         starved: the nearest machine upstream that is
--                      stopped, walking past starved ones; blocked: the same
--                      downstream, past blocked ones. Its effective reason, if
--                      any; the machine in cause_machine_id either way
--   flow               starved or blocked, but the walk met a running
--                      machine or none at all: buffer and flow loss (Pos 12)
--   waiting_for_order  order_required, and no active work order
--   none               no reason yet: coded later, or a minor stop (3a.7)
-- Classified at read time (ADR-0009 decision 5): a late reason changes the
-- result without any update.
CREATE FUNCTION hist.fn_line_stops(p_line_id integer, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (
  slice_start timestamptz, slice_end timestamptz, duration_s double precision,
  machine_id integer, state text, event_ts timestamptz, cause text,
  reason_id integer, reason_code text, reason_name text, loss_category_id integer,
  cause_machine_id integer, cause_machine_name text, cause_state text,
  assigned_by text, comment text)
LANGUAGE sql STABLE
AS $$
WITH RECURSIVE
lim AS (SELECT p_from AS t0, least(p_to, now()) AS t1),
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
ev AS (                                              -- events in range, and each machine's state at its start
  SELECT e.machine_id, e.ts, e.state_id FROM hist.machine_state_event e, lim
  WHERE e.machine_id IN (SELECT id FROM mach) AND e.ts > lim.t0 AND e.ts < lim.t1
  UNION ALL
  SELECT * FROM (
    SELECT DISTINCT ON (e.machine_id) e.machine_id, e.ts, e.state_id FROM hist.machine_state_event e, lim
    WHERE e.machine_id IN (SELECT id FROM mach) AND e.ts <= lim.t0
    ORDER BY e.machine_id, e.ts DESC) first_state
),
iv AS (
  SELECT ev.machine_id, ev.ts AS event_ts, ev.state_id,
         greatest(ev.ts, lim.t0) AS s,
         least(coalesce(lead(ev.ts) OVER (PARTITION BY ev.machine_id ORDER BY ev.ts), lim.t1), lim.t1) AS e
  FROM ev, lim
),
cut AS (SELECT DISTINCT s AS t FROM iv WHERE s < (SELECT t1 FROM lim) UNION SELECT t0 FROM lim),
sl AS (SELECT t AS s, coalesce(lead(t) OVER (ORDER BY t), (SELECT t1 FROM lim)) AS e FROM cut),
rule_sl AS (                                         -- the KPI rule in force at each slice
  SELECT sl.s, sl.e, k.constraint_machine_id AS cm, k.order_required
  FROM sl CROSS JOIN LATERAL config.fn_line_kpi_rule(p_line_id, sl.s) k
  WHERE sl.e > sl.s AND k.id IS NOT NULL
),
own AS (                                             -- the constraint's state in each slice; running dropped
  SELECT rs.*, x.state_id, x.event_ts
  FROM rule_sl rs JOIN iv x ON x.machine_id = rs.cm AND x.s <= rs.s AND rs.s < x.e
  WHERE x.state_id <> 1
),
walked AS (
  SELECT o.*,
    (SELECT jsonb_build_object('machine_id', w.machine_id, 'state_id', w.state_id, 'event_ts', w.event_ts)
     FROM (SELECT x.machine_id, x.state_id, x.event_ts, c.pos
           FROM chain c JOIN iv x ON x.machine_id = c.machine_id AND x.s <= o.s AND o.s < x.e
           WHERE (o.state_id = 4 AND c.pos < (SELECT pos FROM chain WHERE machine_id = o.cm))
              OR (o.state_id = 3 AND c.pos > (SELECT pos FROM chain WHERE machine_id = o.cm))) w
     WHERE NOT (o.state_id = 4 AND w.state_id = 4) AND NOT (o.state_id = 3 AND w.state_id = 3)   -- walk past
     ORDER BY CASE WHEN o.state_id = 4 THEN -w.pos ELSE w.pos END
     LIMIT 1) AS hit
  FROM own o
),
classified AS (
  SELECT w.s, w.e, w.cm, w.state_id, w.event_ts,
         CASE
           WHEN w.state_id = 9 THEN 'unknown'
           WHEN er.reason_id IS NOT NULL THEN 'reason'
           WHEN w.state_id IN (3, 4) AND (w.hit->>'state_id')::int IN (2, 5, 6, 7, 8, 9) THEN 'attributed'
           WHEN w.state_id IN (3, 4) AND EXISTS (SELECT 1 FROM chain WHERE machine_id = w.cm) THEN 'flow'
           WHEN w.order_required AND NOT EXISTS (
                  SELECT 1 FROM hist.vw_work_order_interval o
                  WHERE o.line_id = p_line_id AND o.started_at <= w.s AND (o.completed_at IS NULL OR o.completed_at > w.s))
             THEN 'waiting_for_order'
           ELSE 'none'
         END AS cause,
         er.reason_id AS own_reason, w.hit
  FROM walked w
  LEFT JOIN hist.vw_effective_reason er ON er.machine_id = w.cm AND er.event_ts = w.event_ts
),
detailed AS (
  SELECT c.s, c.e, c.cm, c.state_id, c.event_ts, c.cause,
         CASE c.cause WHEN 'reason' THEN er_own.reason_id
                      WHEN 'attributed' THEN er_cause.reason_id
                      WHEN 'waiting_for_order' THEN (SELECT id FROM config.reason WHERE code = 'waiting_for_order' AND is_system)
         END AS reason_id,
         CASE WHEN c.cause = 'attributed' THEN (c.hit->>'machine_id')::int END AS cause_machine_id,
         CASE WHEN c.cause = 'attributed' THEN (c.hit->>'state_id')::int END AS cause_state_id,
         CASE c.cause WHEN 'reason' THEN er_own.assigned_by WHEN 'attributed' THEN er_cause.assigned_by
                      WHEN 'waiting_for_order' THEN 'ofm' END AS assigned_by,
         CASE c.cause WHEN 'reason' THEN er_own.comment WHEN 'attributed' THEN er_cause.comment END AS comment
  FROM classified c
  LEFT JOIN hist.vw_effective_reason er_own ON c.cause = 'reason' AND er_own.machine_id = c.cm AND er_own.event_ts = c.event_ts
  LEFT JOIN hist.vw_effective_reason er_cause ON c.cause = 'attributed'
        AND er_cause.machine_id = (c.hit->>'machine_id')::int AND er_cause.event_ts = (c.hit->>'event_ts')::timestamptz
),
grouped AS (                                         -- join neighbouring slices that say the same
  SELECT d.*,
         sum(CASE WHEN prev_same THEN 0 ELSE 1 END) OVER (ORDER BY d.s) AS grp
  FROM (
    SELECT d.*,
           lag(d.e) OVER w = d.s
           AND (lag(d.cm) OVER w, lag(d.event_ts) OVER w, lag(d.cause) OVER w, lag(d.reason_id) OVER w,
                lag(d.cause_machine_id) OVER w, lag(d.cause_state_id) OVER w, lag(d.assigned_by) OVER w, lag(d.comment) OVER w)
               IS NOT DISTINCT FROM (d.cm, d.event_ts, d.cause, d.reason_id, d.cause_machine_id, d.cause_state_id, d.assigned_by, d.comment)
           AS prev_same
    FROM detailed d WINDOW w AS (ORDER BY d.s)) d
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
COMMENT ON FUNCTION hist.fn_line_stops(integer, timestamptz, timestamptz) IS
  'The line''s stop list (ADR-0009, ADR-0024): its constraint machine''s non-running time in [from, to), sliced, each with cause (unknown, reason, attributed, flow, waiting_for_order, none), reason and position, and the machine it is charged to.';

-- ---------------------------------------------------------------------------
-- 6. The runtime view gains, at its end, the fault code map of a fault_code
-- property: {"103": reason_id, ...} (its machine's config.fault_code_reason).
-- ---------------------------------------------------------------------------
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
  END AS fault_reasons
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

-- Audit columns, audit log and the runtime's model-change notification
-- (fault code maps reach the runtime through vw_runtime_model).
CALL audit.fn_enable('config.reason');
CALL audit.fn_enable('config.fault_code_reason');

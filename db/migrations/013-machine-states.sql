-- 013 Machine states (Phase 3a, step 3a.3; ADR-0006, ADR-0007, ADR-0025).
--
-- 1. config.machine_state        the fixed state vocabulary, unknown included
-- 2. machine_property.role       what a property means to OFM (state code,
--                                fault code, heartbeat, counters), at most one
--                                of each per machine; heartbeat_timeout_ms
-- 3. config.machine_state_rule   per machine: which property values mean which
--                                state, checked in order of priority
-- 4. hist.machine_state_event    one row per state change, never updated (ADR-0006)
--    hist.vw_machine_state_interval  each state with its start and end
-- 5. hist.runtime_heartbeat      one row per minute while a runtime runs, so a
--                                restarted runtime knows when it stopped
-- 6. config.vw_runtime_model     gains role, heartbeat timeout, machine topic
--                                and the state rules of each property
--
-- How the runtime uses this (flows/ofm-runtime.json): it evaluates the rules
-- of a machine whenever one of their properties changes. The first rule, in
-- order of priority, whose condition holds gives the state. If no rule holds,
-- or a property a rule needs has no good value, the state is unknown. Each
-- change is published retained on .../{machine}/state and written here.

-- ---------------------------------------------------------------------------
-- 1. State vocabulary (Overview §10.1, ADR-0006 decision 4). Fixed by this
-- migration, like the loss categories; editors may change only the display
-- name and description. Ids 1-8 are also the codes the demo simulator sends.
-- ---------------------------------------------------------------------------
CREATE TABLE config.machine_state (
  id            smallint PRIMARY KEY CHECK (id BETWEEN 1 AND 9),
  name          text NOT NULL UNIQUE CHECK (config.fn_is_valid_name(name)),
  display_name  text NOT NULL,
  description   text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  created_by    text        NOT NULL DEFAULT current_user,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  updated_by    text        NOT NULL DEFAULT current_user
);
INSERT INTO config.machine_state (id, name, display_name, description) VALUES
  (1, 'running',     'Running',     'Producing'),
  (2, 'idle',        'Idle',        'Ready, not producing, nothing wrong (stopped by the operator, no order)'),
  (3, 'blocked',     'Blocked',     'Cannot pass product on: the next machine does not take it'),
  (4, 'starved',     'Starved',     'Waiting for product from the previous machine'),
  (5, 'fault',       'Fault',       'Stopped by a fault'),
  (6, 'setup',       'Setup',       'Changeover or adjustment'),
  (7, 'cleaning',    'Cleaning',    'Cleaning and hygiene'),
  (8, 'maintenance', 'Maintenance', 'Maintenance work on the machine'),
  (9, 'unknown',     'Unknown',     'OFM could not observe the machine: no connection, frozen data, runtime not running, or no rule applies');
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON config.machine_state FROM ofm_config;
GRANT UPDATE (display_name, description) ON config.machine_state TO ofm_config;
COMMENT ON TABLE config.machine_state IS
  'Machine state vocabulary (ADR-0006); unknown = not observable. Reference data: only display_name and description may be edited.';

-- ---------------------------------------------------------------------------
-- 2. Property roles. A role tells OFM what a property means, whatever its name.
--   state_code    the PLC's state or mode number (informative; rules decide states)
--   fault_code    the PLC's fault number (reasons, step 3a.6)
--   heartbeat     a value that changes all the time while the machine's data
--                 is alive; no change for heartbeat_timeout_ms = frozen (ADR-0025)
--   count_in, count_good, count_reject   unit counters (step 3a.4)
-- ---------------------------------------------------------------------------
ALTER TABLE config.machine_property
  ADD COLUMN role text CHECK (role IN ('state_code', 'fault_code', 'heartbeat', 'count_in', 'count_good', 'count_reject')),
  ADD COLUMN heartbeat_timeout_ms integer CHECK (heartbeat_timeout_ms BETWEEN 1000 AND 3600000),
  ADD CONSTRAINT machine_property_timeout_needs_heartbeat
    CHECK (heartbeat_timeout_ms IS NULL OR (role IS NOT NULL AND role = 'heartbeat')),
  ADD CONSTRAINT machine_property_counter_is_number
    CHECK (role NOT IN ('count_in', 'count_good', 'count_reject') OR datatype IN ('int', 'float')),
  -- A rule may test only a property of its own machine (section 3).
  ADD CONSTRAINT machine_property_machine_id_uq UNIQUE (machine_id, id);
CREATE UNIQUE INDEX machine_property_role_active_uq
  ON config.machine_property (machine_id, role) WHERE role IS NOT NULL AND retired_at IS NULL;
COMMENT ON COLUMN config.machine_property.role IS
  'What the property means to OFM: state_code, fault_code, heartbeat, count_in, count_good, count_reject; at most one of each per machine.';
COMMENT ON COLUMN config.machine_property.heartbeat_timeout_ms IS
  'Heartbeat role only: the machine is frozen when this value has not changed for this long (ADR-0025). Empty = 5000. Must exceed the source''s read interval plus the heartbeat''s own period.';

-- ---------------------------------------------------------------------------
-- 3. State rules. For each machine, rules are checked in order of priority
-- (1 first): "property operator value -> state". Value is written as text:
-- a number for int and float properties (after scaling, in engineering
-- units), true or false for bool, any text for string. bool and string
-- properties allow only = and <>.
-- Example, a machine with a state code:   state_code = 5 -> fault, ...
-- Example, a machine with bits only:      1: fault_bit = true -> fault
--                                         2: run_bit = true -> running
--                                         3: run_bit = false -> idle
-- ---------------------------------------------------------------------------
CREATE TABLE config.machine_state_rule (
  id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  machine_id   integer NOT NULL,
  priority     smallint NOT NULL CHECK (priority BETWEEN 1 AND 999),
  property_id  integer NOT NULL,
  operator     text NOT NULL DEFAULT '=' CHECK (operator IN ('=', '<>', '<', '<=', '>', '>=')),
  value        text NOT NULL CHECK (length(value) BETWEEN 1 AND 1024),
  state_id     smallint NOT NULL REFERENCES config.machine_state (id) ON DELETE RESTRICT,
  note         text,
  created_at   timestamptz NOT NULL DEFAULT now(),
  created_by   text        NOT NULL DEFAULT current_user,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  updated_by   text        NOT NULL DEFAULT current_user,
  CONSTRAINT machine_state_rule_priority_uq UNIQUE (machine_id, priority),
  CONSTRAINT machine_state_rule_property_fk FOREIGN KEY (machine_id, property_id)
    REFERENCES config.machine_property (machine_id, id) ON DELETE RESTRICT
);
COMMENT ON TABLE config.machine_state_rule IS
  'How a machine''s state follows from its property values: checked in order of priority, the first rule that holds gives the state; none, or a property without a good value, gives unknown.';

-- The value must suit the property's datatype, so a typo is caught when it
-- is entered, not by a machine that never leaves unknown.
CREATE FUNCTION config.fn_check_state_rule()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE dt text;
BEGIN
  SELECT datatype INTO dt FROM config.machine_property WHERE id = NEW.property_id;
  IF dt IN ('int', 'float') AND NEW.value !~ '^\s*[-+]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?\s*$' THEN
    RAISE EXCEPTION 'state rule value "%" is not a number, but property % is %', NEW.value, NEW.property_id, dt
      USING ERRCODE = 'check_violation';
  END IF;
  IF dt = 'bool' AND lower(trim(NEW.value)) NOT IN ('true', 'false') THEN
    RAISE EXCEPTION 'state rule value "%" must be true or false: property % is bool', NEW.value, NEW.property_id
      USING ERRCODE = 'check_violation';
  END IF;
  IF dt IN ('bool', 'string') AND NEW.operator NOT IN ('=', '<>') THEN
    RAISE EXCEPTION 'operator % cannot compare a % property; use = or <>', NEW.operator, dt
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_check_state_rule BEFORE INSERT OR UPDATE ON config.machine_state_rule
  FOR EACH ROW EXECUTE FUNCTION config.fn_check_state_rule();

-- ---------------------------------------------------------------------------
-- 4. State events (ADR-0006): one row per change, complete when written,
-- never updated or deleted. cause: rule (from the state rules), communication_loss
-- (its source went offline), frozen (its heartbeat stopped, ADR-0025),
-- runtime_outage (inserted at start-up for the time the runtime was not running).
-- An ordinary table, not a hypertable: thousands of rows a day, not millions.
-- ---------------------------------------------------------------------------
CREATE TABLE hist.machine_state_event (
  machine_id  integer     NOT NULL REFERENCES config.machine (id) ON DELETE RESTRICT,
  ts          timestamptz NOT NULL,
  state_id    smallint    NOT NULL REFERENCES config.machine_state (id) ON DELETE RESTRICT,
  cause       text        NOT NULL CHECK (cause IN ('rule', 'communication_loss', 'frozen', 'runtime_outage')),
  PRIMARY KEY (machine_id, ts)
);
COMMENT ON TABLE hist.machine_state_event IS
  'Machine state changes (ADR-0006): one row per change, never updated. The state lasts until the machine''s next event; see hist.vw_machine_state_interval.';
COMMENT ON COLUMN hist.machine_state_event.cause IS
  'Why the state was recorded: rule, communication_loss, frozen (ADR-0025) or runtime_outage (start-up reconciliation).';

-- Each state with its end: the next event's start (ADR-0006 decision 2). The
-- newest state of a machine has no end yet; its duration runs until now.
-- Filter by machine_id where possible: that filter is applied before the
-- intervals are formed, a time filter only after.
CREATE VIEW hist.vw_machine_state_interval AS
SELECT
  e.machine_id,
  m.line_id,
  m.name                     AS machine_name,
  e.ts                       AS starts_at,
  lead(e.ts) OVER w          AS ends_at,
  extract(epoch FROM coalesce(lead(e.ts) OVER w, greatest(now(), e.ts)) - e.ts) AS duration_s,
  e.state_id,
  s.name                     AS state,
  e.cause
FROM hist.machine_state_event e
JOIN config.machine m       ON m.id = e.machine_id
JOIN config.machine_state s ON s.id = e.state_id
WINDOW w AS (PARTITION BY e.machine_id ORDER BY e.ts);
COMMENT ON VIEW hist.vw_machine_state_interval IS
  'Machine state intervals derived from hist.machine_state_event: start, end (NULL while it lasts), duration in seconds, state and cause.';

-- ---------------------------------------------------------------------------
-- 5. Runtime heartbeat (ADR-0006 decision 5): one row a minute per runtime.
-- At start-up a runtime places unknown from its last heartbeat. Stored through
-- the historian writer, so the rows survive a database outage too.
-- ---------------------------------------------------------------------------
CREATE TABLE hist.runtime_heartbeat (
  runtime_name  text        NOT NULL CHECK (config.fn_is_valid_name(runtime_name)),
  ts            timestamptz NOT NULL,
  PRIMARY KEY (runtime_name, ts)
);
COMMENT ON TABLE hist.runtime_heartbeat IS
  'One row a minute while a runtime runs (ADR-0006): after a restart, the time since the last row is recorded as unknown.';

-- Least privilege as for all history (ADR-0006): the runtime appends, the
-- reader reads (default privileges of schema hist); nobody else.
REVOKE ALL ON hist.vw_machine_state_interval FROM ofm_runtime;

-- ---------------------------------------------------------------------------
-- 6. The runtime view gains, at its end: the machine, role and heartbeat
-- timeout, the machine's topic (for .../{machine}/state) and the state rules
-- that test this property, as a JSON list in order of priority. Each rule
-- appears once, on the row of the property it tests; the runtime gathers a
-- machine's rules from its rows.
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
   WHERE r.property_id = p.id) AS state_rules
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

-- Audit columns, audit log and the runtime's model-change notification.
CALL audit.fn_enable('config.machine_state');
CALL audit.fn_enable('config.machine_state_rule');

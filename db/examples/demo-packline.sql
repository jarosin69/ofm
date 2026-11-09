-- Simulated packing line, OFM's demo (ADR-0023, demo/packing-line/README.md).
-- Not a migration: load it, or refresh it after changing this file, with
--   docker compose run --rm migrate demo
-- and remove it, with all its history, with
--   docker compose run --rm migrate demo-remove
-- The simulator itself runs in the "linesim" container (COMPOSE_PROFILES=demo).
--
-- What it adds to the model, in the example enterprise acme / site melbourne:
-- area "packing", line "packline01" with six machines, each read from its
-- own simulated OPC UA PLC (sources linesim_m1 ... linesim_m6); the products
-- mix150, mix250, mix500 with their rated speeds; the line's KPI rules
-- (constraint: filler, minor stops under 5 minutes, output counted at the
-- closer); its shift pattern
-- (Mon-Fri 06:00-22:00, cleaning 21:30-22:00, Melbourne time); shifts A, B
-- and C of 8 hours from 06:00; and the flow
-- order of the machines (ADR-0024); each machine's property roles, heartbeat
-- and state rules (ADR-0006, ADR-0025); reasons for its fault codes and for
-- operators (ADR-0009); and the simulator's database role
-- ofm_demo with the functions it may call (schema demo: start and complete
-- work orders, step 3a.5); three demo people for the line view, employee
-- numbers 1001-1003, each choosing a PIN at their first sign-in (step 3a.8).
-- Rename anything in Mathesar afterwards:
-- history is kept by ID (ADR-0004).
-- Running it again changes nothing that is already there.

INSERT INTO config.enterprise (name, display_name, description)
VALUES ('acme', 'Acme Confectionery', 'Example enterprise for OFM development')
ON CONFLICT (name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.site (enterprise_id, name, display_name, time_zone)
SELECT id, 'melbourne', 'Melbourne plant', 'Australia/Melbourne'
FROM config.enterprise WHERE name = 'acme' AND retired_at IS NULL
ON CONFLICT (enterprise_id, name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.area (site_id, name, display_name, description)
SELECT s.id, 'packing', 'Packing', 'Packing lines'
FROM config.site s JOIN config.enterprise e ON e.id = s.enterprise_id
WHERE e.name = 'acme' AND s.name = 'melbourne' AND s.retired_at IS NULL
ON CONFLICT (site_id, name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.line (area_id, name, display_name, description)
SELECT a.id, 'packline01', 'Packing line 1', 'Simulated packing line (OFM demo, ADR-0023)'
FROM config.area a JOIN config.site s ON s.id = a.site_id JOIN config.enterprise e ON e.id = s.enterprise_id
WHERE e.name = 'acme' AND s.name = 'melbourne' AND a.name = 'packing' AND a.retired_at IS NULL
ON CONFLICT (area_id, name) WHERE retired_at IS NULL DO NOTHING;

CREATE TEMP VIEW demo_line AS
SELECT l.id
FROM config.line l JOIN config.area a ON a.id = l.area_id
JOIN config.site s ON s.id = a.site_id JOIN config.enterprise e ON e.id = s.enterprise_id
WHERE e.name = 'acme' AND s.name = 'melbourne' AND a.name = 'packing'
  AND l.name = 'packline01' AND l.retired_at IS NULL;

-- The six machines; slot = the simulator's slot (line.json), unit = what they count.
CREATE TEMP TABLE demo_machine (slot int, name text, display_name text, unit text, rated text);
INSERT INTO demo_machine VALUES
  (1, 'erector',      'Carton erector', 'cartons', '120 cartons/min'),
  (2, 'filler',       'Filler',         'cartons', '100 cartons/min, the constraint'),
  (3, 'checkweigher', 'Checkweigher',   'cartons', '120 cartons/min'),
  (4, 'closer',       'Carton closer',  'cartons', '120 cartons/min'),
  (5, 'case_packer',  'Case packer',    'cases',   '12 cases/min, 10 cartons per case'),
  (6, 'palletiser',   'Palletiser',     'cases',   '15 cases/min, 60 cases per pallet');

INSERT INTO config.machine (line_id, name, display_name, description, external_ref)
SELECT demo_line.id, d.name, d.display_name, 'Simulated, ' || d.rated || '; counts ' || d.unit, 'linesim slot ' || d.slot
FROM demo_line, demo_machine d
ON CONFLICT (line_id, name) WHERE retired_at IS NULL DO NOTHING;

-- One simulated OPC UA PLC per machine: opc.tcp://linesim:484<slot>.
-- Read every 0.5 s, delivered every 1 s (ADR-0022 defaults).
INSERT INTO config.source (name, display_name, description, protocol, endpoint, settings)
SELECT 'linesim_m' || d.slot, 'Simulated PLC ' || d.slot || ' (' || d.display_name || ')',
       'Simulated OPC UA PLC of the demo line (service linesim, profile demo)',
       'opcua', 'opc.tcp://linesim:' || (4840 + d.slot),
       '{"securityMode": "None", "samplingIntervalMs": 500, "publishingIntervalMs": 1000}'
FROM demo_machine d
ON CONFLICT (name) WHERE retired_at IS NULL DO NOTHING;

-- Properties: the nine signals of the machine interface (demo README section 4).
-- "state" is reserved for the machine state OFM derives itself (step 3a.3),
-- so the PLC's state code is state_code. The machine-specific process value
-- is mapped only where it means something.
CREATE TEMP TABLE demo_signal (prop text, node text, display_name text, datatype text, unit text,
                               low double precision, high double precision, deadband double precision,
                               only_machine text, description text);
INSERT INTO demo_signal VALUES
  ('state_code',     'State',         'State code',       'int',   'code',        1, 8,     0, NULL,
   '1 running, 2 idle, 3 blocked, 4 starved, 5 fault, 6 setup, 7 cleaning, 8 maintenance'),
  ('fault_code',     'FaultCode',     'Fault code',       'int',   'code',        0, 32767, 0, NULL,
   '0 = no fault; the machine''s fault number (demo README section 4); 999 = unknown fault'),
  ('count_in',       'CountIn',       'Units processed',  'int',   'pcs',         0, NULL,  0, NULL,
   'Good plus rejected units since the simulator started; only rises'),
  ('count_good',     'CountGood',     'Good units',       'int',   'pcs',         0, NULL,  0, NULL,
   'Good units passed on since the simulator started; only rises'),
  ('count_reject',   'CountReject',   'Rejected units',   'int',   'pcs',         0, NULL,  0, NULL,
   'Units rejected since the simulator started; only rises'),
  ('speed',          'Speed',         'Speed',            'float', 'pcs_per_min', 0, NULL,  1, NULL,
   'Units actually made per minute, about 20-second average'),
  ('speed_setpoint', 'SpeedSetpoint', 'Speed setpoint',   'float', 'pcs_per_min', 0, NULL,  0, NULL,
   'Set speed: rated speed x speed %; for the filler, the product''s rate x speed %'),
  ('heartbeat',      'Heartbeat',     'Heartbeat',        'int',   's',           0, NULL,  0, NULL,
   '+1 every second while the simulator runs; frozen data detection (ADR-0025)'),
  ('last_weight',    'ProcessValue',  'Last carton weight','float','g',           0, NULL,  0, 'checkweigher',
   'Weight of the last carton weighed'),
  ('pallets',        'ProcessValue',  'Pallets completed','int',   'pcs',         0, NULL,  0, 'palletiser',
   'Full pallets since the simulator started');

INSERT INTO config.machine_property
  (machine_id, name, display_name, description, datatype, engineering_unit_id, low, high, deadband)
SELECT m.id, sg.prop, sg.display_name, sg.description, sg.datatype, u.id, sg.low, sg.high, sg.deadband
FROM demo_machine d
JOIN config.machine m ON m.name = d.name AND m.retired_at IS NULL
JOIN demo_line ON demo_line.id = m.line_id
JOIN demo_signal sg ON sg.only_machine IS NULL OR sg.only_machine = d.name
JOIN config.engineering_unit u ON u.code = sg.unit
ON CONFLICT (machine_id, COALESCE(sub_asset_id, 0), name) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.plc_mapping (property_id, source_id, address)
SELECT p.id, src.id, 'nsu=urn:ofm:linesim:m' || d.slot || ';s=' || sg.node
FROM demo_machine d
JOIN config.machine m ON m.name = d.name AND m.retired_at IS NULL
JOIN demo_line ON demo_line.id = m.line_id
JOIN demo_signal sg ON sg.only_machine IS NULL OR sg.only_machine = d.name
JOIN config.machine_property p ON p.machine_id = m.id AND p.name = sg.prop AND p.retired_at IS NULL
JOIN config.source src ON src.name = 'linesim_m' || d.slot AND src.retired_at IS NULL
ON CONFLICT (property_id) WHERE retired_at IS NULL DO NOTHING;

-- Roles (migration 013): what each signal means to OFM. The heartbeat rises
-- every second; 5 s without a change = frozen data (ADR-0025).
UPDATE config.machine_property p
SET role = p.name,
    heartbeat_timeout_ms = CASE WHEN p.name = 'heartbeat' THEN 5000 END
FROM config.machine m JOIN demo_line ON demo_line.id = m.line_id
WHERE p.machine_id = m.id AND m.retired_at IS NULL AND p.retired_at IS NULL AND p.role IS NULL
  AND p.name IN ('state_code', 'fault_code', 'heartbeat', 'count_in', 'count_good', 'count_reject')
  AND NOT EXISTS (SELECT 1 FROM config.machine_property o
                  WHERE o.machine_id = p.machine_id AND o.role = p.name AND o.retired_at IS NULL);

-- State rules: the simulator's state code is the state's id (1 running ...
-- 8 maintenance, demo README section 4); priority = code.
INSERT INTO config.machine_state_rule (machine_id, priority, property_id, operator, value, state_id, note)
SELECT m.id, ms.id, p.id, '=', ms.id::text, ms.id, 'Simulator state code (demo)'
FROM config.machine m JOIN demo_line ON demo_line.id = m.line_id
JOIN config.machine_property p ON p.machine_id = m.id AND p.name = 'state_code' AND p.retired_at IS NULL
CROSS JOIN config.machine_state ms
WHERE m.retired_at IS NULL AND ms.id BETWEEN 1 AND 8
ON CONFLICT (machine_id, priority) DO NOTHING;

-- Flow order (ADR-0024): each machine feeds the next.
INSERT INTO config.asset_relationship (from_machine_id, to_machine_id, relation_type)
SELECT a.id, b.id, 'feeds'
FROM demo_machine da JOIN demo_machine db ON db.slot = da.slot + 1
JOIN config.machine a ON a.name = da.name AND a.retired_at IS NULL JOIN demo_line la ON la.id = a.line_id
JOIN config.machine b ON b.name = db.name AND b.retired_at IS NULL JOIN demo_line lb ON lb.id = b.line_id
ON CONFLICT (from_machine_id, to_machine_id, relation_type) DO NOTHING;

-- Products (ADR-0014): counted in cartons.
INSERT INTO config.material (code, name, material_type, base_unit_id, description)
SELECT v.code, v.name, 'finished', u.id, 'Demo product (simulated packing line)'
FROM (VALUES ('mix150', 'Assorted 150 g'), ('mix250', 'Assorted 250 g'), ('mix500', 'Assorted 500 g')) AS v (code, name)
JOIN config.engineering_unit u ON u.code = 'pcs'
ON CONFLICT (code) WHERE retired_at IS NULL DO NOTHING;

-- Rated speeds on the line, cartons per hour (as in line.json), from 1 January 2026.
INSERT INTO config.material_line_rate (line_id, material_id, rate_per_hour, valid_from, note)
SELECT demo_line.id, mat.id, v.rate, '2026-01-01 00:00 Australia/Melbourne', 'Demo default (line.json)'
FROM demo_line,
     (VALUES ('mix150', 6000), ('mix250', 6000), ('mix500', 4800)) AS v (code, rate)
JOIN config.material mat ON mat.code = v.code AND mat.retired_at IS NULL
ON CONFLICT (line_id, material_id, valid_from) DO NOTHING;

-- KPI rules: the filler is the constraint; stops under 5 minutes are minor
-- stops; good cartons are counted at the closer, rejects from the filler to
-- the closer (ADR-0008 amendment; demo README section 3); the line runs on
-- work orders, so stopped time without one is waiting for order (step 3a.6).
INSERT INTO config.line_kpi_rule (line_id, valid_from, constraint_machine_id, output_machine_id, minor_stop_threshold_s, order_required, note)
SELECT demo_line.id, '2026-01-01 00:00 Australia/Melbourne', m.id, o.id, 300, true, 'Demo default'
FROM demo_line
JOIN config.machine m ON m.line_id = demo_line.id AND m.name = 'filler' AND m.retired_at IS NULL
JOIN config.machine o ON o.line_id = demo_line.id AND o.name = 'closer' AND o.retired_at IS NULL
ON CONFLICT (line_id, valid_from) DO NOTHING;

-- Shift pattern as in line.json: Mon-Fri 06:00-22:00, cleaning 21:30-22:00.
INSERT INTO config.line_schedule (line_id, kind, mon, tue, wed, thu, fri, start_time, end_time, valid_from, note)
SELECT demo_line.id, v.kind, true, true, true, true, true, v.start_time, v.end_time, '2026-01-01', v.note
FROM demo_line,
     (VALUES ('production', time '06:00', time '22:00', 'Two shifts, Monday to Friday'),
             ('cleaning',   time '21:30', time '22:00', 'Daily cleaning at the end of the second shift')) AS v (kind, start_time, end_time, note)
WHERE NOT EXISTS (SELECT 1 FROM config.line_schedule w
                  WHERE w.line_id = demo_line.id AND w.kind = v.kind
                    AND w.start_time = v.start_time AND w.end_time = v.end_time);

-- Shifts (step 3a.8b): three of 8 hours, Monday to Friday; C has no
-- scheduled time in the demo (the line runs 06:00-22:00). Edit them in
-- Mathesar, table line_shift (e.g. two shifts A 06:00-18:00, B 18:00-06:00).
INSERT INTO config.line_shift (line_id, name, start_time, end_time, valid_from, note)
SELECT demo_line.id, v.name, v.start_time, v.end_time, '2026-01-01', 'demo'
FROM demo_line,
     (VALUES ('A', time '06:00', time '14:00'), ('B', time '14:00', time '22:00'), ('C', time '22:00', time '06:00')) AS v (name, start_time, end_time)
WHERE NOT EXISTS (SELECT 1 FROM config.line_shift w WHERE w.line_id = demo_line.id);

-- Reasons (step 3a.6, ADR-0009): the machines' fault codes (demo README
-- section 4), each a reason of its machine, and six reasons for operators,
-- for any machine. 999 (unknown fault) is deliberately not mapped: the
-- operator codes those stops.
CREATE TEMP TABLE demo_fault (machine text, code int, reason text, display_name text, pos int);
INSERT INTO demo_fault VALUES
  ('erector',      101, 'erector_blank_magazine_empty', 'Erector: blank magazine empty',      12),
  ('erector',      102, 'erector_carton_jam',           'Erector: carton jam',                 12),
  ('erector',      103, 'erector_glue_system_fault',    'Erector: glue system fault',          9),
  ('erector',      104, 'erector_vacuum_fault',         'Erector: vacuum fault',               9),
  ('filler',       201, 'filler_product_supply_low',    'Filler: product supply low',          12),
  ('filler',       202, 'filler_counting_head_fault',   'Filler: counting head fault',         9),
  ('filler',       203, 'filler_carton_jam',            'Filler: carton jam',                  12),
  ('checkweigher', 301, 'checkweigher_reject_bin_full', 'Checkweigher: reject bin full',       12),
  ('checkweigher', 302, 'checkweigher_load_cell_fault', 'Checkweigher: load cell fault',       9),
  ('closer',       401, 'closer_glue_fault',            'Closer: glue fault',                  9),
  ('closer',       402, 'closer_carton_jam',            'Closer: carton jam',                  12),
  ('closer',       403, 'closer_flap_guide_fault',      'Closer: flap guide fault',            9),
  ('case_packer',  501, 'case_packer_case_blanks_empty','Case packer: case blanks empty',      12),
  ('case_packer',  502, 'case_packer_case_jam',         'Case packer: case jam',               12),
  ('case_packer',  503, 'case_packer_servo_fault',      'Case packer: servo fault',            9),
  ('palletiser',   601, 'palletiser_waiting_for_removal','Palletiser: waiting for pallet removal', 12),
  ('palletiser',   602, 'palletiser_empty_pallets_out', 'Palletiser: empty pallets out',       12),
  ('palletiser',   604, 'palletiser_robot_fault',       'Palletiser: robot fault',             9);

INSERT INTO config.reason (code, display_name, loss_category_id, machine_id, description)
SELECT f.reason, f.display_name, f.pos, m.id, 'Demo: PLC fault ' || f.code
FROM demo_fault f
JOIN config.machine m ON m.name = f.machine AND m.retired_at IS NULL
JOIN demo_line ON demo_line.id = m.line_id
ON CONFLICT (code) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.reason (code, display_name, loss_category_id, description)
VALUES ('breakdown_other',     'Breakdown, other',     9,  'Demo: a breakdown not on the list; say what in the comment'),
       ('minor_stop_other',    'Minor stop, other',    12, 'Demo: a short stop not on the list'),
       ('material_quality',    'Material quality',     12, 'Demo: cartons, glue or product out of specification'),
       ('meal_break',          'Meal break',           7,  'Demo: line stopped for a break'),
       ('planned_maintenance', 'Planned maintenance',  4,  'Demo: scheduled maintenance work'),
       ('extra_cleaning',      'Extra cleaning',       5,  'Demo: cleaning outside the planned window')
ON CONFLICT (code) WHERE retired_at IS NULL DO NOTHING;

INSERT INTO config.fault_code_reason (machine_id, fault_code, reason_id)
SELECT m.id, f.code, r.id
FROM demo_fault f
JOIN config.machine m ON m.name = f.machine AND m.retired_at IS NULL
JOIN demo_line ON demo_line.id = m.line_id
JOIN config.reason r ON r.code = f.reason AND r.retired_at IS NULL
ON CONFLICT (machine_id, fault_code) DO NOTHING;

-- Demo people for the line view (ADR-0028): they choose their PIN at their
-- first sign-in.
INSERT INTO config.person (employee_no, display_name, note)
SELECT v.no, v.name, 'demo (db/examples/demo-packline.sql)'
FROM (VALUES ('1001', 'Alex Demo'), ('1002', 'Billie Demo'), ('1003', 'Chris Demo')) AS v (no, name)
WHERE NOT EXISTS (SELECT 1 FROM config.person p WHERE p.employee_no = v.no AND p.retired_at IS NULL);

-- The simulator's own door into OFM (ADR-0023): the role ofm_demo may call
-- the functions of schema demo and nothing else. They run with fixed rights
-- (SECURITY DEFINER), like a key switch that allows exactly one operation;
-- the audit log and the events record what they did. Its password is set
-- from OFM_DEMO_DB_PASSWORD in .env (migrate.sh).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ofm_demo') THEN
    CREATE ROLE ofm_demo LOGIN;
  END IF;
END $$;
CREATE SCHEMA IF NOT EXISTS demo;
REVOKE ALL ON SCHEMA demo FROM PUBLIC;
GRANT USAGE ON SCHEMA demo TO ofm_demo;

-- The operator's "start this product, this many" (step 3a.5): an order is
-- created and started on the demo line (config.fn_work_order_start_new),
-- which completes the running one. Called by the auto-operator and by the
-- panel's Start order. Returns the new order's id.
CREATE OR REPLACE FUNCTION demo.start_order(p_sku text, p_planned_qty integer, p_entered_by text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE line integer;
BEGIN
  SELECT l.id INTO line
  FROM config.line l JOIN config.area a ON a.id = l.area_id
  JOIN config.site s ON s.id = a.site_id JOIN config.enterprise e ON e.id = s.enterprise_id
  WHERE e.name = 'acme' AND s.name = 'melbourne' AND a.name = 'packing' AND l.name = 'packline01' AND l.retired_at IS NULL;
  IF line IS NULL THEN
    RAISE EXCEPTION 'the demo line acme/melbourne/packing/packline01 is not in the model' USING ERRCODE = 'no_data_found';
  END IF;
  RETURN config.fn_work_order_start_new(line, p_sku, p_planned_qty, left(p_entered_by, 128));
END $fn$;

-- The operator's "Complete" without a next order: the line then waits.
CREATE OR REPLACE FUNCTION demo.complete_order(p_entered_by text)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $fn$
DECLARE wo integer;
BEGIN
  SELECT work_order_id INTO wo
  FROM hist.vw_line_work_order w JOIN config.line l ON l.id = w.line_id
  JOIN config.area a ON a.id = l.area_id JOIN config.site s ON s.id = a.site_id JOIN config.enterprise e ON e.id = s.enterprise_id
  WHERE e.name = 'acme' AND s.name = 'melbourne' AND a.name = 'packing' AND l.name = 'packline01' AND w.active;
  IF wo IS NULL THEN RETURN NULL; END IF;
  PERFORM config.fn_work_order_complete(wo, left(p_entered_by, 128));
  RETURN wo;
END $fn$;
REVOKE ALL ON FUNCTION demo.start_order(text, integer, text), demo.complete_order(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION demo.start_order(text, integer, text), demo.complete_order(text) TO ofm_demo;

-- Working tables of this script only.
DROP VIEW demo_line;
DROP TABLE demo_machine, demo_signal, demo_fault;

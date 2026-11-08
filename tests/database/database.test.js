// Database tests: the structure is complete, the model refuses bad data, the
// runtime view is correct, every role can do exactly what it should
// (Overview §13) and every model change is audited.
//
// Connects as the administrator (POSTGRES_USER from deploy/.env) and acts as
// each role with SET ROLE. Every case runs in its own transaction on a small
// test plant of its own, which is rolled back: the tests leave nothing
// behind and never touch the example plant or your own data.
"use strict";
const path = require("path");
const fs = require("fs");
const crypto = require("crypto");
const { ROOT, connectDb } = require("../lib/harness");

// PostgreSQL error codes the cases expect.
const REFUSED_BY_RULE = "23514";     // check_violation: a CHECK constraint said no
const DUPLICATE = "23505";           // unique_violation
const NO_PERMISSION = "42501";       // insufficient_privilege
const NO_SUCH_PARENT = "23503";      // foreign_key_violation
const NOT_FOUND = "P0002";           // no_data_found: a function found nothing to act on

// Production context (migration 012): a product and its rate, as steps.
const PCS = "(SELECT id FROM config.engineering_unit WHERE code = 'pcs')";
const ADD_PRODUCT = "INSERT INTO config.material (code, name, material_type, base_unit_id) VALUES ('zz_mix', 'Test mix', 'finished', " + PCS + ")";
const ZZ_MIX = "(SELECT id FROM config.material WHERE code = 'zz_mix')";
// A Sunday window 00:00-06:00 and a Saturday night window 22:00-06:00, in Melbourne time.
const SUNDAY_EARLY = "INSERT INTO config.line_schedule (line_id, kind, sun, start_time, end_time, valid_from) VALUES ($line, 'production', true, '00:00', '06:00', '2026-01-01')";
const hoursOf = r => r.map(x => Number(x.hours));

// Machine states (migration 013): a state code property and a fault bit on the test machine.
const CODE = "(SELECT id FROM config.engineering_unit WHERE code = 'code')";
const ADD_STATE_CODE = "INSERT INTO config.machine_property (machine_id, name, display_name, datatype, engineering_unit_id, role) VALUES ($machine, 'state_code', 'State code', 'int', " + CODE + ", 'state_code')";
const ADD_FAULT_BIT = "INSERT INTO config.machine_property (machine_id, name, display_name, datatype) VALUES ($machine, 'fault_bit', 'Fault', 'bool')";
const STATE_CODE = "(SELECT id FROM config.machine_property WHERE machine_id = $machine AND name = 'state_code')";
const FAULT_BIT = "(SELECT id FROM config.machine_property WHERE machine_id = $machine AND name = 'fault_bit')";
const RULE = (priority, prop, op, value, state) =>
  "INSERT INTO config.machine_state_rule (machine_id, priority, property_id, operator, value, state_id) VALUES ($machine, " +
  priority + ", " + prop + ", '" + op + "', '" + value + "', " + state + ")";
// Production counts (migration 014): a small line mach0 -> mach1 -> mach2 -> mach3
// (feeds), each machine with count_good and count_reject; mach1 is the constraint.
const ADD_MACHINES = "INSERT INTO config.machine (line_id, name, display_name) SELECT $line, n, n FROM unnest(ARRAY['mach0', 'mach2', 'mach3']) AS n";
const ADD_FEEDS = "INSERT INTO config.asset_relationship (from_machine_id, to_machine_id, relation_type) SELECT a.id, b.id, 'feeds' " +
  "FROM (VALUES ('mach0', 'mach1'), ('mach1', 'mach2'), ('mach2', 'mach3')) AS v (f, t) " +
  "JOIN config.machine a ON a.name = v.f AND a.line_id = $line JOIN config.machine b ON b.name = v.t AND b.line_id = $line";
const ADD_COUNTERS = "INSERT INTO config.machine_property (machine_id, name, display_name, datatype, engineering_unit_id, role) " +
  "SELECT m.id, r, r, 'int', " + PCS + ", r FROM config.machine m CROSS JOIN unnest(ARRAY['count_good', 'count_reject']) AS r WHERE m.line_id = $line";
const MACH = name => "(SELECT id FROM config.machine WHERE line_id = $line AND name = '" + name + "')";
const KPI_RULE = (from, output) => "INSERT INTO config.line_kpi_rule (line_id, valid_from, constraint_machine_id, output_machine_id) VALUES ($line, '" +
  from + "', $machine, " + (output ? MACH(output) : "NULL") + ")";
// Units per minute: machine number x 10, + 1 for good, + 2 for reject (mach2: good 21, reject 22).
const COUNTS_AT = ts => "INSERT INTO hist.production_count (ts, property_id, increment, last_value) " +
  "SELECT '" + ts + "', p.id, substr(m.name, 5)::int * 10 + CASE p.role WHEN 'count_good' THEN 1 ELSE 2 END, 1000 " +
  "FROM config.machine_property p JOIN config.machine m ON m.id = p.machine_id WHERE m.line_id = $line AND p.role IN ('count_good', 'count_reject')";
const LINE_COUNTS = "SELECT to_char(ts AT TIME ZONE 'UTC', 'HH24:MI') AS t, good, reject FROM hist.vw_line_count WHERE line_id = $line ORDER BY ts";
const LINE_SETUP = [
  { as: "ofm_config", sql: ADD_MACHINES },
  { as: "ofm_config", sql: ADD_FEEDS },
  { as: "ofm_config", sql: ADD_COUNTERS }];
// Work orders (migration 015): product zz_mix with a rate on the test line.
const ADD_RATE = "INSERT INTO config.material_line_rate (line_id, material_id, rate_per_hour, valid_from) VALUES ($line, " + ZZ_MIX + ", 6000, '2026-01-01')";
const ADD_ORDER = n => "INSERT INTO config.work_order (wo_number, line_id, material_id, planned_qty) VALUES ('" + n + "', $line, " + ZZ_MIX + ", 1000)";
const WO = n => "(SELECT id FROM config.work_order WHERE wo_number = '" + n + "')";
const START = n => "SELECT config.fn_work_order_start(" + WO(n) + ", 'tester') AS ts";
const WO_EVENTS = "SELECT w.wo_number, e.event_type, e.entered_by, e.ts = now() AS now FROM hist.work_order_event e JOIN config.work_order w ON w.id = e.work_order_id WHERE w.line_id = $line ORDER BY w.wo_number, e.event_type";
const ORDER_SETUP = [
  { as: "ofm_config", sql: ADD_PRODUCT },
  { as: "ofm_config", sql: ADD_RATE },
  { as: "ofm_config", sql: ADD_ORDER("wo1") },
  { as: "ofm_config", sql: ADD_ORDER("wo2") }];
// Reasons (migration 016): events on the small line mach0 -> mach1 -> mach2 -> mach3, 1 Nov 2026 (UTC).
const EV = (name, hhmm, state) => "INSERT INTO hist.machine_state_event (machine_id, ts, state_id, cause) VALUES (" + MACH(name) +
  ", '2026-11-01T" + hhmm + ":00Z', " + state + ", 'rule')";
const ADD_REASON = (code, pos, machine) => "INSERT INTO config.reason (code, display_name, loss_category_id, machine_id) VALUES ('" +
  code + "', '" + code + "', " + pos + ", " + (machine ? MACH(machine) : "NULL") + ")";
const ASSIGN = (machine, hhmm, code) => "SELECT config.fn_assign_reason(" + MACH(machine) + ", '2026-11-01T" + hhmm + ":00Z', '" + code + "', 'tester', 'test') AS at";
const RULE_AT = (constraint, orders) => "INSERT INTO config.line_kpi_rule (line_id, valid_from, constraint_machine_id, order_required) VALUES ($line, '2026-01-01', " +
  MACH(constraint) + ", " + (orders ? "true" : "false") + ")";
const STOPS = "SELECT to_char(slice_start AT TIME ZONE 'UTC', 'HH24:MI') || '-' || to_char(slice_end AT TIME ZONE 'UTC', 'HH24:MI') || ' ' || state || ' ' || cause || " +
  "coalesce(' ' || reason_code, '') || coalesce(' @' || cause_machine_name, '') || coalesce(' pos' || loss_category_id, '') AS s " +
  "FROM hist.fn_line_stops($line, '2026-11-01T00:00:00Z', '2026-11-01T02:00:00Z')";
const stops = r => r.map(x => x.s).join(" | ");
// Time ledger and KPIs (migration 017): a worked example on Monday 2 Nov 2026,
// Melbourne time (+11). Scheduled 09:00-10:00, cleaning window 09:50-10:00;
// product zz_mix at 6000/h (ICT 0.6 s), order started 08:55, changeover
// ended 09:05; mach1 is the constraint and output. Its states:
//   08:50 idle | 09:00 setup (changeover window) | 09:05 running |
//   09:15 fault, coded zz_motor (Pos 9) | 09:20 running | 09:30 idle, 2 min
//   (minor stop) | 09:32 running | 09:40 fault, uncoded, 7 min (unaccounted) |
//   09:47 running | 09:50 cleaning (cleaning window) | 10:00 idle (unscheduled)
// Counts: 2000 good and 50 rejects in scheduled minutes, 500 good at 10:05.
// Expected for 08:30-10:30: Pos 1 7200, Pos 2 3600, Pos 3 3600, Pos 5 600,
// Pos 6 300, Pos 8 2700, Pos 9 300, Pos 12 120, unaccounted 420, running
// 1860, Pos 13 1200, Pos 11 30, Pos 10 630; A 0.68889, P 0.66129,
// Q 0.97561, OEE 0.44444.
const L = hhmm => "'2026-11-02 " + hhmm + ":00+11'";
const EVL = (hhmm, state) => "INSERT INTO hist.machine_state_event (machine_id, ts, state_id, cause) VALUES ($machine, " + L(hhmm) + ", " + state + ", 'rule')";
const COUNT_ROWS = (role, n, from, minutes) => "INSERT INTO hist.production_count (ts, property_id, increment, last_value) " +
  "SELECT " + L(from) + "::timestamptz + make_interval(mins => g), (SELECT id FROM config.machine_property WHERE machine_id = $machine AND role = '" + role + "'), " +
  n + ", 1000 + g FROM generate_series(0, " + (minutes - 1) + ") g";
const LEDGER_SETUP = [
  ...LINE_SETUP,
  { as: "ofm_config", sql: RULE_AT("mach1", false) },
  ...ORDER_SETUP.slice(0, 3),
  { as: "ofm_config", sql: ADD_REASON("zz_motor", 9, null) },
  { as: "ofm_config", sql: "INSERT INTO config.line_schedule (line_id, kind, mon, start_time, end_time, valid_from) VALUES ($line, 'production', true, '09:00', '10:00', '2026-01-01')" },
  { as: "ofm_config", sql: "INSERT INTO config.line_schedule (line_id, kind, mon, start_time, end_time, valid_from) VALUES ($line, 'cleaning', true, '09:50', '10:00', '2026-01-01')" },
  { as: "ofm_runtime", sql: "INSERT INTO hist.work_order_event (work_order_id, event_type, ts, entered_by) VALUES (" + WO("wo1") + ", 'start', " + L("08:55") + ", 'tester')" },
  { as: "ofm_runtime", sql: "INSERT INTO hist.work_order_event (work_order_id, event_type, ts, entered_by) VALUES (" + WO("wo1") + ", 'changeover_end', " + L("09:05") + ", 'ofm')" },
  ...[["08:50", 2], ["09:00", 6], ["09:05", 1], ["09:15", 5], ["09:20", 1], ["09:30", 2], ["09:32", 1], ["09:40", 5], ["09:47", 1], ["09:50", 7], ["10:00", 2]]
    .map(([t, st]) => ({ as: "ofm_runtime", sql: EVL(t, st) })),
  { as: "ofm_runtime", sql: "SELECT config.fn_assign_reason($machine, " + L("09:15") + ", 'zz_motor', 'tester') AS at" },
  { as: "ofm_runtime", sql: COUNT_ROWS("count_good", 100, "09:05", 20) },
  { as: "ofm_runtime", sql: COUNT_ROWS("count_reject", 50, "09:10", 1) },
  { as: "ofm_runtime", sql: COUNT_ROWS("count_good", 500, "10:05", 1) }];
const KPI = "SELECT * FROM hist.fn_line_kpi($line, " + L("08:30") + ", " + L("10:30") + ")";
const near = (a, b) => a !== null && Math.abs(Number(a) - b) < 0.0001;
const closes = k => Math.abs(k.pos2_s + k.pos4_s + k.pos5_s + k.pos6_s + k.pos7_s + k.pos9_s + k.pos12_s + k.unaccounted_s + k.running_s - k.pos1_s) < 0.001;
const EVENT = (ts, state, cause) =>
  "INSERT INTO hist.machine_state_event (machine_id, ts, state_id, cause) VALUES ($machine, '" + ts + "', " + state + ", '" + (cause || "rule") + "') ON CONFLICT (machine_id, ts) DO NOTHING";

// A small plant created inside each case's transaction (as administrator).
async function testPlant(db) {
  const one = async (sql, params) => (await db.query(sql, params)).rows[0].id;
  const ids = {};
  ids.enterprise = await one("INSERT INTO config.enterprise (name, display_name) VALUES ('zz_test', 'Test') RETURNING id");
  ids.site = await one("INSERT INTO config.site (enterprise_id, name, display_name, time_zone) VALUES ($1, 'site1', 'Site', 'Australia/Melbourne') RETURNING id", [ids.enterprise]);
  ids.area = await one("INSERT INTO config.area (site_id, name, display_name) VALUES ($1, 'area1', 'Area') RETURNING id", [ids.site]);
  ids.line = await one("INSERT INTO config.line (area_id, name, display_name) VALUES ($1, 'line1', 'Line') RETURNING id", [ids.area]);
  ids.machine = await one("INSERT INTO config.machine (line_id, name, display_name) VALUES ($1, 'mach1', 'Machine') RETURNING id", [ids.line]);
  ids.source = await one("INSERT INTO config.source (name, display_name, protocol, endpoint, runtime_name) VALUES ('zz_src', 'Test source', 'opcua', 'opc.tcp://nowhere:4840', 'zz_runtime') RETURNING id");
  ids.temp = await one("INSERT INTO config.machine_property (machine_id, name, display_name, datatype, engineering_unit_id, low, high, alarm_high) SELECT $1, 'temp', 'Temperature', 'float', id, 0, 100, 80 FROM config.engineering_unit WHERE code = 'degC' RETURNING id", [ids.machine]);
  ids.speed = await one("INSERT INTO config.machine_property (machine_id, name, display_name, datatype, engineering_unit_id) SELECT $1, 'speed', 'Speed', 'float', id FROM config.engineering_unit WHERE code = 'rpm' RETURNING id", [ids.machine]);
  ids.mapping = await one("INSERT INTO config.plc_mapping (property_id, source_id, address, scale_factor, scale_offset) VALUES ($1, $2, 'ns=2;s=Temp', 0.1, 0) RETURNING id", [ids.temp, ids.source]);
  return ids;
}

// The cases. Each step runs as a role ("as") and expects success ("ok", or a
// function that checks the rows) or a refusal with a PostgreSQL error code.
const CASES = [
  // --- the model refuses bad data -------------------------------------------------
  { name: "name with capitals or spaces is refused", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.line (area_id, name, display_name) VALUES ($area, 'Line 2', 'x')", expect: REFUSED_BY_RULE }] },
  { name: "enterprise name 'ofm' is refused (reserved topic branch)", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.enterprise (name, display_name) VALUES ('ofm', 'x')", expect: REFUSED_BY_RULE }] },
  { name: "machine names spc and foodsafety are refused (reserved)", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.machine (line_id, name, display_name) VALUES ($line, 'spc', 'x')", expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: "INSERT INTO config.machine (line_id, name, display_name) VALUES ($line, 'foodsafety', 'x')", expect: REFUSED_BY_RULE }] },
  { name: "property name 'state' is refused (reserved)", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.machine_property (machine_id, name, display_name, datatype) VALUES ($machine, 'state', 'x', 'bool')", expect: REFUSED_BY_RULE }] },
  { name: "numeric property without a unit is refused", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.machine_property (machine_id, name, display_name, datatype) VALUES ($machine, 'flow', 'x', 'float')", expect: REFUSED_BY_RULE }] },
  { name: "engineering range with low above high is refused", steps: [
    { as: "ofm_config", sql: "UPDATE config.machine_property SET low = 100, high = 0 WHERE id = $temp", expect: REFUSED_BY_RULE }] },
  { name: "misspelt time zone is refused", steps: [
    { as: "ofm_config", sql: "UPDATE config.site SET time_zone = 'Australia/Melborne' WHERE id = $site", expect: REFUSED_BY_RULE }] },
  { name: "same address twice on one source is refused", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.plc_mapping (property_id, source_id, address) VALUES ($speed, $source, 'ns=2;s=Temp')", expect: DUPLICATE }] },
  { name: "second active mapping for one property is refused", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.plc_mapping (property_id, source_id, address) VALUES ($temp, $source, 'ns=2;s=Other')", expect: DUPLICATE }] },
  { name: "duplicate property name on one machine is refused", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.machine_property (machine_id, name, display_name, datatype) VALUES ($machine, 'temp', 'x', 'bool')", expect: DUPLICATE }] },
  { name: "a retired property's name can be used again", steps: [
    { as: "ofm_config", sql: "UPDATE config.machine_property SET retired_at = now() WHERE id = $speed" },
    { as: "ofm_config", sql: "INSERT INTO config.machine_property (machine_id, name, display_name, datatype) VALUES ($machine, 'speed', 'x', 'bool')" }] },

  // --- sources and their protocol settings (ADR-0018) ---------------------------------------
  { name: "unknown protocol is refused", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.source (name, display_name, protocol, endpoint) VALUES ('zz_x', 'x', 'profinet', '10.0.0.1')", expect: REFUSED_BY_RULE }] },
  { name: "EtherNet/IP source is accepted", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.source (name, display_name, protocol, endpoint, settings) VALUES ('zz_clx', 'x', 'ethernetip', '10.0.0.2', '{\"slot\": 0}')" }] },
  { name: "S7 source must state rack and slot", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.source (name, display_name, protocol, endpoint, settings) VALUES ('zz_s7', 'x', 's7', '10.0.0.3', '{\"rack\": 0}')", expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: "INSERT INTO config.source (name, display_name, protocol, endpoint, settings) VALUES ('zz_s7', 'x', 's7', '10.0.0.3', '{\"rack\": 0, \"slot\": 1}')" }] },
  { name: "poll interval below 100 ms or not a number is refused", steps: [
    { as: "ofm_config", sql: "UPDATE config.source SET settings = '{\"pollIntervalMs\": 50}' WHERE id = $source", expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: "UPDATE config.source SET settings = '{\"pollIntervalMs\": \"fast\"}' WHERE id = $source", expect: REFUSED_BY_RULE }] },

  // --- the runtime view (what Node-RED loads) ------------------------------------------
  { name: "runtime view: topic, address key and scaling for a mapped property", steps: [
    { as: "ofm_runtime", sql: "SELECT topic, cache_key, scale_factor, datatype, unit FROM config.vw_runtime_model WHERE runtime_name = 'zz_runtime'",
      expect: r => r.length === 1 && r[0].topic === "zz_test/site1/area1/line1/mach1/temp" &&
                   r[0].cache_key === "zz_src|ns=2;s=Temp" && Number(r[0].scale_factor) === 0.1 && r[0].unit === "degC" }] },
  { name: "runtime view: a retired property disappears", steps: [
    { as: "ofm_config", sql: "UPDATE config.machine_property SET retired_at = now() WHERE id = $temp" },
    { as: "ofm_runtime", sql: "SELECT 1 FROM config.vw_runtime_model WHERE runtime_name = 'zz_runtime'", expect: r => r.length === 0 }] },
  { name: "runtime view: a disabled source takes its properties out of acquisition", steps: [
    { as: "ofm_config", sql: "UPDATE config.source SET is_enabled = false WHERE id = $source" },
    { as: "ofm_runtime", sql: "SELECT 1 FROM config.vw_runtime_model WHERE runtime_name = 'zz_runtime'", expect: r => r.length === 0 }] },

  // --- historian -----------------------------------------------------------------------
  { name: "historian: a repeated row is ignored, not duplicated (safe replay)", steps: [
    { as: "ofm_runtime", sql: "INSERT INTO hist.measurement (ts, property_id, value, quality, ts_source) VALUES ('2026-01-01T00:00:00Z', $temp, 1, 0, 0) ON CONFLICT DO NOTHING" },
    { as: "ofm_runtime", sql: "INSERT INTO hist.measurement (ts, property_id, value, quality, ts_source) VALUES ('2026-01-01T00:00:00Z', $temp, 2, 0, 0) ON CONFLICT DO NOTHING" },
    { as: "ofm_reader", sql: "SELECT value FROM hist.measurement WHERE property_id = $temp", expect: r => r.length === 1 && r[0].value === 1 }] },
  { name: "historian: a missing value is stored only with quality bad (migration 010)", steps: [
    { as: "ofm_runtime", sql: "INSERT INTO hist.measurement (ts, property_id, value, quality, ts_source) VALUES (now(), $temp, NULL, 2, 1)" },
    { as: "ofm_runtime", sql: "INSERT INTO hist.measurement (ts, property_id, value, quality, ts_source) VALUES (now() + interval '1 s', $temp, NULL, 0, 1)", expect: REFUSED_BY_RULE }] },
  { name: "historian: unknown quality code is refused", steps: [
    { as: "ofm_runtime", sql: "INSERT INTO hist.measurement (ts, property_id, value, quality, ts_source) VALUES (now(), $temp, 1, 3, 0)", expect: REFUSED_BY_RULE }] },

  // --- permissions (least privilege, Overview §13) -----------------------------------------
  { name: "ofm_runtime cannot change the model", steps: [
    { as: "ofm_runtime", sql: "UPDATE config.machine_property SET alarm_high = 1 WHERE id = $temp", expect: NO_PERMISSION }] },
  { name: "ofm_runtime cannot change or delete history (append-only, ADR-0006)", steps: [
    { as: "ofm_runtime", sql: "INSERT INTO hist.measurement (ts, property_id, value, quality, ts_source) VALUES (now(), $temp, 1, 0, 0)" },
    { as: "ofm_runtime", sql: "UPDATE hist.measurement SET value = 2 WHERE property_id = $temp", expect: NO_PERMISSION },
    { as: "ofm_runtime", sql: "DELETE FROM hist.measurement WHERE property_id = $temp", expect: NO_PERMISSION }] },
  { name: "ofm_runtime cannot read the audit log", steps: [
    { as: "ofm_runtime", sql: "SELECT 1 FROM audit.audit_log LIMIT 1", expect: NO_PERMISSION }] },
  { name: "ofm_config cannot read the historian or the audit log", steps: [
    { as: "ofm_config", sql: "SELECT 1 FROM hist.measurement LIMIT 1", expect: NO_PERMISSION },
    { as: "ofm_config", sql: "SELECT 1 FROM audit.audit_log LIMIT 1", expect: NO_PERMISSION }] },
  { name: "ofm_mathesar (model editor) cannot read the historian", steps: [
    { as: "ofm_mathesar", sql: "SELECT 1 FROM hist.measurement LIMIT 1", expect: NO_PERMISSION }] },
  { name: "ofm_reader can read the 1-minute and 1-hour averages; ofm_config cannot", steps: [
    { as: "ofm_reader", sql: "SELECT count(*) FROM hist.measurement_1m WHERE false" },
    { as: "ofm_reader", sql: "SELECT count(*) FROM hist.measurement_1h WHERE false" },
    { as: "ofm_config", sql: "SELECT count(*) FROM hist.measurement_1h WHERE false", expect: NO_PERMISSION }] },
  { name: "ofm_reader can read model, historian and audit log", steps: [
    { as: "ofm_reader", sql: "SELECT (SELECT count(*) FROM config.vw_runtime_model) + (SELECT count(*) FROM hist.measurement WHERE false) + (SELECT count(*) FROM audit.audit_log WHERE false) AS n" }] },
  { name: "ofm_reader cannot change anything", steps: [
    { as: "ofm_reader", sql: "UPDATE config.machine_property SET alarm_high = 1 WHERE id = $temp", expect: NO_PERMISSION },
    { as: "ofm_reader", sql: "INSERT INTO hist.measurement (ts, property_id, value, quality, ts_source) VALUES (now(), $temp, 1, 0, 0)", expect: NO_PERMISSION }] },

  // --- production context (migration 012, step 3a.2) ---------------------------------------
  { name: "loss categories: the 13 waterfall positions and Unaccounted are there (ADR-0008)", steps: [
    { as: "ofm_reader", sql: "SELECT array_agg(id ORDER BY sort_order) AS ids FROM config.loss_category",
      expect: r => r[0].ids.join() === "1,2,3,4,5,6,7,8,9,10,11,12,90,13" }] },
  { name: "loss categories: editors may rename one, never add or delete one", steps: [
    { as: "ofm_config", sql: "UPDATE config.loss_category SET display_name = 'Cleaning (CIP)' WHERE id = 5" },
    { as: "ofm_config", sql: "INSERT INTO config.loss_category (id, name, display_name, category_type, sort_order) VALUES (14, 'extra', 'x', 'planned', 1)", expect: NO_PERMISSION },
    { as: "ofm_config", sql: "DELETE FROM config.loss_category WHERE id = 7", expect: NO_PERMISSION }] },
  { name: "material: an unknown material type or a code with a space is refused", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.material (code, name, material_type, base_unit_id) VALUES ('zz1', 'x', 'product', " + PCS + ")", expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: "INSERT INTO config.material (code, name, material_type, base_unit_id) VALUES ('zz 1', 'x', 'finished', " + PCS + ")", expect: REFUSED_BY_RULE }] },
  { name: "material: two active materials with the same code are refused", steps: [
    { as: "ofm_config", sql: ADD_PRODUCT },
    { as: "ofm_config", sql: ADD_PRODUCT, expect: DUPLICATE }] },
  { name: "rated speed: only a product (finished or semi_finished) has one", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.material (code, name, material_type, base_unit_id) VALUES ('zz_box', 'Carton', 'packaging', " + PCS + ")" },
    { as: "ofm_config", sql: "INSERT INTO config.material_line_rate (line_id, material_id, rate_per_hour) SELECT $line, id, 100 FROM config.material WHERE code = 'zz_box'", expect: REFUSED_BY_RULE }] },
  { name: "rated speed in force: never changed or deleted; only its note may be edited", steps: [
    { as: "ofm_config", sql: ADD_PRODUCT },
    { as: "ofm_config", sql: "INSERT INTO config.material_line_rate (line_id, material_id, rate_per_hour, valid_from) VALUES ($line, " + ZZ_MIX + ", 6000, now() - interval '1 day')" },
    { as: "ofm_config", sql: "UPDATE config.material_line_rate SET rate_per_hour = 7000 WHERE line_id = $line", expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: "UPDATE config.material_line_rate SET note = 'measured on trial' WHERE line_id = $line" },
    { as: "ofm_config", sql: "DELETE FROM config.material_line_rate WHERE line_id = $line", expect: REFUSED_BY_RULE }] },
  { name: "rated speed not yet in force: may be deleted (a typo caught in time)", steps: [
    { as: "ofm_config", sql: ADD_PRODUCT },
    { as: "ofm_config", sql: "INSERT INTO config.material_line_rate (line_id, material_id, rate_per_hour, valid_from) VALUES ($line, " + ZZ_MIX + ", 60000, now() + interval '1 day')" },
    { as: "ofm_config", sql: "DELETE FROM config.material_line_rate WHERE line_id = $line" }] },
  { name: "rated speed at a time: the newest rate valid then", steps: [
    { as: "ofm_config", sql: ADD_PRODUCT },
    { as: "ofm_config", sql: "INSERT INTO config.material_line_rate (line_id, material_id, rate_per_hour, valid_from) VALUES ($line, " + ZZ_MIX + ", 5000, '2026-01-01'), ($line, " + ZZ_MIX + ", 6000, '2026-06-01')" },
    { as: "ofm_runtime", sql: "SELECT config.fn_material_rate($line, " + ZZ_MIX + ", '2026-03-01') AS a, config.fn_material_rate($line, " + ZZ_MIX + ", '2026-07-01') AS b, config.fn_material_rate($line, " + ZZ_MIX + ", '2025-12-01') AS c",
      expect: r => r[0].a === 5000 && r[0].b === 6000 && r[0].c === null }] },
  { name: "KPI rule: the constraint machine must be a machine of that line", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.line (area_id, name, display_name) VALUES ($area, 'line2', 'Line 2')" },
    { as: "ofm_config", sql: "INSERT INTO config.line_kpi_rule (line_id, constraint_machine_id) SELECT id, $machine FROM config.line WHERE name = 'line2' AND area_id = $area", expect: NO_SUCH_PARENT },
    { as: "ofm_config", sql: "INSERT INTO config.line_kpi_rule (line_id, constraint_machine_id) VALUES ($line, $machine)" }] },
  { name: "KPI rule in force: never changed (threshold, constraint); the rule at a time is the newest valid then", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.line_kpi_rule (line_id, valid_from, constraint_machine_id, minor_stop_threshold_s) VALUES ($line, '2026-01-01', $machine, 300), ($line, '2026-06-01', $machine, 120)" },
    { as: "ofm_config", sql: "UPDATE config.line_kpi_rule SET minor_stop_threshold_s = 60 WHERE line_id = $line", expect: REFUSED_BY_RULE },
    { as: "ofm_runtime", sql: "SELECT (config.fn_line_kpi_rule($line, '2026-03-01')).minor_stop_threshold_s AS a, (config.fn_line_kpi_rule($line, now())).minor_stop_threshold_s AS b",
      expect: r => r[0].a === 300 && r[0].b === 120 }] },
  { name: "schedule: a window needs at least one day of the week", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.line_schedule (line_id, kind, start_time, end_time) VALUES ($line, 'production', '06:00', '14:00')", expect: REFUSED_BY_RULE }] },
  { name: "schedule: Mon-Fri 06:00-22:00 and cleaning 21:30-22:00 are 16 h and 30 min a day, Melbourne time", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.line_schedule (line_id, kind, mon, tue, wed, thu, fri, start_time, end_time, valid_from) VALUES ($line, 'production', true, true, true, true, true, '06:00', '22:00', '2026-01-01'), ($line, 'cleaning', true, true, true, true, true, '21:30', '22:00', '2026-01-01')" },
    { as: "ofm_reader", sql: "SELECT kind, extract(epoch FROM ends_at - starts_at) / 3600 AS hours, to_char(starts_at AT TIME ZONE 'Australia/Melbourne', 'Dy HH24:MI') AS local_start FROM config.fn_line_schedule($line, '2026-11-01 00:00 Australia/Melbourne', '2026-11-08 00:00 Australia/Melbourne') ORDER BY starts_at, kind",
      expect: r => r.length === 10 && r[0].local_start === "Mon 06:00" && r.filter(x => x.kind === "production").every(x => Number(x.hours) === 16) &&
                   r.filter(x => x.kind === "cleaning").every(x => Number(x.hours) === 0.5) }] },
  { name: "schedule on daylight-saving days: Sunday 00:00-06:00 is 5 h on 4 Oct 2026 and 7 h on 5 Apr 2026", steps: [
    { as: "ofm_config", sql: SUNDAY_EARLY },
    { as: "ofm_reader", sql: "SELECT extract(epoch FROM ends_at - starts_at) / 3600 AS hours FROM config.fn_line_schedule($line, '2026-10-01', '2026-10-08')", expect: r => hoursOf(r).join() === "5" },
    { as: "ofm_reader", sql: "SELECT extract(epoch FROM ends_at - starts_at) / 3600 AS hours FROM config.fn_line_schedule($line, '2026-04-01', '2026-04-08')", expect: r => hoursOf(r).join() === "7" }] },
  { name: "schedule: a night window (Sat 22:00-06:00) runs into Sunday; windows are cut to the range asked for", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.line_schedule (line_id, kind, sat, start_time, end_time, valid_from) VALUES ($line, 'production', true, '22:00', '06:00', '2026-01-01')" },
    { as: "ofm_reader", sql: "SELECT extract(epoch FROM ends_at - starts_at) / 3600 AS hours FROM config.fn_line_schedule($line, '2026-11-07 00:00 Australia/Melbourne', '2026-11-09 00:00 Australia/Melbourne')", expect: r => hoursOf(r).join() === "8" },
    { as: "ofm_reader", sql: "SELECT extract(epoch FROM ends_at - starts_at) / 3600 AS hours FROM config.fn_line_schedule($line, '2026-11-08 00:00 Australia/Melbourne', '2026-11-09 00:00 Australia/Melbourne')", expect: r => hoursOf(r).join() === "6" }] },
  { name: "schedule: valid_from and valid_to bound the days a window starts on", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.line_schedule (line_id, kind, mon, tue, wed, thu, fri, sat, sun, start_time, end_time, valid_from, valid_to) VALUES ($line, 'production', true, true, true, true, true, true, true, '06:00', '14:00', '2026-11-03', '2026-11-04')" },
    { as: "ofm_reader", sql: "SELECT count(*)::int AS n FROM config.fn_line_schedule($line, '2026-11-01', '2026-11-10')", expect: r => r[0].n === 2 }] },
  { name: "production context: ofm_runtime and ofm_reader read it, neither changes it", steps: [
    { as: "ofm_config", sql: ADD_PRODUCT },
    { as: "ofm_runtime", sql: "SELECT count(*) FROM config.material_line_rate, config.line_kpi_rule, config.line_schedule, config.material" },
    { as: "ofm_reader", sql: "SELECT count(*) FROM config.material_line_rate, config.line_kpi_rule, config.line_schedule, config.material" },
    { as: "ofm_runtime", sql: "UPDATE config.material SET name = 'x'", expect: NO_PERMISSION },
    { as: "ofm_reader", sql: "INSERT INTO config.line_schedule (line_id, kind, mon, start_time, end_time) VALUES ($line, 'production', true, '06:00', '14:00')", expect: NO_PERMISSION }] },
  { name: "production context: a new rate is audited", steps: [
    { as: "ofm_config", sql: ADD_PRODUCT },
    { as: "ofm_config", sql: "INSERT INTO config.material_line_rate (line_id, material_id, rate_per_hour) VALUES ($line, " + ZZ_MIX + ", 6000)" },
    { as: "ofm_reader", sql: "SELECT action, new_row->>'rate_per_hour' AS rate FROM audit.audit_log WHERE table_name = 'config.material_line_rate' ORDER BY id DESC LIMIT 1",
      expect: r => r.length === 1 && r[0].action === "INSERT" && Number(r[0].rate) === 6000 }] },

  // --- machine states (migration 013, step 3a.3) ----------------------------------------------
  { name: "machine states: the vocabulary of ADR-0006, unknown included; editors may rename, never add or delete", steps: [
    { as: "ofm_reader", sql: "SELECT string_agg(name, ',' ORDER BY id) AS names FROM config.machine_state",
      expect: r => r[0].names === "running,idle,blocked,starved,fault,setup,cleaning,maintenance,unknown" },
    { as: "ofm_config", sql: "UPDATE config.machine_state SET display_name = 'Waiting for product' WHERE name = 'starved'" },
    { as: "ofm_config", sql: "INSERT INTO config.machine_state (id, name, display_name) VALUES (10, 'paused', 'x')", expect: NO_PERMISSION },
    { as: "ofm_config", sql: "DELETE FROM config.machine_state WHERE id = 9", expect: NO_PERMISSION }] },
  { name: "roles: at most one property per role on a machine; counters must be numbers", steps: [
    { as: "ofm_config", sql: ADD_STATE_CODE },
    { as: "ofm_config", sql: "UPDATE config.machine_property SET role = 'state_code' WHERE id = $temp", expect: DUPLICATE },
    { as: "ofm_config", sql: "INSERT INTO config.machine_property (machine_id, name, display_name, datatype, role) VALUES ($machine, 'good', 'x', 'string', 'count_good')", expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: "UPDATE config.machine_property SET role = 'counter' WHERE id = $temp", expect: REFUSED_BY_RULE }] },
  { name: "roles: a heartbeat timeout only on the heartbeat role, at least 1 s; the view gives 5000 when empty (ADR-0025)", steps: [
    { as: "ofm_config", sql: "UPDATE config.machine_property SET heartbeat_timeout_ms = 5000 WHERE id = $temp", expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: "UPDATE config.machine_property SET role = 'heartbeat', heartbeat_timeout_ms = 500 WHERE id = $temp", expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: "UPDATE config.machine_property SET role = 'heartbeat' WHERE id = $temp" },
    { as: "ofm_runtime", sql: "SELECT role, heartbeat_timeout_ms, machine_topic FROM config.vw_runtime_model WHERE property_id = $temp",
      expect: r => r[0].role === "heartbeat" && r[0].heartbeat_timeout_ms === 5000 && r[0].machine_topic === "zz_test/site1/area1/line1/mach1" }] },
  { name: "state rules: the value must suit the property (number, true/false); bool allows only = and <>", steps: [
    { as: "ofm_config", sql: ADD_STATE_CODE },
    { as: "ofm_config", sql: ADD_FAULT_BIT },
    { as: "ofm_config", sql: RULE(1, STATE_CODE, "=", "five", 5), expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: RULE(1, FAULT_BIT, "=", "1", 5), expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: RULE(1, FAULT_BIT, ">", "true", 5), expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: RULE(1, FAULT_BIT, "=", "true", 5) },
    { as: "ofm_config", sql: RULE(2, STATE_CODE, ">=", "1.5e0", 1) },
    { as: "ofm_config", sql: RULE(3, STATE_CODE, "==", "1", 1), expect: REFUSED_BY_RULE }] },
  { name: "state rules: one rule per priority on a machine; only properties of that machine", steps: [
    { as: "ofm_config", sql: ADD_STATE_CODE },
    { as: "ofm_config", sql: RULE(1, STATE_CODE, "=", "1", 1) },
    { as: "ofm_config", sql: RULE(1, STATE_CODE, "=", "5", 5), expect: DUPLICATE },
    { as: "ofm_config", sql: "INSERT INTO config.machine (line_id, name, display_name) VALUES ($line, 'mach2', 'Machine 2')" },
    { as: "ofm_config", sql: "INSERT INTO config.machine_state_rule (machine_id, priority, property_id, value, state_id) SELECT id, 1, " + STATE_CODE + ", '1', 1 FROM config.machine WHERE name = 'mach2' AND line_id = $line", expect: NO_SUCH_PARENT }] },
  { name: "runtime view: each rule on the row of the property it tests, in order of priority", steps: [
    { as: "ofm_config", sql: ADD_STATE_CODE },
    { as: "ofm_config", sql: "INSERT INTO config.plc_mapping (property_id, source_id, address) VALUES (" + STATE_CODE + ", $source, 'ns=2;s=State')" },
    { as: "ofm_config", sql: RULE(5, STATE_CODE, "=", "5", 5) },
    { as: "ofm_config", sql: RULE(1, STATE_CODE, "=", "1", 1) },
    { as: "ofm_runtime", sql: "SELECT property_id, state_rules FROM config.vw_runtime_model WHERE runtime_name = 'zz_runtime' ORDER BY property_id",
      expect: r => r.length === 2 && r[0].state_rules === null &&
                   JSON.stringify(r[1].state_rules) === JSON.stringify([{ state: "running", value: "1", operator: "=", priority: 1 }, { state: "fault", value: "5", operator: "=", priority: 5 }]) }] },
  { name: "state events: the runtime appends, never changes or deletes; a replayed event is ignored", steps: [
    { as: "ofm_runtime", sql: EVENT("2026-11-05T01:00:00Z", 1) },
    { as: "ofm_runtime", sql: EVENT("2026-11-05T01:00:00Z", 5) },
    { as: "ofm_runtime", sql: "UPDATE hist.machine_state_event SET state_id = 2 WHERE machine_id = $machine", expect: NO_PERMISSION },
    { as: "ofm_runtime", sql: "DELETE FROM hist.machine_state_event WHERE machine_id = $machine", expect: NO_PERMISSION },
    { as: "ofm_reader", sql: "SELECT state_id FROM hist.machine_state_event WHERE machine_id = $machine", expect: r => r.length === 1 && r[0].state_id === 1 },
    { as: "ofm_runtime", sql: EVENT("2026-11-05T01:00:01Z", 1, "power_cut"), expect: REFUSED_BY_RULE }] },
  { name: "state events: ofm_config can neither read nor write them", steps: [
    { as: "ofm_config", sql: "SELECT 1 FROM hist.machine_state_event LIMIT 1", expect: NO_PERMISSION },
    { as: "ofm_config", sql: EVENT("2026-11-05T01:00:00Z", 1), expect: NO_PERMISSION }] },
  { name: "state intervals: each state ends where the next begins; the newest is open", steps: [
    { as: "ofm_runtime", sql: EVENT("2026-11-05T01:00:00Z", 1) },
    { as: "ofm_runtime", sql: EVENT("2026-11-05T01:10:00Z", 5) },
    { as: "ofm_runtime", sql: EVENT("2026-11-05T01:04:00Z", 4) },                     // arrives late (store-and-forward)
    { as: "ofm_reader", sql: "SELECT state, duration_s, ends_at IS NULL AS open FROM hist.vw_machine_state_interval WHERE machine_id = $machine ORDER BY starts_at",
      expect: r => r.map(x => x.state).join() === "running,starved,fault" && Number(r[0].duration_s) === 240 && Number(r[1].duration_s) === 360 &&
                   r[2].open === true && !r[0].open }] },
  { name: "runtime heartbeat: appended by the runtime, read by the reader, never changed", steps: [
    { as: "ofm_runtime", sql: "INSERT INTO hist.runtime_heartbeat (runtime_name, ts) VALUES ('zz_runtime', now()) ON CONFLICT DO NOTHING" },
    { as: "ofm_runtime", sql: "DELETE FROM hist.runtime_heartbeat WHERE runtime_name = 'zz_runtime'", expect: NO_PERMISSION },
    { as: "ofm_reader", sql: "SELECT count(*)::int AS n FROM hist.runtime_heartbeat WHERE runtime_name = 'zz_runtime'", expect: r => r[0].n === 1 }] },
  { name: "state rules are audited and reach the runtime as a model change", steps: [
    { as: "ofm_config", sql: ADD_STATE_CODE },
    { as: "ofm_config", sql: RULE(1, STATE_CODE, "=", "1", 1) },
    { as: "ofm_reader", sql: "SELECT action FROM audit.audit_log WHERE table_name = 'config.machine_state_rule' ORDER BY id DESC LIMIT 1",
      expect: r => r.length === 1 && r[0].action === "INSERT" }] },

  // --- production counts (migration 014, step 3a.4) ---------------------------------------------
  { name: "production counts: the runtime appends whole minutes; a replayed row is ignored; never changed", steps: [
    ...LINE_SETUP,
    { as: "ofm_runtime", sql: COUNTS_AT("2026-11-06T01:00:00Z") },
    { as: "ofm_runtime", sql: COUNTS_AT("2026-11-06T01:00:00Z") + " ON CONFLICT (property_id, ts) DO NOTHING" },
    { as: "ofm_runtime", sql: COUNTS_AT("2026-11-06T01:00:30Z"), expect: REFUSED_BY_RULE },
    { as: "ofm_runtime", sql: "INSERT INTO hist.production_count (ts, property_id, increment, last_value) VALUES ('2026-11-06T01:01:00Z', $temp, 0, 5)", expect: REFUSED_BY_RULE },
    { as: "ofm_runtime", sql: "INSERT INTO hist.production_count (ts, property_id, increment, last_value, resets) VALUES ('2026-11-06T01:01:00Z', $temp, 0, 0, 1)" },
    { as: "ofm_runtime", sql: "UPDATE hist.production_count SET increment = 1", expect: NO_PERMISSION },
    { as: "ofm_runtime", sql: "DELETE FROM hist.production_count", expect: NO_PERMISSION },
    { as: "ofm_config", sql: "SELECT 1 FROM hist.production_count LIMIT 1", expect: NO_PERMISSION },
    { as: "ofm_reader", sql: "SELECT count(*)::int AS n, sum(increment)::int AS units FROM hist.vw_production_count WHERE line_id = $line AND role IS NOT NULL",
      expect: r => r[0].n === 8 && r[0].units === 132 }] },
  { name: "line counts: good at the output machine, rejects from the constraint to it (ADR-0008 amendment)", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: KPI_RULE("2026-01-01", "mach3") },
    { as: "ofm_runtime", sql: COUNTS_AT("2026-11-06T01:00:00Z") },
    { as: "ofm_reader", sql: LINE_COUNTS, expect: r => r.length === 1 && Number(r[0].good) === 31 && Number(r[0].reject) === 12 + 22 + 32 }] },
  { name: "line counts: no output machine = the constraint machine", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: KPI_RULE("2026-01-01", null) },
    { as: "ofm_runtime", sql: COUNTS_AT("2026-11-06T01:00:00Z") },
    { as: "ofm_reader", sql: LINE_COUNTS, expect: r => Number(r[0].good) === 11 && Number(r[0].reject) === 12 }] },
  { name: "line counts: an output machine the constraint does not feed counts only those two machines' rejects", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: KPI_RULE("2026-01-01", "mach0") },
    { as: "ofm_runtime", sql: COUNTS_AT("2026-11-06T01:00:00Z") },
    { as: "ofm_reader", sql: LINE_COUNTS, expect: r => Number(r[0].good) === 1 && Number(r[0].reject) === 2 + 12 }] },
  { name: "line counts: each minute under the KPI rule in force then; a rule in force keeps its output machine", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: KPI_RULE("2026-01-01", "mach2") },
    { as: "ofm_config", sql: KPI_RULE("2026-11-06T01:30:00Z", "mach3") },
    { as: "ofm_runtime", sql: COUNTS_AT("2026-11-06T01:00:00Z") },
    { as: "ofm_runtime", sql: COUNTS_AT("2026-11-06T02:00:00Z") },
    { as: "ofm_reader", sql: LINE_COUNTS,
      expect: r => r.map(x => x.t + " " + Number(x.good) + "/" + Number(x.reject)).join() === "01:00 21/34,02:00 31/66" },
    { as: "ofm_config", sql: "UPDATE config.line_kpi_rule SET output_machine_id = " + MACH("mach3") + " WHERE line_id = $line AND valid_from = '2026-01-01'", expect: REFUSED_BY_RULE }] },
  { name: "KPI rule: the output machine must be a machine of the same line", steps: [
    { as: "ofm_config", sql: "INSERT INTO config.line_kpi_rule (line_id, valid_from, constraint_machine_id, output_machine_id) VALUES ($line, '2026-01-01', $machine, -1)", expect: NO_SUCH_PARENT }] },

  // --- work orders (migration 015, step 3a.5) -------------------------------------------------
  { name: "work orders: only products; planned in the model by ofm_config; started only through the functions", steps: [
    ...ORDER_SETUP,
    { as: "ofm_config", sql: "INSERT INTO config.material (code, name, material_type, base_unit_id) VALUES ('zz_film', 'Film', 'packaging', " + PCS + ")" },
    { as: "ofm_config", sql: "INSERT INTO config.work_order (wo_number, line_id, material_id, planned_qty) VALUES ('wo3', $line, (SELECT id FROM config.material WHERE code = 'zz_film'), 10)", expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: START("wo1"), expect: NO_PERMISSION },
    { as: "ofm_config", sql: "INSERT INTO hist.work_order_event (work_order_id, event_type, ts, entered_by) VALUES (" + WO("wo1") + ", 'start', now(), 'x')", expect: NO_PERMISSION },
    { as: "ofm_reader", sql: START("wo1"), expect: NO_PERMISSION },
    { as: "ofm_runtime", sql: START("wo1") },
    { as: "ofm_reader", sql: WO_EVENTS, expect: r => r.length === 1 && r[0].event_type === "start" && r[0].entered_by === "tester" }] },
  { name: "work orders: no start without a rated speed for the product on the line", steps: [
    { as: "ofm_config", sql: ADD_PRODUCT },
    { as: "ofm_config", sql: ADD_ORDER("wo1") },
    { as: "ofm_runtime", sql: START("wo1"), expect: REFUSED_BY_RULE }] },
  { name: "work orders: starting one completes the line's running order at the same time; never started twice", steps: [
    ...ORDER_SETUP,
    { as: "ofm_runtime", sql: START("wo1") },
    { as: "ofm_runtime", sql: START("wo2") },
    { as: "ofm_reader", sql: WO_EVENTS,
      expect: r => r.map(x => x.wo_number + ":" + x.event_type).join() === "wo1:complete,wo1:start,wo2:start" && r.every(x => x.now) },
    { as: "ofm_runtime", sql: START("wo2"), expect: REFUSED_BY_RULE },
    { as: "ofm_runtime", sql: START("wo1"), expect: REFUSED_BY_RULE }] },
  { name: "work orders: once started, line and product are locked and the order cannot be deleted; the quantity may change", steps: [
    ...ORDER_SETUP,
    { as: "ofm_config", sql: "UPDATE config.work_order SET planned_qty = 2000 WHERE wo_number = 'wo2'" },
    { as: "ofm_config", sql: "DELETE FROM config.work_order WHERE wo_number = 'wo2'" },
    { as: "ofm_runtime", sql: START("wo1") },
    { as: "ofm_config", sql: "UPDATE config.work_order SET material_id = (SELECT id FROM config.material WHERE code = 'zz_mix') WHERE wo_number = 'wo1'" },
    { as: "ofm_config", sql: "INSERT INTO config.line (area_id, name, display_name) VALUES ($area, 'line2', 'Line 2')" },
    { as: "ofm_config", sql: "UPDATE config.work_order SET line_id = (SELECT id FROM config.line WHERE name = 'line2' AND area_id = $area) WHERE wo_number = 'wo1'", expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: "UPDATE config.work_order SET planned_qty = 1500 WHERE wo_number = 'wo1'" },
    { as: "ofm_config", sql: "DELETE FROM config.work_order WHERE wo_number = 'wo1'", expect: NO_SUCH_PARENT }] },
  { name: "work orders: the first changeover_end counts; none before the start or after the completion", steps: [
    ...ORDER_SETUP,
    { as: "ofm_runtime", sql: "INSERT INTO hist.work_order_event (work_order_id, event_type, ts, entered_by) VALUES (" + WO("wo1") + ", 'changeover_end', now(), 'ofm')", expect: REFUSED_BY_RULE },
    { as: "ofm_runtime", sql: START("wo1") },
    { as: "ofm_runtime", sql: "SELECT config.fn_work_order_changeover_end(" + WO("wo1") + ", 'operator') AS ts" },
    { as: "ofm_runtime", sql: "INSERT INTO hist.work_order_event (work_order_id, event_type, ts, entered_by) VALUES (" + WO("wo1") + ", 'changeover_end', now() + interval '1 minute', 'ofm') ON CONFLICT (work_order_id, event_type) DO NOTHING" },
    { as: "ofm_runtime", sql: "SELECT config.fn_work_order_changeover_end(" + WO("wo1") + ", 'operator 2') AS ts", expect: r => r[0].ts !== null },
    { as: "ofm_reader", sql: "SELECT entered_by FROM hist.work_order_event WHERE event_type = 'changeover_end' AND work_order_id = " + WO("wo1"),
      expect: r => r.length === 1 && r[0].entered_by === "operator" },
    { as: "ofm_runtime", sql: START("wo2") },
    { as: "ofm_runtime", sql: "INSERT INTO hist.work_order_event (work_order_id, event_type, ts, entered_by) VALUES (" + WO("wo1") + ", 'changeover_end', now(), 'x') ON CONFLICT DO NOTHING", expect: REFUSED_BY_RULE },
    { as: "ofm_runtime", sql: "SELECT config.fn_work_order_complete(" + WO("wo2") + ", 'tester') AS ts" },
    { as: "ofm_runtime", sql: "INSERT INTO hist.work_order_event (work_order_id, event_type, ts, entered_by) VALUES (" + WO("wo2") + ", 'changeover_end', now(), 'ofm')", expect: REFUSED_BY_RULE }] },
  { name: "work order events: append-only for the runtime", steps: [
    ...ORDER_SETUP,
    { as: "ofm_runtime", sql: START("wo1") },
    { as: "ofm_runtime", sql: "UPDATE hist.work_order_event SET entered_by = 'x'", expect: NO_PERMISSION },
    { as: "ofm_runtime", sql: "DELETE FROM hist.work_order_event", expect: NO_PERMISSION }] },
  { name: "work orders: each line's newest order, active and in changeover, with its rate and the counter that ends the changeover", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: KPI_RULE("2026-01-01", "mach3") },
    ...ORDER_SETUP,
    { as: "ofm_runtime", sql: "SELECT config.fn_work_order_start_new($line, 'zz_mix', 500, 'operator') AS id" },
    { as: "ofm_runtime", sql: "SELECT line_topic, active, changeover, planned_qty, rate_per_hour, wo_number, " +
        "good_property_id = (SELECT p.id FROM config.machine_property p WHERE p.machine_id = " + MACH("mach3") + " AND p.role = 'count_good') AS good_ok " +
        "FROM hist.vw_line_work_order WHERE line_id = $line",
      expect: r => r.length === 1 && r[0].line_topic === "zz_test/site1/area1/line1" && r[0].active && r[0].changeover && r[0].planned_qty === 500 &&
                   Number(r[0].rate_per_hour) === 6000 && /^adhoc-[0-9]+$/.test(r[0].wo_number) && r[0].good_ok },
    { as: "ofm_runtime", sql: "SELECT config.fn_work_order_complete((SELECT work_order_id FROM hist.vw_line_work_order WHERE line_id = $line), 'operator') AS ts" },
    { as: "ofm_reader", sql: "SELECT active, changeover FROM hist.vw_line_work_order WHERE line_id = $line",
      expect: r => r.length === 1 && r[0].active === false && r[0].changeover === false }] },

  // --- reasons (migration 016, step 3a.6) -------------------------------------------------------
  { name: "reasons: positions 4, 5, 6, 7, 9 or 12 only; one active reason per code; waiting_for_order is built in", steps: [
    { as: "ofm_config", sql: ADD_REASON("zz_r", 9, null) },
    { as: "ofm_config", sql: ADD_REASON("zz_r", 12, null), expect: DUPLICATE },
    { as: "ofm_config", sql: ADD_REASON("zz_bad", 10, null), expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: "DELETE FROM config.reason WHERE code = 'waiting_for_order'", expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: "UPDATE config.reason SET loss_category_id = 12 WHERE code = 'waiting_for_order'", expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: "UPDATE config.reason SET display_name = 'No order' WHERE code = 'waiting_for_order'" },
    { as: "ofm_config", sql: "INSERT INTO config.reason (code, display_name, loss_category_id, is_system) VALUES ('zz_sys', 'x', 7, true)", expect: REFUSED_BY_RULE }] },
  { name: "fault codes: mapped per machine to a reason that applies to it; code 0 is never mapped", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: ADD_REASON("zz_glue", 9, "mach0") },
    { as: "ofm_config", sql: "INSERT INTO config.fault_code_reason (machine_id, fault_code, reason_id) VALUES (" + MACH("mach2") + ", 103, (SELECT id FROM config.reason WHERE code = 'zz_glue'))", expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: "INSERT INTO config.fault_code_reason (machine_id, fault_code, reason_id) VALUES (" + MACH("mach0") + ", 0, (SELECT id FROM config.reason WHERE code = 'zz_glue'))", expect: REFUSED_BY_RULE },
    { as: "ofm_config", sql: "INSERT INTO config.fault_code_reason (machine_id, fault_code, reason_id) VALUES (" + MACH("mach0") + ", 103, (SELECT id FROM config.reason WHERE code = 'zz_glue'))" },
    { as: "ofm_config", sql: "INSERT INTO config.machine_property (machine_id, name, display_name, datatype, engineering_unit_id, role) VALUES (" + MACH("mach0") + ", 'fault_code', 'Fault', 'int', " + CODE + ", 'fault_code')" },
    { as: "ofm_config", sql: "INSERT INTO config.plc_mapping (property_id, source_id, address) VALUES ((SELECT id FROM config.machine_property WHERE name = 'fault_code' AND machine_id = " + MACH("mach0") + "), $source, 'ns=2;s=Fault')" },
    { as: "ofm_runtime", sql: "SELECT fault_reasons FROM config.vw_runtime_model WHERE property_name = 'fault_code' AND runtime_name = 'zz_runtime'",
      expect: r => r.length === 1 && Object.keys(r[0].fault_reasons).join() === "103" }] },
  { name: "state reasons: append-only, only for real events; the newest assignment is effective", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: ADD_REASON("zz_jam", 12, null) },
    { as: "ofm_config", sql: ADD_REASON("zz_glue", 9, "mach0") },
    { as: "ofm_runtime", sql: EV("mach1", "01:00", 5) },
    { as: "ofm_runtime", sql: ASSIGN("mach1", "01:00", "zz_jam") },
    { as: "ofm_runtime", sql: "INSERT INTO hist.state_reason (machine_id, event_ts, reason_id, assigned_by, assigned_at) VALUES (" + MACH("mach1") +
        ", '2026-11-01T01:00:00Z', (SELECT id FROM config.reason WHERE code = 'zz_jam'), 'plc', now() + interval '1 hour')" },
    { as: "ofm_runtime", sql: ASSIGN("mach1", "01:00", "zz_glue"), expect: REFUSED_BY_RULE },
    { as: "ofm_runtime", sql: ASSIGN("mach1", "01:05", "zz_jam"), expect: NOT_FOUND },
    { as: "ofm_runtime", sql: "UPDATE hist.state_reason SET reason_id = reason_id", expect: NO_PERMISSION },
    { as: "ofm_runtime", sql: "DELETE FROM hist.state_reason", expect: NO_PERMISSION },
    { as: "ofm_config", sql: ASSIGN("mach1", "01:00", "zz_jam"), expect: NO_PERMISSION },
    { as: "ofm_reader", sql: "SELECT assigned_by FROM hist.vw_effective_reason WHERE machine_id = " + MACH("mach1"), expect: r => r.length === 1 && r[0].assigned_by === "plc" }] },
  { name: "state reasons: a running machine has no stop to code", steps: [
    { as: "ofm_config", sql: ADD_REASON("zz_jam", 12, null) },
    { as: "ofm_runtime", sql: EV("mach1", "01:00", 1) },
    { as: "ofm_runtime", sql: ASSIGN("mach1", "01:00", "zz_jam"), expect: REFUSED_BY_RULE }] },
  { name: "line stops: the constraint's own reason; running time is not a stop; a later correction wins", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: RULE_AT("mach1", false) },
    { as: "ofm_config", sql: ADD_REASON("zz_jam", 12, null) },
    { as: "ofm_config", sql: ADD_REASON("zz_motor", 9, null) },
    { as: "ofm_runtime", sql: EV("mach1", "00:30", 1) },
    { as: "ofm_runtime", sql: EV("mach1", "01:00", 5) },
    { as: "ofm_runtime", sql: EV("mach1", "01:10", 1) },
    { as: "ofm_runtime", sql: ASSIGN("mach1", "01:00", "zz_jam") },
    { as: "ofm_reader", sql: STOPS, expect: r => stops(r) === "01:00-01:10 fault reason zz_jam pos12" },
    { as: "ofm_runtime", sql: ASSIGN("mach1", "01:00", "zz_motor") },
    { as: "ofm_reader", sql: STOPS, expect: r => stops(r) === "01:00-01:10 fault reason zz_motor pos9" }] },
  { name: "line stops: starved time charged to the stopped machine upstream, then flow loss while the buffer refills", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: RULE_AT("mach1", false) },
    { as: "ofm_config", sql: ADD_REASON("zz_glue", 9, "mach0") },
    { as: "ofm_runtime", sql: EV("mach0", "00:30", 1) },
    { as: "ofm_runtime", sql: EV("mach1", "00:30", 1) },
    { as: "ofm_runtime", sql: EV("mach0", "01:00", 5) },
    { as: "ofm_runtime", sql: EV("mach1", "01:01", 4) },
    { as: "ofm_runtime", sql: EV("mach0", "01:05", 1) },
    { as: "ofm_runtime", sql: EV("mach1", "01:06", 1) },
    { as: "ofm_runtime", sql: ASSIGN("mach0", "01:00", "zz_glue") },
    { as: "ofm_reader", sql: STOPS, expect: r => stops(r) === "01:01-01:05 starved attributed zz_glue @mach0 pos9 | 01:05-01:06 starved flow" }] },
  { name: "line stops: the walk passes starved machines; a cause without a reason is named, not coded", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: RULE_AT("mach2", false) },
    { as: "ofm_runtime", sql: EV("mach0", "01:00", 5) },
    { as: "ofm_runtime", sql: EV("mach1", "01:01", 4) },
    { as: "ofm_runtime", sql: EV("mach2", "01:02", 4) },
    { as: "ofm_runtime", sql: EV("mach0", "01:10", 1) },
    { as: "ofm_runtime", sql: EV("mach1", "01:10", 1) },
    { as: "ofm_runtime", sql: EV("mach2", "01:11", 1) },
    { as: "ofm_reader", sql: STOPS, expect: r => stops(r) === "01:02-01:10 starved attributed @mach0 | 01:10-01:11 starved flow" }] },
  { name: "line stops: blocked time charged downstream; waiting for order without an active order; unknown stays unknown", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: RULE_AT("mach1", true) },
    ...ORDER_SETUP.slice(0, 2),
    { as: "ofm_config", sql: ADD_REASON("zz_servo", 9, "mach3") },
    { as: "ofm_runtime", sql: EV("mach1", "00:10", 2) },
    { as: "ofm_runtime", sql: EV("mach1", "00:20", 9) },
    { as: "ofm_runtime", sql: EV("mach3", "01:00", 5) },
    { as: "ofm_runtime", sql: EV("mach2", "01:01", 3) },
    { as: "ofm_runtime", sql: EV("mach1", "01:02", 3) },
    { as: "ofm_runtime", sql: EV("mach1", "01:20", 1) },
    { as: "ofm_runtime", sql: ASSIGN("mach3", "01:00", "zz_servo") },
    { as: "ofm_reader", sql: STOPS,
      expect: r => stops(r) === "00:10-00:20 idle waiting_for_order waiting_for_order pos7 | 00:20-01:02 unknown unknown | 01:02-01:20 blocked attributed zz_servo @mach3 pos9" }] },
  { name: "line stops: with an active order, an idle stop has no reason yet", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: RULE_AT("mach1", true) },
    ...ORDER_SETUP,
    { as: "ofm_runtime", sql: "INSERT INTO hist.work_order_event (work_order_id, event_type, ts, entered_by) VALUES (" + WO("wo1") + ", 'start', now() - interval '10 minutes', 'tester')" },
    { as: "ofm_runtime", sql: "INSERT INTO hist.machine_state_event (machine_id, ts, state_id, cause) VALUES ($machine, now() - interval '30 seconds', 2, 'rule')" },
    { as: "ofm_reader", sql: "SELECT cause FROM hist.fn_line_stops($line, now() - interval '1 minute', now())", expect: r => r.length === 1 && r[0].cause === "none" }] },
  { name: "line stops: a line whose feeds are not one chain is listed, and its starved time is not attributed", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: RULE_AT("mach1", false) },
    { as: "ofm_config", sql: "INSERT INTO config.asset_relationship (from_machine_id, to_machine_id, relation_type) VALUES (" + MACH("mach0") + ", " + MACH("mach2") + ", 'feeds')" },
    { as: "ofm_reader", sql: "SELECT problem FROM config.vw_line_flow_problem WHERE line_id = $line", expect: r => r.length === 1 && /feeds two/.test(r[0].problem) },
    { as: "ofm_runtime", sql: EV("mach0", "01:00", 5) },
    { as: "ofm_runtime", sql: EV("mach1", "01:01", 4) },
    { as: "ofm_runtime", sql: EV("mach1", "01:05", 1) },
    { as: "ofm_reader", sql: STOPS, expect: r => stops(r) === "01:01-01:05 starved none" }] },

  // --- time ledger and KPIs (migration 017, step 3a.7) -------------------------------------------
  { name: "time ledger: each slice by the first rule that applies (ADR-0009), the worked example", steps: [
    ...LEDGER_SETUP,
    { as: "ofm_reader", sql: "SELECT to_char(slice_start AT TIME ZONE 'Australia/Melbourne', 'HH24:MI') || ' ' || round(duration_s) || ' ' || rule || coalesce(' ' || loss_category_id, '') || coalesce(' ' || reason_code, '') AS s " +
        "FROM hist.fn_time_ledger($line, " + L("08:30") + ", " + L("10:30") + ")",
      expect: r => r.map(x => x.s).join(" | ") ===
        "08:30 1800 no_activity 2 | 09:00 300 changeover 6 | 09:05 600 running | 09:15 300 reason 9 zz_motor | 09:20 600 running | " +
        "09:30 120 minor_stop 12 | 09:32 480 running | 09:40 420 unaccounted 90 | 09:47 180 running | 09:50 600 planned_window 5 | 10:00 1800 no_activity 2" }] },
  { name: "line KPIs: the waterfall of the worked example, to the second; it closes; OEE = A x P x Q", steps: [
    ...LEDGER_SETUP,
    { as: "ofm_reader", sql: KPI, expect: r => {
        const k = r[0];
        const pos = [k.pos1_s, k.pos2_s, k.pos3_s, k.pos4_s, k.pos5_s, k.pos6_s, k.pos7_s, k.pos8_s, k.pos9_s, k.pos10_s, k.pos11_s, k.pos12_s, k.unaccounted_s, k.pos13_s, k.running_s].map(Math.round).join();
        return pos === "7200,3600,3600,0,600,300,0,2700,300,630,30,120,420,1200,1860" && k.good === 2000 && k.reject === 50 &&
          near(k.availability, 1860 / 2700) && near(k.performance, 1230 / 1860) && near(k.quality, 2000 / 2050) && near(k.oee, 1200 / 2700) &&
          near(k.availability * k.performance * k.quality, k.oee) && closes(k) &&
          Math.abs(k.pos10_s + k.pos11_s + k.pos13_s - k.running_s) < 0.001 && near(k.downtime_h, 840 / 3600) &&
          k.kpi_rule_id !== null && k.performance_over_100 === false;
      } }] },
  { name: "line KPIs: a correction reclassifies history at once (the uncoded fault coded later)", steps: [
    ...LEDGER_SETUP,
    { as: "ofm_runtime", sql: "SELECT config.fn_assign_reason($machine, " + L("09:40") + ", 'zz_motor', 'supervisor') AS at" },
    { as: "ofm_reader", sql: KPI, expect: r => Math.round(r[0].pos9_s) === 720 && Math.round(r[0].unaccounted_s) === 0 && closes(r[0]) }] },
  { name: "line KPIs: a rated speed set too low shows as performance above 100 %, flagged, not clipped", steps: [
    ...LEDGER_SETUP,
    { as: "ofm_runtime", sql: COUNT_ROWS("count_good", 4000, "09:25", 1) },
    { as: "ofm_reader", sql: KPI, expect: r => r[0].performance > 1 && r[0].pos10_s < 0 && r[0].performance_over_100 === true && closes(r[0]) }] },
  { name: "line KPIs: without any order, downtime but no OEE", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: RULE_AT("mach1", false) },
    { as: "ofm_config", sql: "INSERT INTO config.line_schedule (line_id, kind, mon, start_time, end_time, valid_from) VALUES ($line, 'production', true, '09:00', '10:00', '2026-01-01')" },
    { as: "ofm_runtime", sql: EVL("09:00", 1) },
    { as: "ofm_runtime", sql: EVL("09:30", 5) },
    { as: "ofm_runtime", sql: COUNT_ROWS("count_good", 100, "09:05", 5) },
    { as: "ofm_reader", sql: KPI, expect: r => r[0].oee === null && r[0].pos13_s === null && Math.round(r[0].unaccounted_s) === 1800 && closes(r[0]) }] },
  { name: "line KPIs: hourly, daily and DST days in local time; every period closes", steps: [
    ...LEDGER_SETUP,
    { as: "ofm_reader", sql: "SELECT to_char(period_start AT TIME ZONE 'Australia/Melbourne', 'HH24') AS h, round(pos13_s) AS p13 FROM hist.fn_line_kpi_series($line, " + L("08:00") + ", " + L("11:00") + ", 'hour')",
      expect: r => r.map(x => x.h + ":" + x.p13).join() === "08:0,09:1200,10:0" },
    { as: "ofm_config", sql: "INSERT INTO config.line_schedule (line_id, kind, sun, start_time, end_time, valid_from) VALUES ($line, 'production', true, '00:00', '06:00', '2026-01-01')" },
    { as: "ofm_runtime", sql: "INSERT INTO hist.machine_state_event (machine_id, ts, state_id, cause) VALUES ($machine, '2026-10-03 23:00+10', 1, 'rule'), ($machine, '2026-04-04 23:00+11', 1, 'rule')" },
    { as: "ofm_reader", sql: "SELECT round(pos1_s) AS p1, round(pos2_s) AS p2, round(running_s) AS run, round(pos2_s + pos4_s + pos5_s + pos6_s + pos7_s + pos9_s + pos12_s + unaccounted_s + running_s) AS sum " +
        "FROM hist.fn_line_kpi_series($line, '2026-10-03 00:00+10', '2026-10-06 00:00+11', 'day')",
      expect: r => r.map(x => x.p1 + "/" + x.sum + "/" + x.run).join() === "86400/86400/0,82800/82800/18000,86400/86400/3600" },   // Mon 5 Oct: 09:00-10:00
    { as: "ofm_reader", sql: "SELECT round(pos1_s) AS p1, round(running_s) AS run FROM hist.fn_line_kpi_series($line, '2026-04-05 00:00+11', '2026-04-06 00:00+10', 'day')",
      expect: r => r.length === 1 && Number(r[0].p1) === 90000 && Number(r[0].run) === 25200 },
    { as: "ofm_reader", sql: "SELECT count(*)::int AS n FROM hist.fn_line_kpi_series($line, '2026-10-04 00:00+10', '2026-10-05 00:00+11', 'hour')", expect: r => r[0].n === 23 }] },
  { name: "machine reliability: breakdowns are own Pos 9 stops; MTBF on running time, MTTR on their length", steps: [
    ...LEDGER_SETUP,
    { as: "ofm_runtime", sql: "SELECT config.fn_assign_reason($machine, " + L("09:40") + ", 'zz_motor', 'supervisor') AS at" },
    { as: "ofm_reader", sql: "SELECT machine_name, round(running_s) AS run, breakdowns, round(breakdown_s) AS brk, round(mtbf_h::numeric, 4) AS mtbf, round(mttr_min::numeric, 2) AS mttr " +
        "FROM hist.fn_machine_reliability($line, " + L("08:30") + ", " + L("10:30") + ") WHERE machine_name = 'mach1'",
      expect: r => Number(r[0].run) === 1860 && r[0].breakdowns === 2 && Number(r[0].brk) === 720 && Number(r[0].mtbf) === Number((1860 / 3600 / 2).toFixed(4)) && Number(r[0].mttr) === 6 }] },
  { name: "live KPIs: hour, day and the running order of a line with a KPI rule; the runtime may read them", steps: [
    ...LINE_SETUP,
    { as: "ofm_config", sql: RULE_AT("mach1", true) },
    ...ORDER_SETUP,
    { as: "ofm_runtime", sql: START("wo1") },
    { as: "ofm_runtime", sql: "SELECT period, line_topic, wo_number FROM hist.fn_live_line_kpi() WHERE line_id = $line ORDER BY period",
      expect: r => r.map(x => x.period).join() === "day,hour,order" && r[0].line_topic === "zz_test/site1/area1/line1" && r[2].wo_number === "wo1" }] },

  // --- audit (Overview §11) -----------------------------------------------------------------
  { name: "a model change is audited with old and new values", steps: [
    { as: "ofm_config", sql: "UPDATE config.machine_property SET alarm_high = 75 WHERE id = $temp" },
    { as: "ofm_reader", sql: "SELECT action, old_row->>'alarm_high' AS old, new_row->>'alarm_high' AS new, changed_by = session_user AS by_login FROM audit.audit_log WHERE table_name = 'config.machine_property' AND row_id = $temp ORDER BY id DESC LIMIT 1",
      expect: r => r.length === 1 && r[0].action === "UPDATE" && Number(r[0].old) === 80 && Number(r[0].new) === 75 && r[0].by_login === true },
    { as: "ofm_reader", sql: "SELECT updated_by FROM config.machine_property WHERE id = $temp", expect: r => r[0].updated_by === "ofm_config" }] },
  { name: "audit columns: created_by cannot be altered", steps: [
    { as: "ofm_config", sql: "UPDATE config.machine_property SET created_by = 'someone_else' WHERE id = $temp" },
    { as: "ofm_reader", sql: "SELECT created_by FROM config.machine_property WHERE id = $temp", expect: r => r[0].created_by !== "someone_else" }] }
];

// Replace $name placeholders with the test plant's IDs.
function bind(sql, ids) {
  const params = [];
  const text = sql.replace(/\$([a-z]+)/g, (_, k) => {
    if (!(k in ids)) throw new Error("unknown placeholder $" + k);
    params.push(ids[k]);
    return "$" + params.length;
  });
  return { text, params };
}

async function runCase(db, c) {
  await db.query("BEGIN");
  try {
    const ids = await testPlant(db);
    for (const [i, s] of c.steps.entries()) {
      const label = "step " + (i + 1) + " as " + s.as;
      const { text, params } = bind(s.sql, ids);
      await db.query("SAVEPOINT step");
      await db.query("SET LOCAL ROLE " + s.as);
      let rows = null, code = null;
      try {
        rows = (await db.query(text, params)).rows;
      } catch (e) {
        code = e.code || e.message;
      }
      await db.query(code ? "ROLLBACK TO SAVEPOINT step" : "RELEASE SAVEPOINT step");
      await db.query("RESET ROLE");
      const expect = s.expect || "ok";
      if (typeof expect === "string" && expect !== "ok") {
        if (code !== expect) return label + ": expected refusal " + expect + ", got " + (code || "success");
      } else if (code) {
        return label + ": failed with " + code;
      } else if (typeof expect === "function" && !expect(rows)) {
        return label + ": unexpected result " + JSON.stringify(rows);
      }
    }
    return null;
  } finally {
    await db.query("ROLLBACK");
  }
}

module.exports.run = async function (t) {
  let db;
  try {
    db = await connectDb();
  } catch (e) {
    t.check("database reachable as " + (process.env.PGUSER || "?"), false,
      e.message + " - is the stack running? (docker compose up -d)");
    return;
  }
  try {
    // --- structure ------------------------------------------------------------------
    const dir = path.join(ROOT, "db", "migrations");
    const files = fs.readdirSync(dir).filter(f => /^\d{3}-.+\.sql$/.test(f)).sort();
    const applied = new Map((await db.query("SELECT filename, checksum FROM public.schema_migrations")).rows
      .map(r => [r.filename, r.checksum]));
    const problems = [];
    for (const f of files) {
      const sum = crypto.createHash("sha256")
        .update(fs.readFileSync(path.join(dir, f), "utf8").replace(/\r/g, "")).digest("hex");
      if (!applied.has(f)) problems.push(f + " not applied");
      else if (applied.get(f) !== sum) problems.push(f + " edited after it was applied");
    }
    t.check("all " + files.length + " migrations applied, none edited since", problems.length === 0, problems.join("; "));

    const tz = (await db.query("SHOW timezone")).rows[0].TimeZone;
    t.check("database works in UTC (ADR-0003)", tz === "UTC" || tz === "Etc/UTC", "timezone is " + tz);
    const tel = (await db.query("SHOW timescaledb.telemetry_level")).rows[0]["timescaledb.telemetry_level"];
    t.check("TimescaleDB sends no usage reports (telemetry_level off, step 2.8)", tel === "off",
            "telemetry_level is " + tel + " - docker compose up -d applies the setting in docker-compose.yml");

    let hyper = [];
    try {
      hyper = (await db.query("SELECT hypertable_name FROM timescaledb_information.hypertables WHERE hypertable_schema = 'hist' ORDER BY 1")).rows.map(r => r.hypertable_name);
    } catch (e) { /* TimescaleDB missing: reported below */ }
    t.check("historian tables are TimescaleDB hypertables",
      hyper.includes("measurement") && hyper.includes("measurement_text"), "found: " + (hyper.join(", ") || "none"));

    // --- housekeeping (step 2.5) ---------------------------------------------------------
    let jobs = [];
    try {
      jobs = (await db.query(
        "SELECT proc_name, hypertable_name, config FROM timescaledb_information.jobs WHERE hypertable_schema = 'hist'")).rows;
    } catch (e) { /* TimescaleDB missing: reported below */ }
    const job = (proc, table) => jobs.find(j => j.proc_name === proc && j.hypertable_name === table);
    t.check("compression after 7 days on both historian tables",
      ["measurement", "measurement_text"].every(x => job("policy_compression", x) && job("policy_compression", x).config.compress_after === "7 days"),
      JSON.stringify(jobs.filter(j => j.proc_name === "policy_compression").map(j => j.hypertable_name)));
    t.check("1-minute and 1-hour averages kept up to date (refresh policies)",
      job("policy_refresh_continuous_aggregate", "measurement_1m") && job("policy_refresh_continuous_aggregate", "measurement_1h"));
    const keep = x => { const j = job("policy_retention", x); return j ? j.config.drop_after : "none"; };
    t.check("retention set: raw " + keep("measurement") + ", averages " + keep("measurement_1h"),
      ["measurement", "measurement_text", "measurement_1m", "measurement_1h"].every(x => keep(x) !== "none"),
      "missing - run docker compose up -d (the migration runner sets retention from .env)");

    const silent = (await db.query(
      "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace " +
      "WHERE n.nspname = 'config' AND c.relkind IN ('r', 'p') AND NOT EXISTS (" +
      "SELECT 1 FROM pg_trigger g WHERE g.tgrelid = c.oid AND g.tgname = 'trg_notify_model_changed') ORDER BY 1")).rows
      .filter(r => r.relname !== "work_order");   // not part of the runtime model; its events notify on their own channel (migration 015)
    t.check("every configuration table notifies the runtime of changes (step 2.1; work orders by their events)", silent.length === 0,
      "no trigger on: " + silent.map(r => r.relname).join(", "));

    // --- cases ------------------------------------------------------------------------
    for (const c of CASES) {
      let err;
      try { err = await runCase(db, c); } catch (e) { err = "could not run: " + (e.code ? e.code + " " : "") + e.message; }
      t.check(c.name, !err, err);
    }
  } finally {
    await db.end();
  }
};

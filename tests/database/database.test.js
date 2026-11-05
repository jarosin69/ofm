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

// Production context (migration 012): a product and its rate, as steps.
const PCS = "(SELECT id FROM config.engineering_unit WHERE code = 'pcs')";
const ADD_PRODUCT = "INSERT INTO config.material (code, name, material_type, base_unit_id) VALUES ('zz_mix', 'Test mix', 'finished', " + PCS + ")";
const ZZ_MIX = "(SELECT id FROM config.material WHERE code = 'zz_mix')";
// A Sunday window 00:00-06:00 and a Saturday night window 22:00-06:00, in Melbourne time.
const SUNDAY_EARLY = "INSERT INTO config.line_schedule (line_id, kind, sun, start_time, end_time, valid_from) VALUES ($line, 'production', true, '00:00', '06:00', '2026-01-01')";
const hoursOf = r => r.map(x => Number(x.hours));

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
      "SELECT 1 FROM pg_trigger g WHERE g.tgrelid = c.oid AND g.tgname = 'trg_notify_model_changed') ORDER BY 1")).rows;
    t.check("every configuration table notifies the runtime of changes (step 2.1)", silent.length === 0,
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

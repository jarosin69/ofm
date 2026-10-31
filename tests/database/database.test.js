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
  { name: "ofm_reader can read model, historian and audit log", steps: [
    { as: "ofm_reader", sql: "SELECT (SELECT count(*) FROM config.vw_runtime_model) + (SELECT count(*) FROM hist.measurement WHERE false) + (SELECT count(*) FROM audit.audit_log WHERE false) AS n" }] },
  { name: "ofm_reader cannot change anything", steps: [
    { as: "ofm_reader", sql: "UPDATE config.machine_property SET alarm_high = 1 WHERE id = $temp", expect: NO_PERMISSION },
    { as: "ofm_reader", sql: "INSERT INTO hist.measurement (ts, property_id, value, quality, ts_source) VALUES (now(), $temp, 1, 0, 0)", expect: NO_PERMISSION }] },

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

    let hyper = [];
    try {
      hyper = (await db.query("SELECT hypertable_name FROM timescaledb_information.hypertables WHERE hypertable_schema = 'hist' ORDER BY 1")).rows.map(r => r.hypertable_name);
    } catch (e) { /* TimescaleDB missing: reported below */ }
    t.check("historian tables are TimescaleDB hypertables",
      hyper.includes("measurement") && hyper.includes("measurement_text"), "found: " + (hyper.join(", ") || "none"));

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

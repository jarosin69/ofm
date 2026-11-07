// Unit tests for PLC reasons (step 3a.6, ADR-0006): the model cache carries
// each machine's fault code map; "machine states" records the reason of the
// first mapped fault code of a stop, once, also when the code arrives after
// the state; nothing for unmapped codes or while running; the writer stores
// reasons after their events. No database needed.
"use strict";
const { loadFlow, loadFunction } = require("../lib/functions");

const flow = loadFlow();
const M = "acme/melbourne/packing/packline01/erector";

function row(id, name, extra) {
  return Object.assign({
    property_id: id, machine_id: 1, topic: M + "/" + name, display_name: name, description: null,
    datatype: "int", unit: "code", low: null, high: null, alarm_low: null, alarm_high: null, deadband: 0,
    is_historised: true, max_publish_interval_ms: 60000, source_name: "linesim_m1", protocol: "opcua",
    endpoint: "opc.tcp://linesim:4841", source_settings: {}, address: "ns=1;s=" + name, scale_factor: 1,
    scale_offset: 0, cache_key: "linesim_m1|ns=1;s=" + name, role: null, heartbeat_timeout_ms: null,
    machine_topic: M, state_rules: null, fault_reasons: null
  }, extra || {});
}
const RULES = [1, 2, 5].map(c => ({ priority: c, operator: "=", value: String(c), state: { 1: "running", 2: "idle", 5: "fault" }[c] }));

module.exports.run = async function (t) {
  const cache = loadFunction(flow, "ofm_rt_cache", { env: { OFM_RUNTIME_NAME: "ofm_runtime_01" } });
  await cache.run({ payload: [
    row(10, "state_code", { role: "state_code", state_rules: RULES }),
    row(11, "fault_code", { role: "fault_code", fault_reasons: { 103: 40, 104: 41 }, source_name: "linesim_m1b", cache_key: "linesim_m1b|ns=1;s=fault_code" })
  ], trigger: "startup" });
  const m = cache.global.ofm_model.machines[1];
  t.check("cache: the machine's fault code property and its code -> reason map",
    m.fault && m.fault.propertyId === 11 && m.fault.reasons[103] === 40);
  t.check("cache: a new fault code asks for an evaluation; its source does not decide the state",
    cache.global.ofm_model.byProperty[11].stateInput === true && m.sources.join() === "linesim_m1");

  const now = Date.now();
  const values = {};
  const set = (id, v, ts) => { values[id] = { latest: { v, q: "good", ts, tss: "device" } }; };
  const g = { ofm_model: cache.global.ofm_model, ofm_values: values, ofm_states_ready: now - 60000,
    ofm_states: { 1: { state: null, ts: 0, observable: true, liveSince: now - 60000 } } };
  const st = loadFunction(flow, "ofm_rt_states", { global: g });
  const reasons = out => (out && out[1] || []).map(x => x.params).filter(p => p[0] === "r");
  set(10, 1, now - 30000); set(11, 0, now - 30000);
  await st.run({ topic: "tick" });

  set(10, 5, now - 20000);
  let out = await st.run({ topic: "evaluate", machineId: 1 });
  t.check("a fault without a fault code yet: the state event, no reason", out[1].length === 1 && reasons(out).length === 0);
  const eventTs = out[1][0].params[1];
  set(11, 103, now - 19900);
  out = await st.run({ topic: "evaluate", machineId: 1 });
  t.check("the fault code arrives a moment later: its reason for that stop, by plc, at the code's own time",
    reasons(out).length === 1 && JSON.stringify(reasons(out)[0]) === JSON.stringify(["r", 1, eventTs, 40, "plc", now - 19900]));
  set(11, 104, now - 19000);
  out = await st.run({ topic: "evaluate", machineId: 1 });
  t.check("another code during the same stop: the first one stays (root cause)", !out || reasons(out).length === 0);
  await st.run({ topic: "tick" });

  set(10, 1, now - 10000); set(11, 0, now - 10000);
  out = await st.run({ topic: "evaluate", machineId: 1 });
  t.check("running: no reason", reasons(out).length === 0);
  set(11, 104, now - 9000);
  out = await st.run({ topic: "evaluate", machineId: 1 });
  t.check("a fault code while running gives no reason", !out || reasons(out).length === 0);
  set(10, 5, now - 8000);
  out = await st.run({ topic: "evaluate", machineId: 1 });
  t.check("a new stop with the code already showing: reason at once, never before the stop",
    reasons(out).length === 1 && reasons(out)[0][3] === 41 && reasons(out)[0][5] === out[1][0].params[1] && reasons(out)[0][2] === out[1][0].params[1]);

  set(10, 2, now - 5000); set(11, 999, now - 5000);
  out = await st.run({ topic: "evaluate", machineId: 1 });
  t.check("an unmapped code (999): no reason, an operator codes it", reasons(out).length === 0);

  // the writer stores reasons after their events
  const os = require("os"), fs = require("fs"), path = require("path"), zlib = require("zlib");
  const sql = [];
  class Pool { on() {} async query(text, cols) { sql.push({ text, cols }); } async end() {} }
  const writer = loadFunction(flow, "ofm_rt_writer", { global: { pg: { Pool }, fs, path, zlib },
    env: { OFM_RUNTIME_NAME: "ofm_runtime_01", OFM_SF_QUEUE_DIR: fs.mkdtempSync(path.join(os.tmpdir(), "ofm-sf-rs-")) } });
  await writer.run({ params: ["r", 1, now, 40, "plc", now + 100] });
  await writer.run({ params: ["e", now, 1, 5, "rule"] });
  await writer.run({ topic: "tick" });
  const iEvent = sql.findIndex(x => /machine_state_event/.test(x.text)), iReason = sql.findIndex(x => /state_reason/.test(x.text));
  t.check("writer: reasons go to hist.state_reason, after the events of the same batch",
    iEvent >= 0 && iReason > iEvent && JSON.stringify(sql[iReason].cols) === JSON.stringify([[1], [now], [40], ["plc"], [now + 100]]));
};

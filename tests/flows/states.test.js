// Unit tests for machine states and frozen data (step 3a.3; ADR-0006,
// ADR-0007, ADR-0025): the model cache gathers each machine's rules and
// heartbeat; "machine states" applies the rules in order of priority, stamps
// events with the right time and goes unknown on a lost source or frozen
// data; "heartbeat" detects a frozen machine and its recovery; "normalise"
// marks a frozen machine's values bad and asks for evaluations; the writer
// stores events and runtime heartbeats; start-up reconciliation records the
// time the runtime was not running as unknown. No database or PLC needed.
"use strict";
const { loadFlow, loadFunction } = require("../lib/functions");
const contracts = require("../lib/contracts");

const M = "acme/melbourne/packing/packline01/filler";
const flow = loadFlow();

// Rows as config.vw_runtime_model delivers them (the columns the runtime loads).
function row(id, name, extra) {
  return Object.assign({
    property_id: id, machine_id: 2, topic: M + "/" + name, display_name: name, description: null,
    datatype: "int", unit: "code", low: null, high: null, alarm_low: null, alarm_high: null, deadband: 0,
    is_historised: true, max_publish_interval_ms: 60000, source_name: "linesim_m2", protocol: "opcua",
    endpoint: "opc.tcp://linesim:4842", source_settings: {}, address: "ns=1;s=" + name, scale_factor: 1,
    scale_offset: 0, cache_key: "linesim_m2|ns=1;s=" + name, role: null, heartbeat_timeout_ms: null,
    machine_topic: M, state_rules: null
  }, extra || {});
}
const RULES = [3, 1, 2].map(c => ({ priority: c, operator: "=", value: String(c), state: ["running", "idle", "blocked"][c - 1] }));
const ROWS = [
  row(10, "state_code", { role: "state_code", state_rules: RULES }),
  row(11, "fault_bit", { datatype: "bool", unit: null, state_rules: [{ priority: 0, operator: "=", value: "true", state: "fault" }] }),
  row(12, "heartbeat", { role: "heartbeat", heartbeat_timeout_ms: 5000, unit: "s" }),
  row(13, "speed", { datatype: "float", unit: "pcs_per_min", deadband: 1 }),
  row(20, "temp", { machine_id: 3, topic: "acme/melbourne/packing/packline01/closer/temp", machine_topic: "acme/melbourne/packing/packline01/closer",
                    source_name: "linesim_m4", cache_key: "linesim_m4|ns=1;s=temp", datatype: "float", unit: "degC" })
];

module.exports.run = async function (t) {
  // --- 1. the model cache ------------------------------------------------------------
  const cache = loadFunction(flow, "ofm_rt_cache", { env: { OFM_RUNTIME_NAME: "ofm_runtime_01" } });
  let out = await cache.run({ payload: ROWS, trigger: "startup" });
  const model = cache.global.ofm_model;
  const m = model.machines[2];
  t.check("cache: a machine with state rules or a heartbeat is gathered; one without neither is not",
    m && !model.machines[3] && m.topic === M);
  t.check("cache: the machine's rules from all its properties, in order of priority",
    m.rules.map(r => r.priority + ":" + r.state).join() === "0:fault,1:running,2:idle,3:blocked" &&
    m.rules[0].propertyId === 11 && m.rules[0].datatype === "bool");
  t.check("cache: heartbeat property and timeout; the machine's sources",
    m.heartbeat.propertyId === 12 && m.heartbeat.timeoutMs === 5000 && m.sources.join() === "linesim_m2");
  t.check("cache: properties tested by rules ask normalise for evaluations, others do not",
    model.byProperty[10].stateInput === true && model.byProperty[11].stateInput === true && !model.byProperty[13].stateInput &&
    model.byProperty[10].machineId === 2);
  t.check("cache: the first load starts the reconciliation (output 4)", out[3] && out[3].payload === "reconcile" && out[3].trigger === "startup");
  out = await cache.run({ payload: ROWS.map(r => r.property_id === 10 ? Object.assign({}, r, { state_rules: null }) : r)
                                      .map(r => r.property_id === 11 ? Object.assign({}, r, { state_rules: null }) : r), trigger: "notify" });
  t.check("cache: later loads do not reconcile again", out[3] === null);
  t.check("cache: a machine whose rules were all removed has its state topic cleared",
    out[0].some(x => x.topic === M + "/state" && x.payload === "" && x.retain));
  await cache.run({ payload: ROWS, trigger: "notify" });

  // --- 2. machine states ---------------------------------------------------------------------
  const now = Date.now();
  const values = {};
  const set = (id, v, extra) => { values[id] = { latest: Object.assign({ v, q: "good", ts: now - 1000, tss: "device" }, extra || {}) }; };
  const g = { ofm_model: cache.global.ofm_model, ofm_values: values, ofm_sources_down: {}, ofm_frozen: {} };
  const st = loadFunction(flow, "ofm_rt_states", { global: g });
  t.check("states: nothing is evaluated before start-up reconciliation is done", (await st.run({ topic: "tick" })) === null);
  const readyAt = now - 500;
  g.ofm_states = {}; g.ofm_states_ready = readyAt;
  out = await st.run({ topic: "ready" });
  t.check("states: a machine never seen, with no values yet, waits for its first values (no unknown event)", out[0] === null && out[1] === null);
  set(10, 1); set(11, false);
  out = await st.run({ topic: "tick" });
  const first = out[0][0];
  t.check("states: first state from the rules, published retained on .../state",
    first.topic === M + "/state" && first.payload.v === "running" && first.retain && !contracts.validate("machine-state", first.payload));
  t.check("states: a state first seen after start-up is stamped with the read time, not the device's older time",
    first.payload.ts >= readyAt && first.payload.tss === "gateway");
  t.check("states: one historian event [e, ts, machine, state id, cause]",
    out[1].length === 1 && JSON.stringify(out[1][0].params) === JSON.stringify(["e", first.payload.ts, 2, 1, "rule"]));
  t.check("states: unchanged state, nothing sent", (await st.run({ topic: "tick" }))[0] === null);

  set(10, 2, { ts: now + 2000 });
  out = await st.run({ topic: "evaluate", machineId: 2 });
  t.check("states: a change is stamped with the device time of the value that caused it",
    out[0][0].payload.v === "idle" && out[0][0].payload.ts === now + 2000 && out[0][0].payload.tss === "device");
  set(11, true, { ts: now + 1500 });
  out = await st.run({ topic: "evaluate", machineId: 2 });
  t.check("states: the first rule that holds wins (fault bit, priority 0)", out[0][0].payload.v === "fault");
  t.check("states: never before the previous event (+1 ms), even if the value's own time is older",
    out[0][0].payload.ts === now + 2001 && out[1][0].params[3] === 5);
  set(11, false, { ts: now + 3000 }); set(10, 7, { ts: now + 3000 });
  out = await st.run({ topic: "evaluate", machineId: 2 });
  t.check("states: no rule holds -> unknown with quality bad (cause rule)",
    out[0][0].payload.v === "unknown" && out[0][0].payload.q === "bad" && out[1][0].params.slice(3).join() === "9,rule");
  set(10, 3, { ts: now + 4000 }); set(11, null, { q: "bad", ts: now + 4000 });
  out = await st.run({ topic: "evaluate", machineId: 2 });
  t.check("states: a higher-priority rule without a good value -> unknown, never the lower rule's state", out[0] === null);
  set(11, false, { ts: now + 5000, q: "uncertain" });
  out = await st.run({ topic: "evaluate", machineId: 2 });
  t.check("states: an uncertain input gives the state with quality uncertain",
    out[0][0].payload.v === "blocked" && out[0][0].payload.q === "uncertain");

  g.ofm_sources_down.linesim_m2 = now + 6000;
  out = await st.run({ topic: "tick" });
  t.check("states: source lost -> unknown at the moment of loss (cause communication_loss)",
    out[0][0].payload.v === "unknown" && out[0][0].payload.ts === now + 6000 && out[1][0].params[4] === "communication_loss");
  delete g.ofm_sources_down.linesim_m2;
  out = await st.run({ topic: "tick" });
  const back = out[0][0].payload;
  t.check("states: source back -> the actual state, stamped with when it was read again",
    back.v === "blocked" && back.ts >= Date.now() - 50 && back.tss === "gateway");
  g.ofm_frozen[2] = { since: back.ts + 10, at: back.ts + 5000 };
  out = await st.run({ topic: "tick" });
  t.check("states: frozen -> unknown from the last heartbeat change (cause frozen)",
    out[0][0].payload.v === "unknown" && out[0][0].payload.ts === back.ts + 10 && out[1][0].params[4] === "frozen");
  delete g.ofm_frozen[2];
  await st.run({ topic: "tick" });

  const renamed = JSON.parse(JSON.stringify(g.ofm_model));
  renamed.machines[2].topic = M.replace("filler", "filler_a");
  g.ofm_model = renamed;
  out = await st.run({ topic: "tick" });
  t.check("states: machine renamed -> same state republished on the new topic, no new event",
    out[0] && out[0][0].topic === M.replace("filler", "filler_a") + "/state" && out[1] === null);
  g.ofm_model = cache.global.ofm_model;
  await st.run({ topic: "tick" });

  const silent = JSON.parse(JSON.stringify(g.ofm_model));
  silent.machines[7] = { id: 7, topic: M.replace("filler", "new_machine"), rules: [{ priority: 1, propertyId: 99, operator: "=", value: "1", state: "running", datatype: "int" }], sources: [] };
  g.ofm_model = silent;
  await st.run({ topic: "tick" });
  g.ofm_states[7].liveSince -= 11000;
  out = await st.run({ topic: "tick" });
  t.check("states: a machine whose values never arrive is recorded unknown after 10 s",
    out[0] && out[0][0].topic.endsWith("new_machine/state") && out[0][0].payload.v === "unknown");
  g.ofm_model = cache.global.ofm_model;

  const odd = JSON.parse(JSON.stringify(g.ofm_model));
  odd.machines[2].rules = [{ priority: 1, propertyId: 10, operator: "=", value: "x", state: "fault", datatype: "int" },
                           { priority: 2, propertyId: 10, operator: ">=", value: "3", state: "setup", datatype: "int" }];
  g.ofm_model = odd;
  out = await st.run({ topic: "tick" });
  t.check("states: a rule that cannot compare is skipped with one warning; >= works",
    out[0][0].payload.v === "setup" && st.warnings.filter(w => /cannot compare/.test(w)).length === 1);
  await st.run({ topic: "tick" });
  t.check("states: the warning is not repeated", st.warnings.filter(w => /cannot compare/.test(w)).length === 1);
  g.ofm_model = cache.global.ofm_model;

  // --- 3. frozen data in "heartbeat" (ADR-0025) ------------------------------------------------
  const hv = {};
  const hg = { ofm_model: cache.global.ofm_model, ofm_values: hv, ofm_sources_down: {} };
  const hb = loadFunction(flow, "ofm_rt_hb", { global: hg });
  const t0 = Date.now();
  for (const [id, v] of [[10, 1], [11, false], [12, 100], [13, 97.5], [20, 4]]) {
    hv[id] = { latest: { v, q: "good", ts: t0 - 200, tss: "device" }, sent: { v, q: "good", at: t0 } };
  }
  await hb.run({ topic: "tick" });
  t.check("heartbeat: a machine whose heartbeat has just been seen is not frozen", !hg.ofm_frozen[2]);
  hb.context.seen[2].at -= 6000;                                   // 6 s without a change
  hb.context.seen[2].ts -= 6000;
  out = await hb.run({ topic: "tick" });
  const frozenTopics = (out[0] || []).map(x => x.topic.split("/").pop()).sort().join();
  t.check("heartbeat: no change for longer than the timeout -> frozen; all its properties at once bad, no others",
    hg.ofm_frozen[2] && frozenTopics === "fault_bit,heartbeat,speed,state_code" && out[0].every(x => x.payload.q === "bad" && x.payload.v !== null));
  t.check("heartbeat: frozen since the heartbeat's last own time", hg.ofm_frozen[2].since === t0 - 6200);
  t.check("heartbeat: the bad values go to the historian (quality 2)", out[1] && out[1].length === 4 && out[1].every(r => r.params[3] === 2));
  t.check("heartbeat: a warning names the machine and the heartbeat value",
    hb.warnings.some(w => /filler is frozen/.test(w) && /stayed at 100/.test(w)));
  out = await hb.run({ topic: "tick" });
  t.check("heartbeat: frozen is reported once", out[0] === null);
  hv[13].sent.at -= 61000;
  out = await hb.run({ topic: "tick" });
  t.check("heartbeat: while frozen, the republish is bad, never good", out[0] && out[0][0].payload.q === "bad");

  // "normalise" while frozen
  const norm = loadFunction(flow, "ofm_rt_norm", { global: hg });
  const reading = (address, value) => ({ payload: { source: "linesim_m2", address, value, status: "Good", sourceTimestamp: Date.now(), receivedAt: Date.now() } });
  out = await norm.run(reading("ns=1;s=state_code", 2));
  t.check("normalise: a value of a frozen machine is published bad, its own quality kept as latest",
    out[0].payload.q === "bad" && hv[10].latest.q === "good" && out[1].params[3] === 2);
  t.check("normalise: a value tested by a state rule asks for an evaluation of its machine (output 5)",
    out[4] && out[4].topic === "evaluate" && out[4].machineId === 2);
  await norm.run(reading("ns=1;s=speed", 97.5));
  out = await norm.run(reading("ns=1;s=speed", 97.9));
  t.check("normalise: values no rule tests ask for nothing", out[4] === null || out[4] === undefined);

  hv[12].latest = { v: 101, q: "good", ts: Date.now(), tss: "device" };
  out = await hb.run({ topic: "tick" });
  t.check("heartbeat: the heartbeat moves again -> live; values republished with their own quality",
    !hg.ofm_frozen[2] && out[0] && out[0].length === 4 && out[0].every(x => x.payload.q === "good"));
  t.check("heartbeat: a warning says the machine is live again", hb.warnings.some(w => /filler is live again/.test(w)));
  hb.context.seen[2].at -= 6000;
  hg.ofm_sources_down.linesim_m2 = Date.now();
  await hb.run({ topic: "tick" });
  t.check("heartbeat: a lost source is not also frozen (ADR-0007 applies), and timing restarts",
    !hg.ofm_frozen[2] && !hb.context.seen[2]);

  // --- 4. the writer stores events and runtime heartbeats ----------------------------------------
  const os = require("os"), fs = require("fs"), path = require("path"), zlib = require("zlib");
  const sql = [];
  class Pool { on() {} async query(text, cols) { sql.push({ text, cols }); } async end() {} }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ofm-sf-states-"));
  const wg = { pg: { Pool }, fs, path, zlib };
  const writer = loadFunction(flow, "ofm_rt_writer", { global: wg, env: { OFM_RUNTIME_NAME: "ofm_runtime_01", OFM_SF_QUEUE_DIR: dir } });
  await writer.run({ params: [now, 13, 97.5, 0, 0] });
  await writer.run({ params: ["e", now, 2, 1, "rule"] });
  await writer.run({ params: ["h", now, "ofm_runtime_01"] });
  await writer.run({ topic: "tick" });
  const ev = sql.find(q => /machine_state_event/.test(q.text)), beat = sql.find(q => /runtime_heartbeat/.test(q.text));
  t.check("writer: state events go to hist.machine_state_event, replay-safe",
    ev && /ON CONFLICT \(machine_id, ts\) DO NOTHING/.test(ev.text) && JSON.stringify(ev.cols) === JSON.stringify([[now], [2], [1], ["rule"]]));
  t.check("writer: runtime heartbeats go to hist.runtime_heartbeat",
    beat && JSON.stringify(beat.cols) === JSON.stringify([[now], ["ofm_runtime_01"]]));
  t.check("writer: values still go to hist.measurement, in their own query",
    sql.filter(q => /hist\.measurement /.test(q.text)).length === 1 && sql.length === 3);
  t.check("writer: the disk queue's length is shared (global ofm_historian)", wg.ofm_historian && wg.ofm_historian.queueRows === 0);

  // --- 5. start-up reconciliation ------------------------------------------------------------------
  const HB = Date.UTC(2026, 10, 5, 8, 0, 0);
  function reconWith(rows, opts) {
    const queries = [];
    class Client {
      async connect() { if (opts && opts.fail) throw new Error("connect ECONNREFUSED"); }
      async query(text, params) {
        queries.push({ text, params });
        if (/runtime_heartbeat/.test(text)) return { rows: [{ ts: opts && opts.noBeat ? null : HB }] };
        if (/machine_state_event/.test(text)) return { rows };
        if (/production_count/.test(text)) return { rows: [] };
        throw new Error("unexpected " + text);
      }
      async end() {}
    }
    const machines = {
      2: { id: 2, topic: M, rules: [{ priority: 1 }], sources: [] },
      4: { id: 4, topic: M.replace("filler", "closer"), rules: [{ priority: 1 }], sources: [] },
      5: { id: 5, topic: M.replace("filler", "case_packer"), rules: [{ priority: 1 }], sources: [] },
      6: { id: 6, topic: M.replace("filler", "palletiser"), rules: [], heartbeat: {}, sources: [] }
    };
    const glob = { pg: { Client }, ofm_model: { machines }, ofm_historian: { queueRows: 0 } };
    const fn = loadFunction(flow, "ofm_rt_recon", { global: glob, env: { OFM_RUNTIME_NAME: "ofm_runtime_01", OFM_RECONCILE_WAIT_MS: "3000" } });
    return { fn, glob, queries };
  }
  let r = reconWith([
    { machine_id: 2, ts: HB - 3600000, state: "running" },     // running for an hour before the last heartbeat
    { machine_id: 4, ts: HB + 20000, state: "fault" },         // a fault after the last heartbeat
    { machine_id: 5, ts: HB - 600000, state: "unknown" }       // already unknown
  ]);
  out = await r.fn.run({ payload: "reconcile", trigger: "startup" });
  const evs = (out[1] || []).map(x => x.params);
  t.check("reconcile: asks only for this runtime's heartbeat and the machines with state rules",
    r.queries[0].params[0] === "ofm_runtime_01" && r.queries[1].params[0].join() === "2,4,5");
  t.check("reconcile: unknown at the last heartbeat for a machine whose last event is older (cause runtime_outage)",
    evs.some(e => JSON.stringify(e) === JSON.stringify(["e", HB, 2, 9, "runtime_outage"])));
  t.check("reconcile: unknown just after the last event when that is newer than the heartbeat",
    evs.some(e => e[2] === 4 && e[1] === HB + 20001));
  t.check("reconcile: a machine already unknown gets no new event, but its state is published",
    !evs.some(e => e[2] === 5) && out[0].some(x => x.topic.endsWith("case_packer/state") && x.payload.v === "unknown"));
  t.check("reconcile: payloads match machine-state.schema.json", out[0].every(x => !contracts.validate("machine-state", x.payload)));
  t.check("reconcile: hands over the states and says ready",
    out[2].topic === "ready" && r.glob.ofm_states_ready && r.glob.ofm_states[2].state === "unknown" && r.glob.ofm_states[4].ts === HB + 20001);
  t.check("reconcile: runs once only", (await r.fn.run({ payload: "reconcile", trigger: "startup" })) === null);

  r = reconWith([{ machine_id: 2, ts: HB - 3600000, state: "running" }], { noBeat: true });
  out = await r.fn.run({ payload: "reconcile", trigger: "startup" });
  t.check("reconcile: no heartbeat recorded yet -> unknown just after the last event", out[1][0].params[1] === HB - 3600000 + 1);

  r = reconWith([], { fail: true });
  const before = Date.now();
  out = await r.fn.run({ payload: "reconcile", trigger: "startup" });
  t.check("reconcile: database unreadable -> every machine unknown from the start, with a warning",
    out[1].length === 3 && out[1].every(x => x.params[1] >= before) && r.fn.warnings.some(w => /could not be read/.test(w)) && out[2]);
  r = reconWith([]);
  out = await r.fn.run({ payload: "reconcile", trigger: "disk" });
  t.check("reconcile: model from the saved copy -> the database is not asked; unknown from the start",
    r.queries.length === 0 && out[1].length === 3 && r.fn.warnings.some(w => /saved copy/.test(w)));
  r = reconWith([]);
  r.glob.ofm_historian.queueRows = 12;
  setTimeout(() => { r.glob.ofm_historian.queueRows = 0; }, 1200);
  const waitFrom = Date.now();
  await r.fn.run({ payload: "reconcile", trigger: "startup" });
  t.check("reconcile: waits for the historian queue to empty before reading", Date.now() - waitFrom >= 1000 && r.queries.length === 3);

  // --- 6. runtime heartbeat --------------------------------------------------------------------------
  const rg = {};
  const rthb = loadFunction(flow, "ofm_rt_rthb", { global: rg, env: { OFM_RUNTIME_NAME: "ofm_runtime_01" } });
  t.check("runtime heartbeat: nothing before reconciliation is done", (await rthb.run({ topic: "tick60" })) === null);
  rg.ofm_states_ready = Date.now();
  const b = await rthb.run({ topic: "tick60" });
  t.check("runtime heartbeat: one row [h, ts, runtime] for the writer", b.params[0] === "h" && b.params[2] === "ofm_runtime_01" && b.params[1] >= rg.ofm_states_ready);
};

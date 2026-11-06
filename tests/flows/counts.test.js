// Unit tests for production counts (step 3a.4, ADR-0026): the model cache
// marks the counters; "normalise" passes their good readings on; "counts"
// turns readings into units per minute, with resets, held readings before
// start-up reconciliation, and late readings; the writer stores the rows;
// reconciliation hands over each counter's last stored reading.
// The clock (Date.now) is set by the test.
"use strict";
const { loadFlow, loadFunction } = require("../lib/functions");

const flow = loadFlow();
const M = "acme/melbourne/packing/packline01/closer";
const realNow = Date.now;

function row(id, name, role, extra) {
  return Object.assign({
    property_id: id, machine_id: 4, topic: M + "/" + name, display_name: name, description: null,
    datatype: "int", unit: "pcs", low: 0, high: null, alarm_low: null, alarm_high: null, deadband: 0,
    is_historised: true, max_publish_interval_ms: 60000, source_name: "linesim_m4", protocol: "opcua",
    endpoint: "opc.tcp://linesim:4844", source_settings: {}, address: "ns=1;s=" + name, scale_factor: 1,
    scale_offset: 0, cache_key: "linesim_m4|ns=1;s=" + name, role, heartbeat_timeout_ms: null,
    machine_topic: M, state_rules: null
  }, extra || {});
}

module.exports.run = async function (t) {
  try {
    await tests(t);
  } finally {
    Date.now = realNow;
  }
};

async function tests(t) {
  // --- the model cache and "normalise" ---------------------------------------------------
  const cache = loadFunction(flow, "ofm_rt_cache", { env: { OFM_RUNTIME_NAME: "ofm_runtime_01" } });
  await cache.run({ payload: [row(30, "count_good", "count_good"), row(31, "count_reject", "count_reject"),
                              row(32, "count_in", "count_in"), row(33, "speed", null, { datatype: "float" }),
                              row(34, "fault_code", "fault_code")], trigger: "startup" });
  const bp = cache.global.ofm_model.byProperty;
  t.check("cache: properties with a count role are counters, others not",
    bp[30].counter && bp[31].counter && bp[32].counter && !bp[33].counter && !bp[34].counter && bp[30].role === "count_good");

  const g = { ofm_model: cache.global.ofm_model };
  const norm = loadFunction(flow, "ofm_rt_norm", { global: g });
  const reading = (name, value, status) => ({ payload: { source: "linesim_m4", address: "ns=1;s=" + name, value,
    status: status || "Good", sourceTimestamp: realNow() - 100, receivedAt: realNow() } });
  let out = await norm.run(reading("count_good", 1200));
  t.check("normalise: a counter reading goes to \"counts\" (output 6) with its own time",
    out[5] && out[5].topic === "count" && out[5].propertyId === 30 && out[5].v === 1200 && out[5].ts === out[0].payload.ts);
  out = await norm.run(reading("speed", 97.5));
  t.check("normalise: other values do not", !out[5]);
  out = await norm.run(reading("count_good", null, "BadNotConnected"));
  t.check("normalise: a bad counter reading is not passed on", !out[5]);

  // --- "counts" ------------------------------------------------------------------------------
  const T = Date.UTC(2026, 10, 6, 9, 0, 0);          // 20:00 Melbourne, a whole minute
  let clock = T + 10000;
  Date.now = () => clock;
  const cg = { ofm_model: cache.global.ofm_model };
  const counts = loadFunction(flow, "ofm_rt_counts", { global: cg });
  const send = (id, v, ts) => counts.run({ topic: "count", propertyId: id, v, ts });
  const tick = () => counts.run({ topic: "tick" });

  await send(30, 1010, T + 9000);
  await send(30, 1015, T + 9500);
  t.check("counts: readings before start-up reconciliation are held", !cg.ofm_counts_ready && cg.ofm_counters[30].held.length === 2);
  out = await counts.run({ topic: "ready", payload: clock, counters: { 30: 1000 } });
  t.check("counts: after \"ready\", held readings are counted from the last stored reading (1000 -> 1015)",
    out === null && cg.ofm_counters[30].buckets[T].inc === 15 && cg.ofm_counters[30].last === 1015);
  await send(31, 7, T + 11000);
  t.check("counts: a counter without a stored reading starts from its first reading (nothing counted)",
    cg.ofm_counters[31].last === 7 && Object.keys(cg.ofm_counters[31].buckets).length === 0);
  await send(30, 1015, T + 12000);
  await send(30, 1020, T + 30000);
  clock = T + 62000;
  out = await tick();
  t.check("counts: nothing is written until the minute is over plus 5 s", out === null);
  await send(30, 1023, T + 61000);
  clock = T + 65000;
  out = await tick();
  const rows = out ? out[0].map(x => x.params) : [];
  t.check("counts: one row per counter and minute: [c, minute, property, units, last reading, resets]",
    rows.length === 1 && JSON.stringify(rows[0]) === JSON.stringify(["c", T, 30, 20, 1020, 0]));
  t.check("counts: the next minute stays open", cg.ofm_counters[30].buckets[T + 60000].inc === 3);
  await send(30, 1025, T + 50000);
  t.check("counts: a late reading of a minute already written goes into the oldest open minute",
    cg.ofm_counters[30].buckets[T + 60000].inc === 5 && !cg.ofm_counters[30].buckets[T]);
  await send(30, 40, T + 100000);
  t.check("counts: a lower reading is a reset: the reading itself is counted, with a warning",
    cg.ofm_counters[30].buckets[T + 60000].inc === 45 && cg.ofm_counters[30].buckets[T + 60000].resets === 1 &&
    counts.warnings.some(w => /closer\/count_good was reset: 1025 -> 40/.test(w)));
  await send(31, 0, T + 101000);
  clock = T + 125000;
  out = await tick();
  const r2 = out[0].map(x => x.params).sort((a, b) => a[2] - b[2]);
  t.check("counts: a reset to 0 without production is still written (units 0, resets 1)",
    JSON.stringify(r2) === JSON.stringify([["c", T + 60000, 30, 45, 40, 1], ["c", T + 60000, 31, 0, 0, 1]]));
  out = await tick();
  t.check("counts: minutes without production write nothing", out === null);
  await send(30, 40, T + 130000);
  clock = T + 190000;
  t.check("counts: an unchanged reading counts nothing", (await tick()) === null);

  await send(32, 100, T + 191000);
  await send(32, 112.5, T + 192000);
  clock = T + 250000;
  out = await tick();
  t.check("counts: a float counter counts fractions", out && out[0][0].params[3] === 12.5);

  const reduced = JSON.parse(JSON.stringify(cg.ofm_model));
  delete reduced.byProperty[31];
  cg.ofm_model = reduced;
  await tick();
  t.check("counts: a counter no longer in the model is forgotten at once", !cg.ofm_counters[31] && cg.ofm_counters[30]);
  cg.ofm_model = cache.global.ofm_model;

  // Readings with an old own time (e.g. the first values after a reconnection).
  clock = T + 600000;
  await send(32, 200, T - 3600000);
  await send(32, 210, T - 3500000);
  clock = T + 665000;
  out = await tick();
  t.check("counts: a reading with an old own time goes into the oldest minute still open, not one long over",
    out && out[0][0].params[1] === T + 540000 && out[0][0].params[3] === 210 - 112.5);

  // --- the writer ------------------------------------------------------------------------------
  Date.now = realNow;
  const os = require("os"), fs = require("fs"), path = require("path"), zlib = require("zlib");
  const sql = [];
  class Pool { on() {} async query(text, cols) { sql.push({ text, cols }); } async end() {} }
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ofm-sf-counts-"));
  const writer = loadFunction(flow, "ofm_rt_writer", { global: { pg: { Pool }, fs, path, zlib },
    env: { OFM_RUNTIME_NAME: "ofm_runtime_01", OFM_SF_QUEUE_DIR: dir } });
  await writer.run({ params: ["c", T, 30, 20, 1020, 0] });
  await writer.run({ topic: "tick" });
  const q = sql.find(x => /production_count/.test(x.text));
  t.check("writer: count rows go to hist.production_count, replay-safe",
    q && /ON CONFLICT \(property_id, ts\) DO NOTHING/.test(q.text) && JSON.stringify(q.cols) === JSON.stringify([[T], [30], [20], [1020], [0]]));

  // --- reconciliation hands over the counters' last readings --------------------------------------
  const asked = [];
  class Client {
    async connect() {}
    async query(text, params) {
      asked.push({ text, params });
      if (/production_count/.test(text)) return { rows: [{ property_id: 30, last_value: "1020" }] };
      return { rows: [] };
    }
    async end() {}
  }
  const recon = loadFunction(flow, "ofm_rt_recon", {
    global: { pg: { Client }, ofm_model: cache.global.ofm_model, ofm_historian: { queueRows: 0 } },
    env: { OFM_RUNTIME_NAME: "ofm_runtime_01", OFM_RECONCILE_WAIT_MS: "3000" } });
  out = await recon.run({ payload: "reconcile", trigger: "startup" });
  const cq = asked.find(x => /production_count/.test(x.text));
  t.check("reconcile: asks for the last stored reading of every counter of this runtime",
    cq && cq.params[0].slice().sort().join() === "30,31,32");
  t.check("reconcile: \"ready\" carries them to \"counts\"", out[2].topic === "ready" && out[2].counters[30] === 1020);
  const recon2 = loadFunction(flow, "ofm_rt_recon", {
    global: { pg: { Client }, ofm_model: cache.global.ofm_model, ofm_historian: { queueRows: 0 } },
    env: { OFM_RUNTIME_NAME: "ofm_runtime_01" } });
  out = await recon2.run({ payload: "reconcile", trigger: "disk" });
  t.check("reconcile: model from the saved copy -> counters start from their first reading, with a warning",
    JSON.stringify(out[2].counters) === "{}" && recon2.warnings.some(w => /3 counter\(s\) start again/.test(w)));
}

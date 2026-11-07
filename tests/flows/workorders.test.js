// Unit tests for work orders in OFM's runtime (step 3a.5, ADR-0010): the
// listener passes work order notifications on; "work orders" publishes each
// line's active order on .../workorder (schemas/workorder.schema.json),
// clears topics of renamed or removed lines, closes the changeover at the
// first good unit after its guard, and retries after a database failure;
// "counts" reports good units of watched counters. No database needed.
"use strict";
const { loadFlow, loadFunction } = require("../lib/functions");
const contracts = require("../lib/contracts");

const flow = loadFlow();
const LINE = "acme/melbourne/packing/packline01";
const T0 = Date.UTC(2026, 10, 6, 10, 0, 0);

function row(extra) {
  return Object.assign({
    line_id: 7, line_topic: LINE, active: true, ts_ms: T0, work_order_id: 31, wo_number: "adhoc-31", material_id: 3,
    sku: "mix500", planned_qty: 4000, started_ms: T0, changeover: true, rate_per_hour: "4800", good_property_id: 7486
  }, extra || {});
}

module.exports.run = async function (t) {
  let rows = [row()], fail = false;
  const asked = [];
  class Pool {
    on() {}
    async query(text, params) { asked.push({ text, params }); if (fail) throw new Error("connection refused"); return { rows }; }
  }
  const g = { pg: { Pool } };
  const wo = loadFunction(flow, "ofm_rt_wo", { global: g, env: { OFM_RUNTIME_DB_USER: "ofm_runtime" } });

  let out = await wo.run({ topic: "refresh" });
  const m = out[0] && out[0][0];
  t.check("refresh: the active order published retained on .../workorder",
    m && m.topic === LINE + "/workorder" && m.retain && m.payload.active && m.payload.sku === "mix500" && m.payload.ratePerHour === 4800);
  t.check("the payload matches workorder.schema.json", !contracts.validate("workorder", m.payload), contracts.validate("workorder", m.payload));
  t.check("a line in changeover has its output counter watched", g.ofm_wo_watch[7486] === 7);
  out = await wo.run({ topic: "work_order", lineId: 7 });
  t.check("a notification reads only that line; nothing changed, nothing published",
    asked[1].params[0] === 7 && /WHERE line_id = \$1/.test(asked[1].text) && out[0] === null);

  // the first good unit
  out = await wo.run({ topic: "good", propertyId: 7486, ts: T0 + 4000 });
  t.check("a good unit within 10 s of the start is the previous order's: the changeover stays open", out === null);
  out = await wo.run({ topic: "good", propertyId: 7486, ts: T0 + 600000 });
  t.check("the first good unit after that closes the changeover: changeover_end entered_by ofm, and published",
    out[1] && JSON.stringify(out[1].params) === JSON.stringify(["w", T0 + 600000, 31, "changeover_end", "ofm"]) &&
    out[0].payload.changeover === false && out[0].payload.ts === T0 + 600000 && !contracts.validate("workorder", out[0].payload));
  t.check("... and the counter is no longer watched", !g.ofm_wo_watch[7486]);
  out = await wo.run({ topic: "work_order", lineId: 7 });
  t.check("the database not yet updated: the closed changeover is not reopened", out[0] === null);
  rows = [row({ changeover: false, ts_ms: T0 + 600000 })];
  out = await wo.run({ topic: "work_order", lineId: 7 });
  t.check("the database updated: nothing to republish", out[0] === null);

  rows = [row({ active: false, ts_ms: T0 + 900000 })];
  out = await wo.run({ topic: "work_order", lineId: 7 });
  t.check("completed: {active: false, ts} published", out[0][0].payload.active === false && Object.keys(out[0][0].payload).length === 2 &&
    !contracts.validate("workorder", out[0][0].payload));

  rows = [row({ line_topic: "acme/melbourne/packing/pack_a", work_order_id: 32, wo_number: "adhoc-32" })];
  out = await wo.run({ topic: "refresh" });
  t.check("line renamed: the old topic is cleared, the new one published",
    out[0].length === 2 && out[0][0].topic === LINE + "/workorder" && out[0][0].payload === "" && out[0][1].topic === "acme/melbourne/packing/pack_a/workorder");
  rows = [];
  out = await wo.run({ topic: "refresh" });
  t.check("line gone (demo removed): its topic is cleared", out[0].length === 1 && out[0][0].payload === "" && !g.ofm_wo_watch[7486]);

  fail = true;
  out = await wo.run({ topic: "refresh" });
  t.check("database unreachable: nothing published, a retry is planned", out === null && wo.context.retryAt > Date.now());
  fail = false; rows = [row()];
  out = await wo.run({ topic: "tick" });
  t.check("the tick before the retry time does nothing", out === null);
  wo.context.retryAt = Date.now() - 1;
  out = await wo.run({ topic: "tick" });
  t.check("the tick after it reads every line again", out && out[0] && out[0][0].payload.active === true);

  // the listener passes work order notifications on (its code, without a database)
  const listen = flow.find(n => n.id === "ofm_rt_listen");
  t.check("listener: LISTENs on work_order too, and sends its notifications to output 2",
    /LISTEN work_order/.test(listen.func) && /n\.channel === "work_order"/.test(listen.func) && listen.outputs === 2 &&
    listen.wires[1].includes("ofm_rt_wo"));

  // "counts" reports good units of a watched counter
  const cg = { ofm_model: { byProperty: { 7486: { counter: true, topic: LINE + "/closer/count_good" } } }, ofm_counts_ready: Date.now(), ofm_wo_watch: { 7486: 7 } };
  const counts = loadFunction(flow, "ofm_rt_counts", { global: cg });
  await counts.run({ topic: "count", propertyId: 7486, v: 100, ts: T0 });
  out = await counts.run({ topic: "count", propertyId: 7486, v: 101, ts: T0 + 1000 });
  t.check("counts: a watched counter going up is reported to \"work orders\" (output 2)",
    out && out[0] === null && out[1][0].topic === "good" && out[1][0].propertyId === 7486 && out[1][0].ts === T0 + 1000);
  cg.ofm_wo_watch = {};
  out = await counts.run({ topic: "count", propertyId: 7486, v: 102, ts: T0 + 2000 });
  t.check("counts: unwatched, nothing reported", out === null);

  // the writer stores work order events
  const os = require("os"), fs = require("fs"), path = require("path"), zlib = require("zlib");
  const sql = [];
  class WPool { on() {} async query(text, cols) { sql.push({ text, cols }); } async end() {} }
  const writer = loadFunction(flow, "ofm_rt_writer", { global: { pg: { Pool: WPool }, fs, path, zlib },
    env: { OFM_RUNTIME_NAME: "ofm_runtime_01", OFM_SF_QUEUE_DIR: fs.mkdtempSync(path.join(os.tmpdir(), "ofm-sf-wo-")) } });
  await writer.run({ params: ["w", T0, 31, "changeover_end", "ofm"] });
  await writer.run({ topic: "tick" });
  const q = sql.find(x => /work_order_event/.test(x.text));
  t.check("writer: work order events go to hist.work_order_event; a second changeover_end is ignored",
    q && /ON CONFLICT \(work_order_id, event_type\) DO NOTHING/.test(q.text) && JSON.stringify(q.cols) === JSON.stringify([[T0], [31], ["changeover_end"], ["ofm"]]));
};

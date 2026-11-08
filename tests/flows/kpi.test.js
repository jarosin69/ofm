// Unit tests for live line KPIs in OFM's runtime (step 3a.7, ADR-0008):
// "line KPIs" publishes what hist.fn_live_line_kpi returns on
// .../kpi/hour|day|order (schemas/line-kpi.schema.json), only after start-up
// reconciliation, clears topics that no longer apply, and publishes nothing
// when the database cannot be read. No database needed.
"use strict";
const { loadFlow, loadFunction } = require("../lib/functions");
const contracts = require("../lib/contracts");

const flow = loadFlow();
const LINE = "acme/melbourne/packing/packline01";
const T0 = Date.UTC(2026, 10, 6, 10, 0, 0);

function row(period, extra) {
  return Object.assign({
    line_id: 7, line_topic: LINE, period, work_order_id: period === "order" ? 31 : null, wo_number: period === "order" ? "adhoc-31" : null,
    from_ms: T0, to_ms: T0 + 1800000, oee: 0.612345678, availability: 0.8, performance: 0.81, quality: 0.945,
    good: 1290, reject: 75, running_s: 1440.04, unaccounted_s: 0, kpi_rule_id: 1, performance_over_100: false
  }, extra || {});
}

module.exports.run = async function (t) {
  let rows = [row("hour"), row("day", { from_ms: T0 - 36000000 }), row("order")], fail = false;
  const asked = [];
  class Pool {
    on() {}
    async query(text) { asked.push(text); if (fail) throw new Error("connection refused"); return { rows }; }
  }
  const g = { pg: { Pool } };
  const kpi = loadFunction(flow, "ofm_rt_kpi", { global: g, env: { OFM_RUNTIME_DB_USER: "ofm_runtime" } });

  let out = await kpi.run({ topic: "tick60" });
  t.check("before start-up reconciliation is done: nothing read, nothing published", out === null && asked.length === 0);

  g.ofm_states_ready = Date.now();
  out = await kpi.run({ topic: "tick60" });
  const msgs = (out && out[0]) || [];
  const byTopic = Object.fromEntries(msgs.map(m => [m.topic, m]));
  t.check("hour, day and order published retained on .../kpi/{period}, from hist.fn_live_line_kpi()",
    msgs.length === 3 && msgs.every(m => m.retain) && byTopic[LINE + "/kpi/hour"] && byTopic[LINE + "/kpi/day"] &&
    byTopic[LINE + "/kpi/order"] && /hist\.fn_live_line_kpi\(\)/.test(asked[0]));
  const bad = msgs.map(m => contracts.validate("line-kpi", m.payload)).filter(Boolean);
  t.check("every payload matches line-kpi.schema.json", bad.length === 0, bad.join(" | "));
  const h = byTopic[LINE + "/kpi/hour"].payload, o = byTopic[LINE + "/kpi/order"].payload;
  t.check("ratios rounded to 4 decimals, seconds to 0.1 s; the period's start and end",
    h.oee === 0.6123 && h.runningS === 1440 && h.fromTs === T0 && h.toTs === T0 + 1800000 && h.period === "hour");
  t.check("the order topic carries the order; the others do not",
    o.workOrderId === 31 && o.woNumber === "adhoc-31" && h.workOrderId === undefined);
  t.check("every topic name ends in kpi/<period> and maps to line-kpi in the contracts",
    msgs.every(m => contracts.schemaNameForTopic(m.topic) === "line-kpi"));

  rows = [row("hour", { oee: null, availability: null, performance: null, quality: null }), row("day")];
  out = await kpi.run({ topic: "tick60" });
  const cleared = out[0].filter(m => m.payload === "");
  t.check("no order running any more: .../kpi/order cleared (empty retained message)",
    cleared.length === 1 && cleared[0].topic === LINE + "/kpi/order" && cleared[0].retain);
  t.check("no ideal cycle time yet: the ratios are null, still a valid payload",
    out[0][0].payload.oee === null && !contracts.validate("line-kpi", out[0][0].payload));

  rows = [row("hour", { line_topic: "acme/melbourne/packing/pack_a" }), row("day", { line_topic: "acme/melbourne/packing/pack_a" })];
  out = await kpi.run({ topic: "refresh" });
  t.check("line renamed: the old topics cleared, the new ones published",
    out[0].filter(m => m.payload === "").map(m => m.topic).sort().join() === [LINE + "/kpi/day", LINE + "/kpi/hour"].join() &&
    out[0].filter(m => m.payload !== "").every(m => m.topic.startsWith("acme/melbourne/packing/pack_a/kpi/")));

  fail = true;
  out = await kpi.run({ topic: "tick60" });
  t.check("database unreachable: nothing published (the old values keep their old ts)", out === null && !kpi.context.busy);
  fail = false; rows = [];
  out = await kpi.run({ topic: "tick60" });
  t.check("the line lost its KPI rule (or demo removed): its topics cleared", out[0].length === 2 && out[0].every(m => m.payload === ""));
  out = await kpi.run({ topic: "tick60" });
  t.check("nothing left to publish or clear: no message", out === null);

  // wiring: every minute, and after every model load
  const tick = flow.find(n => n.id === "ofm_rt_kpi_tick"), cache = flow.find(n => n.id === "ofm_rt_cache");
  const node = flow.find(n => n.id === "ofm_rt_kpi");
  t.check("wired: a 60 s tick (also once at start), every model load, and the UNS output",
    tick && tick.repeat === "60" && tick.once === true && tick.wires[0].includes("ofm_rt_kpi") &&
    cache.wires[4].includes("ofm_rt_kpi") && node.wires[0].includes("ofm_rt_out_uns"));
};

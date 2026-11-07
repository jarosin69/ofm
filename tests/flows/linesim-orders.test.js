// Unit tests for the simulator's work orders (step 3a.5, ADR-0023 decision 6):
// it follows OFM's .../workorder (changeover to the order's product, stop at
// its planned quantity, wait without an order); the auto-operator starts the
// plan's next order after its delay, only inside the shift pattern; the
// panel's Start and Complete; the UNS connection; the database calls.
// Time is simulated (msg.now).
"use strict";
const path = require("path");
const { ROOT, readJson } = require("../lib/harness");
const { loadFlow, loadFunction } = require("../lib/functions");

const FLOW = path.join(ROOT, "demo", "packing-line", "linesim-flows.json");
const LINE = path.join(ROOT, "demo", "packing-line", "line.json");
const TOPIC = "acme/melbourne/packing/packline01/workorder";

function makeLine(change) {
  const l = readJson(LINE);
  l.seed = 777;
  l.schedule.enabled = false;
  l.unknownFaultPct = 0;
  l.quality.weightSigmaPct = 0;
  for (const m of l.machines) {
    Object.assign(m, { mtbfH: 0, jamsPerH: 0, rejectPct: 0, speedPct: 100 });
    if (m.shortage) m.shortage.perShift = 0;
    if (m.palletWait) m.palletWait.probability = 0;
  }
  l.orders.autoOperator.enabled = false;
  if (change) change(l);
  return l;
}
async function start(line, t0) {
  const e = loadFunction(loadFlow(FLOW), "linesim_engine");
  let t = t0 || Date.UTC(2026, 10, 2, 0, 0, 0);
  let snap = null, panel = null;
  const requests = [];
  await e.run({ topic: "config", payload: line, now: t });
  const keep = res => {
    if (!res) return;
    if (res[0]) snap = res[0].payload;
    if (res[1]) panel = res[1].payload;
    if (res[2]) requests.push(res[2].payload);
  };
  return {
    async run(seconds) {
      for (let i = 0; i < Math.round(seconds * 10); i++) keep(await e.run({ topic: "tick", now: (t += 100) }));
      return snap;
    },
    async order(payload, topic) { keep(await e.run({ topic: topic || TOPIC, payload, now: t })); },
    async cmd(p) { keep(await e.run({ topic: "cmd", payload: p, now: t })); },
    async result(ok, error) { keep(await e.run({ topic: "orderresult", ok, error, now: t })); },
    get panel() { return panel; },
    requests,
    get now() { return t; }
  };
}
const by = (snap, name) => snap.machines.find(m => m.name === name);
const order = (id, sku, qty, extra) => Object.assign({ active: true, ts: 1, workOrderId: id, woNumber: "adhoc-" + id, productId: 1, sku,
  plannedQty: qty, ratePerHour: 6000, startedTs: 1, changeover: true }, extra || {});

module.exports.run = async function (t) {
  // --- following orders ----------------------------------------------------------------------
  let sim = await start(makeLine());
  let s = await sim.run(30);
  t.check("following orders, none active: the line waits, every machine idle, nothing made",
    s.mode === "waiting" && s.machines.every(m => m.state === 2 && m.count_good === 0), s.mode);
  await sim.order(order(5, "mix250", 400), "acme/melbourne/packing/otherline/workorder");
  s = await sim.run(5);
  t.check("an order of another line is ignored", s.mode === "waiting");
  await sim.order(order(5, "mix250", 400));
  s = await sim.run(60);
  t.check("an order for the product already set: no changeover, the line runs", s.mode === "run" && s.sku === "mix250" && by(s, "closer").count_good > 0, s.mode);
  await sim.order(order(5, "mix250", 400, { changeover: false, ts: 2 }));
  s = await sim.run(300);
  const p1 = sim.panel;
  t.check("the same order again (changeover closed in OFM): nothing restarts; at 400 good cartons at the closer the line stops",
    s.mode === "waiting" && p1.order.done === true && p1.order.made >= 400 && p1.order.made < 420 && by(s, "filler").state === 2,
    s.mode + " made " + p1.order.made);
  const madeAt = by(s, "closer").count_good;
  s = await sim.run(60);
  t.check("a finished order makes nothing more", by(s, "closer").count_good === madeAt);

  await sim.order(order(6, "mix500", 3000));
  s = await sim.run(10);
  t.check("a new order for another product: changeover (setup) to it", s.mode === "setup" && s.sku === "mix500" && sim.panel.order.made === 0, s.mode + " " + s.sku);
  s = await sim.run(25 * 60);
  t.check("after the changeover, the new product runs", s.mode === "run" && by(s, "filler").speed_setpoint === 80, s.mode + " " + by(s, "filler").speed_setpoint);
  await sim.order({ active: false, ts: 3 });
  s = await sim.run(5);
  t.check("no active order (completed in OFM): the line waits", s.mode === "waiting");
  await sim.order("");
  s = await sim.run(1);
  t.check("a cleared topic counts as no order", s.mode === "waiting");

  // --- the panel ---------------------------------------------------------------------------------
  await sim.cmd({ cmd: "startorder", sku: "mix150", qty: 500 });
  await sim.cmd({ cmd: "completeorder" });
  t.check("panel: Start and Complete become requests for the database (as an operator would)",
    JSON.stringify(sim.requests) === JSON.stringify([{ cmd: "start", sku: "mix150", qty: 500, by: "simulator panel" }, { cmd: "complete", by: "simulator panel" }]));
  await sim.cmd({ cmd: "follow", enabled: false });
  s = await sim.run(30);
  t.check("Follow OFM work orders off: the line runs freely again", s.mode === "run");
  const cmds = loadFunction(loadFlow(FLOW), "linesim_cmds");
  t.check("panel commands: an order needs a product and a quantity above 0",
    (await cmds.run({ payload: { cmd: "startorder", sku: "mix250", qty: "0" } })) === null &&
    (await cmds.run({ payload: { cmd: "startorder", sku: "mix250", qty: "1200" } })).payload.qty === 1200);

  // --- the auto-operator --------------------------------------------------------------------------
  sim = await start(makeLine(l => { l.orders.autoOperator.enabled = true; l.orders.autoOperator.delayMin = 2; }));
  await sim.run(100);
  t.check("auto-operator: waits its delay before starting (no request after 100 s)", sim.requests.length === 0 && sim.panel.auto.startsInS > 0);
  await sim.run(25);
  t.check("auto-operator: after 2 minutes without an order, starts the plan's first order",
    sim.requests.length === 1 && JSON.stringify(sim.requests[0]) === JSON.stringify({ cmd: "start", sku: "mix250", qty: 6000, by: "auto-operator" }));
  await sim.run(30);
  t.check("auto-operator: asks once, then waits for the answer", sim.requests.length === 1 && sim.panel.auto.pending);
  await sim.result(false, "the demo is not loaded in OFM");
  await sim.run(0.1);
  t.check("auto-operator: a refusal is shown in the panel", sim.panel.auto.lastError === "the demo is not loaded in OFM");
  await sim.run(125);
  t.check("auto-operator: tries the plan's next order after its delay", sim.requests.length === 2 && sim.requests[1].sku === "mix500");
  await sim.order(order(8, "mix250", 100));        // same product as now: no changeover
  await sim.run(0.1);
  t.check("auto-operator: the order arriving ends the wait", !sim.panel.auto.pending);
  await sim.run(5 * 60);
  const n = sim.requests.length;
  t.check("auto-operator: at the planned quantity, the next order follows 2 minutes later",
    sim.panel.order.done && n === 3 && sim.requests[2].sku === "mix150", n + " " + JSON.stringify(sim.requests[n - 1]));

  // Outside the shift pattern it waits for the next shift. 2 Nov 2026 is a Monday; 22:30 Melbourne = 11:30 UTC.
  sim = await start(makeLine(l => { l.schedule.enabled = true; l.orders.autoOperator.enabled = true; }), Date.UTC(2026, 10, 2, 11, 30, 0));
  await sim.run(300);
  t.check("auto-operator: no order outside the shift pattern", sim.requests.length === 0 && sim.panel.mode === "off");

  // --- connection to the UNS ----------------------------------------------------------------------
  const conn = loadFunction(loadFlow(FLOW), "linesim_uns_connect", { env: { OFM_MQTT_READER_PASSWORD: "pw" } });
  let out = await conn.run({ payload: makeLine() });
  t.check("UNS: connects as ofm_reader and subscribes to the line's workorder topic",
    out[0][0].action === "connect" && out[0][0].broker.username === "ofm_reader" && out[0][0].broker.password === "pw" &&
    out[0][1].action === "subscribe" && out[0][1].topic === TOPIC);
  out = await conn.run({ payload: makeLine(l => { l.orders.ofmLine = "acme/melbourne/packing/pack_a"; }) });
  t.check("UNS: line renamed in line.json -> unsubscribe the old topic, subscribe the new, no second connect",
    out[0].length === 2 && out[0][0].action === "unsubscribe" && out[0][0].topic === TOPIC && out[0][1].topic === "acme/melbourne/packing/pack_a/workorder");

  // --- the database calls --------------------------------------------------------------------------
  const calls = [];
  let failWith = null;
  class Client {
    constructor(o) { calls.push({ user: o.user, password: o.password }); }
    async connect() { if (failWith) { const e = new Error("refused"); e.code = failWith; throw e; } }
    async query(text, params) { calls.push({ text, params }); return { rows: [{ id: 42 }] }; }
    async end() {}
  }
  const orders = loadFunction(loadFlow(FLOW), "linesim_orders", { global: { pg: { Client } }, env: { OFM_DEMO_DB_PASSWORD: "dpw" } });
  out = await orders.run({ payload: { cmd: "start", sku: "mix250", qty: 6000, by: "auto-operator" } });
  t.check("database: starts an order with demo.start_order as ofm_demo",
    out.topic === "orderresult" && out.ok && calls[0].user === "ofm_demo" && calls[0].password === "dpw" &&
    /demo\.start_order\(\$1, \$2, \$3\)/.test(calls[1].text) && JSON.stringify(calls[1].params) === JSON.stringify(["mix250", 6000, "auto-operator"]));
  out = await orders.run({ payload: { cmd: "complete", by: "simulator panel" } });
  t.check("database: completes with demo.complete_order", out.ok && /demo\.complete_order/.test(calls[3].text));
  failWith = "28P01";
  out = await orders.run({ payload: { cmd: "start", sku: "mix250", qty: 10 } });
  t.check("database: a wrong password is explained", !out.ok && /OFM_DEMO_DB_PASSWORD/.test(out.error));
  const noPw = loadFunction(loadFlow(FLOW), "linesim_orders", { global: { pg: { Client } }, env: {} });
  out = await noPw.run({ payload: { cmd: "start", sku: "mix250", qty: 10 } });
  t.check("database: no password in .env -> a clear message, no connection", !out.ok && /make-env/.test(out.error));
};

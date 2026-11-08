// Live stack: the simulated packing line (ADR-0023, step 3a.1), when it runs
// (COMPOSE_PROFILES contains "demo"). Reads every simulated PLC the way OFM
// will: one OPC UA server per machine, namespace urn:ofm:linesim:m<slot>,
// nine signals, each Good; the heartbeat moves; the state is a valid code.
// When the demo model is loaded (migrate demo, step 3a.3): every machine has
// a valid retained state on .../{machine}/state and state events in the
// historian; while the line produces, every machine's good counter has
// minute rows and the line has good cartons (step 3a.4); once an order has
// been started, the retained .../workorder matches the database (step 3a.5);
// faults with a mapped fault code carry the PLC's reason, and the line's
// stop list can be read (step 3a.6).
// Skipped when the
// simulator is not running.
"use strict";
const path = require("path");
const { ROOT, readJson, fromNodeRed, stack, connectDb } = require("../lib/harness");
const contracts = require("../lib/contracts");
const LINE = "acme/melbourne/packing/packline01";

const SIGNALS = ["State", "FaultCode", "CountIn", "CountGood", "CountReject", "Speed", "SpeedSetpoint", "Heartbeat", "ProcessValue"];
const HOST = process.env.OFM_TEST_LINESIM_HOST || "linesim";

module.exports.run = async function (t) {
  const opcua = fromNodeRed("node-opcua");
  const line = readJson(path.join(ROOT, "demo", "packing-line", "line.json"));
  const machines = line.machines.filter(m => m.enabled !== false);

  const open = async slot => {
    const client = opcua.OPCUAClient.create({
      endpointMustExist: false, securityMode: opcua.MessageSecurityMode.None, securityPolicy: opcua.SecurityPolicy.None,
      connectionStrategy: { maxRetry: 0, initialDelay: 500, maxDelay: 1000 }
    });
    await client.connect("opc.tcp://" + HOST + ":" + (4840 + slot));
    return { client, session: await client.createSession() };
  };

  let first;
  try {
    first = await open(machines[0].slot);
  } catch (e) {
    t.skip("simulated packing line", "not running - add demo to COMPOSE_PROFILES in .env, then docker compose up -d");
    return;
  }
  await first.session.close();
  await first.client.disconnect();

  for (const m of machines) {
    let c;
    try {
      c = await open(m.slot);
    } catch (e) {
      t.check(m.name + ": simulated PLC answers on port " + (4840 + m.slot), false, e.message);
      continue;
    }
    try {
      const ns = (await c.session.readNamespaceArray()).indexOf("urn:ofm:linesim:m" + m.slot);
      const read = async () => c.session.read(SIGNALS.map(s => ({ nodeId: "ns=" + ns + ";s=" + s, attributeId: opcua.AttributeIds.Value })));
      const a = await read();
      await new Promise(r => setTimeout(r, 2500));
      const b = await read();
      const v = name => b[SIGNALS.indexOf(name)].value.value;
      t.check(m.name + " (port " + (4840 + m.slot) + "): namespace urn:ofm:linesim:m" + m.slot + ", nine signals, all Good",
              ns > 0 && b.every(d => d.statusCode.name === "Good"),
              "namespace " + ns + "; " + b.map((d, i) => SIGNALS[i] + " " + d.statusCode.name).join(", "));
      t.check(m.name + ": heartbeat moves and the state is a valid code",
              v("Heartbeat") > a[SIGNALS.indexOf("Heartbeat")].value.value && v("State") >= 1 && v("State") <= 8,
              "heartbeat " + a[SIGNALS.indexOf("Heartbeat")].value.value + " -> " + v("Heartbeat") + ", state " + v("State"));
      t.note(m.name + ": state " + v("State") + ", fault " + v("FaultCode") + ", good " + v("CountGood") + ", speed " + v("Speed") + "/min");
    } finally {
      await c.session.close();
      await c.client.disconnect();
    }
  }

  // --- machine states on the UNS and in the historian (step 3a.3) ---------------------------
  let db, events;
  try {
    db = await connectDb();
    events = (await db.query(`SELECT m.name, count(e.*)::int AS n, (array_agg(s.name ORDER BY e.ts DESC))[1] AS last
      FROM config.machine m JOIN config.line l ON l.id = m.line_id
      LEFT JOIN hist.machine_state_event e ON e.machine_id = m.id LEFT JOIN config.machine_state s ON s.id = e.state_id
      WHERE l.name = 'packline01' AND m.retired_at IS NULL GROUP BY m.name`)).rows;
  } catch (e) {
    t.skip("demo machine states", "database not reachable: " + e.message);
    return;
  } finally {
    if (db) await db.end().catch(() => {});
  }
  if (events.length === 0) {
    t.skip("demo machine states", "the demo model is not loaded - docker compose run --rm migrate demo");
    return;
  }
  const states = await new Promise(resolve => {
    const got = {};
    const client = fromNodeRed("mqtt").connect(stack.mqttUrl, {
      username: "ofm_reader", password: process.env.OFM_MQTT_READER_PASSWORD,
      clientId: "ofm-test-" + Math.random().toString(16).slice(2, 10), connectTimeout: 5000, reconnectPeriod: 0
    });
    const done = () => { client.end(true); resolve(got); };
    client.on("error", done);
    client.on("connect", () => client.subscribe(LINE + "/+/state", { qos: 0 }, () => setTimeout(done, 2000)));
    client.on("message", (topic, buf, packet) => {
      if (packet.retain && buf.length) got[topic.split("/")[4]] = JSON.parse(buf.toString());
    });
  });
  await checkCounts(t);
  await checkOrder(t);
  await checkReasons(t);
  await checkKpis(t);
  for (const m of machines) {
    const s = states[m.name], e = events.find(x => x.name === m.name);
    const problem = s ? contracts.validate("machine-state", s) : "no retained state";
    t.check(m.name + ": retained state on .../" + m.name + "/state, valid, and the same as its last state event",
            !problem && e && e.n > 0 && e.last === s.v,
            (problem || "state " + s.v) + "; " + (e ? e.n + " event(s), last " + e.last : "no events"));
  }
};

// Counts per minute (step 3a.4): over the last 10 minutes.
async function checkCounts(t) {
  const db = await connectDb();
  try {
    const r = (await db.query(`SELECT m.name, count(c.*)::int AS minutes, coalesce(sum(c.increment), 0)::int AS units
      FROM config.machine m JOIN config.line l ON l.id = m.line_id
      JOIN config.machine_property p ON p.machine_id = m.id AND p.role = 'count_good'
      LEFT JOIN hist.production_count c ON c.property_id = p.id AND c.ts > now() - interval '10 minutes'
      WHERE l.name = 'packline01' AND l.retired_at IS NULL AND m.retired_at IS NULL GROUP BY m.name ORDER BY m.name`)).rows;
    const line = (await db.query(`SELECT coalesce(sum(good), 0)::int AS good FROM hist.vw_line_count c JOIN config.line l ON l.id = c.line_id
      WHERE l.name = 'packline01' AND l.retired_at IS NULL AND c.ts > now() - interval '10 minutes'`)).rows[0];
    if (r.every(x => x.minutes === 0)) {
      t.skip("demo counts per minute", "no production in the last 10 minutes (outside the shift pattern, or just started?)");
      return;
    }
    t.check("demo counts per minute: every machine's good counter has minute rows (last 10 minutes)",
            r.length === 6 && r.every(x => x.minutes > 0), r.map(x => x.name + " " + x.minutes + " min, " + x.units).join("; "));
    t.check("demo counts per minute: the line has good cartons (closer)", line.good > 0, line.good + " good");
  } finally {
    await db.end().catch(() => {});
  }
}

// The active work order (step 3a.5): retained on the UNS as in the database.
async function checkOrder(t) {
  const db = await connectDb();
  let row;
  try {
    row = (await db.query(`SELECT w.active, w.wo_number FROM hist.vw_line_work_order w JOIN config.line l ON l.id = w.line_id
      WHERE l.name = 'packline01' AND l.retired_at IS NULL`)).rows[0];
  } finally {
    await db.end().catch(() => {});
  }
  if (!row) {
    t.skip("demo work order", "no order started yet (auto-operator off, or outside the shift pattern)");
    return;
  }
  const got = await new Promise(resolve => {
    let payload = null;
    const client = fromNodeRed("mqtt").connect(stack.mqttUrl, {
      username: "ofm_reader", password: process.env.OFM_MQTT_READER_PASSWORD,
      clientId: "ofm-test-" + Math.random().toString(16).slice(2, 10), connectTimeout: 5000, reconnectPeriod: 0
    });
    const done = () => { client.end(true); resolve(payload); };
    client.on("error", done);
    client.on("connect", () => client.subscribe(LINE + "/workorder", { qos: 0 }, () => setTimeout(done, 2000)));
    client.on("message", (topic, buf) => { if (buf.length) payload = JSON.parse(buf.toString()); });
  });
  const problem = got ? contracts.validate("workorder", got) : "nothing retained on " + LINE + "/workorder";
  t.check("demo work order: retained on .../workorder, valid, and the same as in the database",
          !problem && got.active === row.active && (!row.active || got.woNumber === row.wo_number),
          problem || (got.active ? got.woNumber + " " + got.sku + (got.changeover ? ", changeover" : "") : "no active order"));
}

// PLC reasons and the stop list (step 3a.6), over the last 24 hours.
async function checkReasons(t) {
  const db = await connectDb();
  try {
    const r = (await db.query(`SELECT count(*)::int AS faults, count(er.reason_id)::int AS coded
      FROM hist.machine_state_event e JOIN config.machine m ON m.id = e.machine_id
      JOIN config.line l ON l.id = m.line_id AND l.name = 'packline01' AND l.retired_at IS NULL
      LEFT JOIN hist.vw_effective_reason er ON er.machine_id = e.machine_id AND er.event_ts = e.ts
      WHERE e.state_id = 5 AND e.ts > now() - interval '24 hours'`)).rows[0];
    if (r.faults === 0) {
      t.skip("demo reasons", "no faults in the last 24 hours");
    } else {
      t.check("demo reasons: faults carry the PLC's reason (except unknown fault 999)", r.coded > 0, r.coded + " of " + r.faults + " faults coded");
    }
    const s = (await db.query(`SELECT count(*)::int AS n FROM config.line l, hist.fn_line_stops(l.id, now() - interval '24 hours', now())
      WHERE l.name = 'packline01' AND l.retired_at IS NULL`)).rows[0];
    t.check("demo stop list: hist.fn_line_stops answers for the last 24 hours", s.n >= 0, s.n + " stop slice(s)");
  } finally {
    await db.end().catch(() => {});
  }
}

// Live line KPIs (step 3a.7): retained on .../kpi/hour|day|order, valid, at
// most two minutes old, and the same as the database calculates; the day's
// ledger closes (every second of the day in exactly one loss position, or
// running time where no ideal cycle time splits it into 10, 11 and 13).
async function checkKpis(t) {
  const got = await new Promise(resolve => {
    const payloads = {};
    const client = fromNodeRed("mqtt").connect(stack.mqttUrl, {
      username: "ofm_reader", password: process.env.OFM_MQTT_READER_PASSWORD,
      clientId: "ofm-test-" + Math.random().toString(16).slice(2, 10), connectTimeout: 5000, reconnectPeriod: 0
    });
    const done = () => { client.end(true); resolve(payloads); };
    client.on("error", done);
    client.on("connect", () => client.subscribe(LINE + "/kpi/+", { qos: 0 }, () => setTimeout(done, 2000)));
    client.on("message", (topic, buf, packet) => { if (packet.retain && buf.length) payloads[topic.split("/")[5]] = JSON.parse(buf.toString()); });
  });
  const db = await connectDb();
  let live, ledger;
  try {
    live = (await db.query(`SELECT k.period, k.good, k.reject, round(extract(epoch FROM k.period_start) * 1000)::bigint AS from_ms FROM hist.fn_live_line_kpi() k
      WHERE k.line_topic = $1`, [LINE])).rows;
    ledger = (await db.query(`SELECT k.pos1_s, k.pos2_s + k.pos4_s + k.pos5_s + k.pos6_s + k.pos7_s + k.pos9_s + k.pos12_s + k.unaccounted_s
        + coalesce(k.pos10_s + k.pos11_s + k.pos13_s, k.running_s) AS parts
      FROM config.line l, hist.fn_line_kpi(l.id, date_trunc('day', now() AT TIME ZONE 'Australia/Melbourne') AT TIME ZONE 'Australia/Melbourne', now()) k
      WHERE l.name = 'packline01' AND l.retired_at IS NULL`)).rows[0];
  } finally {
    await db.end().catch(() => {});
  }
  if (!live.length) {
    t.skip("demo line KPIs", "the line has no KPI rule in force");
    return;
  }
  for (const r of live) {
    const p = got[r.period];
    const problem = !p ? "nothing retained on " + LINE + "/kpi/" + r.period
      : contracts.validate("line-kpi", p) || (Date.now() - p.ts > 120000 ? "ts is " + Math.round((Date.now() - p.ts) / 1000) + " s old" : null);
    // the database's figures may have moved on since the runtime published them, by at most a minute's units
    t.check("demo line KPIs: retained on .../kpi/" + r.period + ", valid, under two minutes old, close to the database",
            !problem && (p.fromTs !== Number(r.from_ms) ||                  // a new hour, day or order began since
                         (p.good <= Number(r.good) && Number(r.good) - p.good <= 200)),
            problem || "OEE " + (p.oee === null ? "-" : Math.round(p.oee * 1000) / 10 + " %") + ", good " + p.good + " (database " + Number(r.good) + ")");
  }
  if (!live.some(r => r.period === "order")) {
    t.check("demo line KPIs: no order running, so no .../kpi/order", !got.order, got.order ? "a stale order topic is retained" : "none");
  }
  t.check("demo time ledger: today's loss positions add up to the calendar time",
          ledger && Math.abs(ledger.pos1_s - ledger.parts) < 0.01, ledger ? ledger.pos1_s + " s = " + ledger.parts + " s" : "no result");
}

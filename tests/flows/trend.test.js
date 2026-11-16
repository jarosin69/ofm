// Unit tests for OFM Trend (step H1, ADR-0029) in flows/ofm-screens.json:
// the dashboard can read every page's script; the node "trend" answers one
// browser through the functions of migration 023 only; the CSV export reads
// in pages and writes as it reads; the chart library is served from the
// image. No database or broker needed.
"use strict";
const path = require("path");
const fs = require("fs");
const os = require("os");
const { ROOT, fromNodeRed } = require("../lib/harness");
const { loadFlow, loadFunction } = require("../lib/functions");

const flow = loadFlow(path.join(ROOT, "flows", "ofm-screens.json"));
const A = { socketId: "browser-a" };
const TAG = { id: 9522, topic: "acme/melbourne/packing/packline01/filler/speed", lineId: 7, line: "packline01", lineName: "Packing line 1",
              machineId: 2, machine: "filler", machineName: "Filler", name: "speed", displayName: "Speed", datatype: "float", unit: "pcs_per_min",
              hi: 105, hihi: 110, maxIntervalMs: 60000, timeZone: "Australia/Melbourne" };

// A stand-in for the pg library: answers by the function called, records what was asked.
function fakePg(asked, pages) {
  return {
    Pool: class {
      constructor(cfg) { this.cfg = cfg; }
      on() {}
      async query(text, params) {
        asked.push({ text, params, user: this.cfg.user });
        if (/fn_trend_tags/.test(text)) return { rows: [{ t: [TAG] }] };
        if (/fn_historian_tags/.test(text)) return { rows: [{ property_id: 9522, last_ms: "1794389547390", last_value: 93.5, last_quality: 0, values_24h: "1440", since_ms: "1762480000000" }] };
        if (/fn_trend_bucket/.test(text)) return { rows: [{ s: 3600 }] };
        if (/fn_trend_data/.test(text)) return { rows: [{ t_ms: "1794380400000", v: 93.123456789, v_min: 90, v_max: 96, q: 0, source: "1m", bucket_s: 3600 },
                                                       { t_ms: "1794384000000", v: null, v_min: null, v_max: null, q: 2, source: "1m", bucket_s: 3600 }] };
        if (/fn_trend_stats/.test(text)) return { rows: [{ source: "raw", n: "120", v_min: 90, v_max: 111, v_avg: 99.5, s_covered: 7200, s_above_hi: 600,
                                                           s_above_hihi: 60, s_below_lo: 0, s_below_lolo: 0 }] };
        if (/fn_trend_export/.test(text)) return { rows: pages.shift() || [] };
        // bands and periods (step H2b)
        if (/fn_trend_states/.test(text)) return { rows: [{ machine_id: 2, t0_ms: "1794380400000", t1_ms: "1794381000000", state: "fault", state_name: "Fault",
                                                            colour: "#c62828", reason: "F12 · Jam", dominant: false }] };
        if (/fn_trend_orders/.test(text)) return { rows: [{ line_id: 7, work_order_id: 31, wo_number: "WO-31", sku: "mix500", t0_ms: "1794380000000",
                                                            setup_end_ms: "1794380600000", t1_ms: "1794387600000", running: true }] };
        if (/fn_trend_order_list/.test(text)) return { rows: [{ line_id: 7, work_order_id: 31, wo_number: "WO-31", sku: "mix500", t0_ms: "1794380000000",
                                                                t1_ms: "1794387600000", running: true }] };
        if (/fn_trend_shifts/.test(text)) return { rows: [{ line_id: 7, name: "A", day: "2026-11-11", t0_ms: "1794337200000", t1_ms: "1794366000000" },
                                                           { line_id: 7, name: "B", day: "2026-11-11", t0_ms: "1794366000000", t1_ms: "1794394800000" }] };
        return { rows: [] };
      }
    }
  };
}
function fakeRes() {
  const r = { code: null, headers: {}, body: "", ended: false, headersSent: false };
  r.status = c => { r.code = c; return r; };
  r.set = h => { Object.assign(r.headers, h); r.headersSent = true; return r; };
  r.type = t => { r.headers["Content-Type"] = t; return r; };
  r.send = b => { r.body += b; r.ended = true; return r; };
  r.write = b => { r.body += b; return true; };
  r.end = b => { if (b) r.body += b; r.ended = true; };
  return r;
}

module.exports.run = async function (t) {
  // every page script is something the dashboard can read: one "export default" object
  // with only the options a ui-template takes (it ignores or refuses anything else)
  const acorn = fromNodeRed("acorn");
  const OK_KEYS = ["name", "data", "computed", "methods", "watch", "mounted", "unmounted"];
  const problems = [];
  for (const n of flow.filter(x => x.type === "ui-template")) {
    const m = /<script>([\s\S]*?)<\/script>/.exec(n.format || "");
    if (!m) continue;
    try {
      const tree = acorn.parse(m[1], { ecmaVersion: "latest", sourceType: "module" });
      const d = tree.body.length === 1 && tree.body[0].type === "ExportDefaultDeclaration" ? tree.body[0].declaration : null;
      if (!d || d.type !== "ObjectExpression") problems.push(n.name + ": the script must be exactly one 'export default { ... }'");
      else for (const p of d.properties) if (!OK_KEYS.includes(p.key && p.key.name)) problems.push(n.name + ": option '" + (p.key && p.key.name) + "' is not taken by a dashboard template");
    } catch (e) { problems.push(n.name + ": " + e.message); }
  }
  t.check("every screen's script can be read by the dashboard (one export default; data, computed, methods, watch, mounted, unmounted)",
          problems.length === 0, problems.join("; "));

  const page = flow.find(n => n.type === "ui-page" && n.path === "/trend"), view = flow.find(n => n.id === "ofm_sc_trend_view");
  t.check("OFM Trend is at /dashboard/trend, its own page, answered by the node 'trend'",
          page && view && flow.find(n => n.id === view.group).page === page.id && view.wires[0][0] === "ofm_sc_trend" &&
          flow.find(n => n.id === "ofm_sc_trend").wires[0][0] === "ofm_sc_trend_view");

  // the node "trend"
  const asked = [];
  const trend = loadFunction(flow, "ofm_sc_trend", { global: { pg: fakePg(asked, []) }, env: { OFM_SCREENS_DB_PASSWORD: "x" } });
  await trend.run({ payload: { cmd: "tags" }, _client: A });
  let m = trend.sent.pop();
  t.check("trend: the tag list goes back to that browser only", m && m.topic === "tags" && m.payload[0].id === 9522 && m._client.socketId === "browser-a");
  await trend.run({ payload: { cmd: "historian" }, _client: A });
  m = trend.sent.pop();
  t.check("trend: the historian list, with numbers as numbers", m.topic === "historian" && m.payload[0].values24h === 1440 && m.payload[0].lastMs === 1794389547390);
  asked.length = 0;
  const pens = Array.from({ length: 20 }, (_, i) => 9500 + i);
  await trend.run({ payload: { cmd: "data", req: 7, from: 1794380400000, to: 1794387600000, points: 99999, pens: pens.concat(["x", -3]) }, _client: A });
  m = trend.sent.pop();
  const data = asked.filter(a => /fn_trend_data/.test(a.text)), stats = asked.filter(a => /fn_trend_stats/.test(a.text));
  t.check("trend: data and statistics per pen, at most 16 pens and 4000 points, nothing but the trend functions, as ofm_screens",
          m.topic === "data" && m.payload.req === 7 && data.length === 16 && stats.length === 16 && data[0].params[3] === 4000 &&
          asked.every(a => a.user === "ofm_screens" && /hist\.fn_trend_(data|stats|annotations)\(/.test(a.text)) &&
          asked.filter(a => /fn_trend_annotations/.test(a.text)).length === 1);
  const s = m.payload.series[9500];
  t.check("trend: points as [t, v, min, max, q], with the source and interval; statistics with numbers",
          s.source === "1m" && s.bucketS === 3600 && s.rows[0].join() === "1794380400000,93.123456789,90,96,0" && s.rows[1][1] === null &&
          m.payload.stats[9500].aboveHi === 600 && m.payload.stats[9500].n === 120);
  await trend.run({ payload: { cmd: "data", req: 8, from: 5, to: 2, pens: [1] }, _client: A });
  m = trend.sent.pop();
  t.check("trend: a period that ends before it starts is refused, to that browser", m.topic === "error" && m.payload.req === 8);
  asked.length = 0;
  await trend.run({ payload: { cmd: "stats", req: 9, from: 1794380400000, to: 1794380700000, pens: [9522, 9533] }, _client: A });
  m = trend.sent.pop();
  t.check("trend: statistics alone for the span between cursors A and B (no values read)",
          m.topic === "stats" && m.payload.req === 9 && m.payload.stats[9533].avg === 99.5 && !m.payload.series &&
          asked.length === 2 && asked.every(a => /hist\.fn_trend_stats\(/.test(a.text)) && asked[0].params[1] === "2026-11-11T07:00:00.000Z");
  // compare (step H2b): the same signal one day earlier is a pen of its own, read a day back and drawn a day later
  asked.length = 0;
  const DAY = 86400000;
  await trend.run({ payload: { cmd: "data", req: 10, from: 1794380400000, to: 1794387600000, machines: [2, "x"], lines: [7],
                               bands: { states: true, orders: true, shifts: true },
                               pens: [{ key: "9522", id: 9522, shift: 0 }, { key: "9522:" + DAY, id: 9522, shift: DAY }, { key: "x;drop", id: 9522, shift: 0 }] }, _client: A });
  m = trend.sent.pop();
  const back = asked.find(a => /fn_trend_data/.test(a.text) && a.params[1] === new Date(1794380400000 - DAY).toISOString());
  t.check("compare: a pen shifted by a day reads the day before and is drawn a day later; a bad pen key is refused",
          m.topic === "data" && back && Object.keys(m.payload.series).sort().join() === "9522,9522:" + DAY &&
          m.payload.series["9522:" + DAY].rows[0][0] === 1794380400000 + DAY && m.payload.series["9522:" + DAY].shift === DAY &&
          m.payload.series["9522"].rows[0][0] === 1794380400000);
  const b = m.payload.bands;
  t.check("bands: machine states with colour and reason, orders with the end of changeover, shifts; through the trend functions only",
          b.states[0].join() === "2,1794380400000,1794381000000,fault,Fault,#c62828,F12 · Jam,false" &&
          b.orders[0].setupEnd === 1794380600000 && b.orders[0].number === "WO-31" && b.shifts[1].name === "B" && b.shifts[1].t0 === 1794366000000 &&
          asked.every(a => a.user === "ofm_screens" && /hist\.fn_trend_(data|stats|annotations|states|orders|shifts)\(/.test(a.text)) &&
          asked.find(a => /fn_trend_states/.test(a.text)).params[0].join() === "2");
  asked.length = 0;
  await trend.run({ payload: { cmd: "periods", lines: [7, "x"] }, _client: A });
  m = trend.sent.pop();
  t.check("periods: a line's recent orders and its shifts of the last 14 days, newest first, to choose one as the period",
          m.topic === "periods" && m.payload.orders[0].number === "WO-31" && m.payload.shifts.map(x => x.name).join() === "B,A" &&
          m.payload.shifts[0].day === "2026-11-11" && asked.length === 2 &&
          asked.every(a => /hist\.fn_trend_(order_list|shifts)\(/.test(a.text) && a.params[0].join() === "7"));
  await trend.run({ payload: { cmd: "data" } });
  t.check("trend: nothing is answered to a message without a browser", trend.sent.length === 0);

  // the CSV export
  const pages = [[{ property_id: 9522, ts: new Date(1), csv: "a" }, { property_id: 9522, ts: new Date(2), csv: "b" }], [{ property_id: 9533, ts: new Date(3), csv: "c" }]];
  const exp = loadFunction(flow, "ofm_sc_export", { global: { pg: fakePg(asked, pages) }, env: { OFM_SCREENS_DB_PASSWORD: "x" } });
  asked.length = 0;
  let res = fakeRes();
  await exp.run({ req: { query: { mode: "raw", pens: "9522,9533", from: "1794380400000", to: "1794387600000" } }, res: { _res: res } });
  t.check("export as stored: a CSV file with a header, written as the values are read",
          res.code === 200 && /attachment; filename="ofm-trend-.*-raw\.csv"/.test(res.headers["Content-Disposition"]) &&
          res.body.startsWith("﻿local_time,utc_ms,topic,name,value,unit,quality\r\na\r\nb\r\n") && res.ended &&
          asked.every(a => /hist\.fn_trend_export\(/.test(a.text)) && asked[0].params[0].join() === "9522,9533");
  res = fakeRes();
  asked.length = 0;
  await exp.run({ req: { query: { mode: "shown", pens: "9522", from: "1794380400000", to: "1794387600000", points: "500" } }, res: { _res: res } });
  const lines = res.body.replace("﻿", "").split("\r\n");
  t.check("export as shown: one row per interval with each pen's average, minimum and maximum, 7 significant digits",
          res.code === 200 && /^local_time \(Australia\/Melbourne, interval start\),utc_ms,"Packing line 1 · Filler · Speed \[pcs_per_min\] avg"/.test(lines[0]) &&
          lines[1] === "2026-11-11 18:00:00,1794380400000,93.12346,90,96" && lines[2] === "2026-11-11 19:00:00,1794384000000,,," &&
          asked.some(a => /make_interval\(secs => \$5\)/.test(a.text) && a.params[4] === 3600));
  res = fakeRes();
  await exp.run({ req: { query: { mode: "raw", pens: "", from: "1", to: "2" } }, res: { _res: res } });
  t.check("export: a request without pens is refused (400)", res.code === 400);

  // the chart library
  const file = path.join(os.tmpdir(), "ofm-echarts-test.js");
  fs.writeFileSync(file, "window.echarts = {}");
  const lib = loadFunction(flow, "ofm_sc_lib", { global: { fs, echartsFile: file } });
  m = await lib.run({});
  t.check("the chart library is served from the image, kept in memory (no internet)",
          m.statusCode === 200 && m.payload === "window.echarts = {}" && /javascript/.test(m.headers["Content-Type"]) &&
          flow.find(n => n.id === "ofm_sc_lib_in").url === "/ofm/echarts.min.js");
  const none = loadFunction(flow, "ofm_sc_lib", { global: { fs } });
  m = await none.run({});
  t.check("without the library in the image: an error the browser shows in its console", m.statusCode === 500);
  fs.unlinkSync(file);

  // annotations (step H2a, ADR-0031): sign-in per page, then annotate and remove as that person
  const said = [], q2 = [];
  const pg2 = { Pool: class {
    on() {}
    async query(text, params) {
      q2.push({ text, params });
      if (/fn_annotation_categories/.test(text)) return { rows: [{ c: [{ id: 1, name: "note", displayName: "Note", colour: "#6c7a89" }] }] };
      if (/fn_person_sign_in/.test(text)) return { rows: [params[0] === "1001" && params[1] === "4711" ? { result: "ok", person_id: 22, display_name: "Alex Demo" }
                                                         : params[0] === "1003" ? { result: "no_pin", person_id: 24 } : { result: "wrong_pin", person_id: 22 }] };
      if (/fn_person_set_pin/.test(text)) return { rows: [{ result: "pin_set", person_id: 24, display_name: "Chris Demo" }] };
      if (/fn_person_annotate/.test(text)) return { rows: [{ id: "77" }] };
      if (/fn_person_annotation_remove/.test(text)) return { rows: [{}] };
      return { rows: [] };
    } } };
  const an = loadFunction(flow, "ofm_sc_trend", { global: { pg: pg2 }, env: { OFM_SCREENS_DB_PASSWORD: "x" } });
  const S = "tr-testpage01";
  const run2 = async payload => { an.sent.length = 0; await an.run({ payload, _client: A }); return an.sent.slice(); };
  let out = await run2({ cmd: "hello", screenId: S });
  t.check("annotations: a new page gets the kinds of note and is signed out",
          out[0].topic === "categories" && out[0].payload[0].name === "note" && out[1].topic === "session" && out[1].payload.signedIn === false);
  out = await run2({ cmd: "annotate", screenId: S, ts: 1794380400000, scope: "signal", targetId: 9522, categoryId: 1, text: "x" });
  t.check("annotations: refused before signing in, and nothing reaches the database",
          out.some(m => m.topic === "session" && m.payload.why === "required") && !q2.some(q => /fn_person_annotate/.test(q.text)));
  out = await run2({ cmd: "signin", screenId: S, employeeNo: "1001", pin: "0000" });
  t.check("annotations: a wrong PIN is said, the page stays signed out", out.some(m => m.topic === "notice" && m.payload.kind === "error") && !an.context.sessions[S]);
  out = await run2({ cmd: "signin", screenId: S, employeeNo: "1003", pin: "" });
  t.check("annotations: a first sign-in asks to choose a PIN", out.some(m => m.topic === "session" && m.payload.choosePin === true));
  out = await run2({ cmd: "setpin", screenId: S, employeeNo: "1003", pin: "12" });
  t.check("annotations: a PIN of 2 digits is refused on the page side", out.some(m => m.topic === "notice" && m.payload.kind === "error") &&
          !q2.some(q => /fn_person_set_pin/.test(q.text)));
  out = await run2({ cmd: "signin", screenId: S, employeeNo: "1001", pin: "4711" });
  const ses = out.find(m => m.topic === "session").payload;
  t.check("annotations: signed in for 30 minutes (OFM_TREND_IDLE_MINUTES), recorded as screen 'trend'",
          ses.signedIn && ses.name === "Alex Demo" && Math.abs(ses.expiresAt - Date.now() - 30 * 60000) < 5000 &&
          q2.some(q => /fn_person_sign_in/.test(q.text) && q.params[2] === "trend"));
  q2.length = 0;
  out = await run2({ cmd: "annotate", screenId: S, ts: 1794380400000, tsEnd: 1794384000000, scope: "machine", targetId: 5, categoryId: 1, text: "  door opened  " });
  const call = q2.find(q => /fn_person_annotate/.test(q.text));
  t.check("annotations: saved as the signed-in person (ID 22), times as UTC, text trimmed",
          call && call.params[0] === 22 && call.params[1] === "2026-11-11T07:00:00.000Z" && call.params[2] === "2026-11-11T08:00:00.000Z" &&
          call.params[3] === "machine" && call.params[4] === 5 && call.params[6] === "door opened" && out.some(m => m.topic === "annotated" && m.payload.id === 77));
  out = await run2({ cmd: "annotate", screenId: S, ts: 1794380400000, scope: "signal", targetId: 9522, categoryId: 1, text: "x".repeat(501) });
  t.check("annotations: more than 500 characters is refused", out.some(m => m.topic === "notice" && m.payload.kind === "error"));
  q2.length = 0;
  out = await run2({ cmd: "unannotate", screenId: S, id: 77, reason: "wrong machine" });
  t.check("annotations: removed as the signed-in person, with the reason",
          q2.some(q => /fn_person_annotation_remove/.test(q.text) && q.params.join() === "22,77,wrong machine") && out.some(m => m.topic === "annotated" && m.payload.removed === 77));
  an.context.sessions[S].last = Date.now() - 31 * 60000;                          // 31 minutes without a touch
  out = await run2({ cmd: "annotate", screenId: S, ts: 1794380400000, scope: "signal", targetId: 9522, categoryId: 1, text: "late" });
  t.check("annotations: after 30 minutes without a touch the page is signed out", out.some(m => m.topic === "session" && m.payload.why === "required"));
  out = await run2({ cmd: "annotate", screenId: "x", text: "y" });
  t.check("annotations: a page without a proper screen id cannot act", out.some(m => m.topic === "session" && m.payload.signedIn === false));
};

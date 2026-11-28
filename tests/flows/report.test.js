// Unit tests for OFM Report (step R1, ADR-0033) in flows/ofm-screens.json:
// the page is at /dashboard/report; the node "report" answers one browser,
// works the period out in the site's time zone, asks only the functions of
// migration 031 (as ofm_screens), refuses periods over 93 days and sends
// the figures the page draws. No database needed.
"use strict";
const path = require("path");
const { ROOT } = require("../lib/harness");
const { loadFlow, loadFunction } = require("../lib/functions");

const flow = loadFlow(path.join(ROOT, "flows", "ofm-screens.json"));
const A = { socketId: "browser-a" };
const KPI = (key, extra) => Object.assign({ group_key: key, label: key, period_start: "2026-10-01T00:00:00+10:00", period_end: "2026-10-02T00:00:00+10:00",
  pos1_s: 86400, pos2_s: 28800, pos3_s: 57600, pos4_s: 0, pos5_s: 1800, pos6_s: 1800, pos7_s: 0, pos8_s: 54000, pos9_s: 3600, pos10_s: 5400,
  pos11_s: 900, pos12_s: 1800, unaccounted_s: 300, pos13_s: 42000, running_s: 48300, good: 70000, reject: 1500, availability: 0.894,
  performance: 0.888, quality: 0.979, oee: 0.778, ge: 0.729, lu: 0.667, downtime_h: 1.58, performance_over_100: false }, extra || {});

function fakePg(asked, opts) {
  return {
    Pool: class {
      constructor(cfg) { this.cfg = cfg; }
      on() {}
      async query(text, params) {
        asked.push({ text, params, user: this.cfg.user });
        if (/fn_screen_model/.test(text)) return { rows: [{ m: [{ id: 1, displayName: "Egg line 1" }, { id: 7, displayName: "Packing line 1" }] }] };
        if (/unnest/.test(text)) return { rows: [{ id: 1, has_rule: false }, { id: 7, has_rule: true }] };
        if (/AS d0/.test(text)) return { rows: [opts.period] };
        if (/fn_report_summary/.test(text)) return { rows: [{ line_name: "Packing line 1", line_path: "acme/melbourne/packing", time_zone: "Australia/Melbourne",
                                                             oee_target: 0.65, kpi_rule_changed: false, test_data: false, has_rule: true, test_operations: true }] };
        if (/fn_report_kpi/.test(text)) { const g = groupOf({ text, params }); return { rows: g === "total" ? [KPI("total")] : g === "product" ? [KPI("707", { label: "mix250" })] : [KPI("2026-10-01")] }; }
        if (/fn_report_losses/.test(text)) return { rows: [{ loss_category_id: 10, kind: "speed", reason: "Speed loss", machine: null, stops: null, seconds: 5400,
                                                            share_of_lost: 0.45, oee_points: 10 }] };
        if (/fn_report_orders/.test(text)) return { rows: [{ work_order_id: 31, wo_number: "WO-31", sku: "mix250", product: "Assorted 250 g", planned_qty: 30000,
                                                            planned_start: null, started_at: "2026-10-01T06:00:00+10:00", completed_at: null, partly_outside: false,
                                                            good: 30010, oee: 0.78, biggest_loss: "Speed loss", biggest_loss_s: 5400 }] };
        if (/fn_report_machines/.test(text)) return { rows: [{ machine_id: 2, machine: "Filler", is_constraint: true, charged_s: 3600, breakdowns: 2, mtbf_h: 20, mttr_min: 15 }] };
        return { rows: [] };
      }
    }
  };
}
// the group of a fn_report_kpi call: a literal in the SQL, or its 4th parameter
const groupOf = q => (/'(total|day|week|shift|product|order)'\)/.exec(q.text) || [])[1] || q.params[3];
const PERIOD = days => ({ tz: "Australia/Melbourne", d0: "2026-10-01", dlast: "2026-10-31", days, t0: "1790776800000", t1: "1793451600000", p0: "1788184800000" });

module.exports.run = async function (t) {
  const page = flow.find(n => n.type === "ui-page" && n.path === "/report"), view = flow.find(n => n.id === "ofm_sc_report_view");
  t.check("OFM Report is at /dashboard/report, its own page, answered by the node 'report'",
          page && view && flow.find(n => n.id === view.group).page === page.id && view.wires[0][0] === "ofm_sc_report" &&
          flow.find(n => n.id === "ofm_sc_report").wires[0][0] === "ofm_sc_report_view");
  const links = ["ofm_sc_view", "ofm_sc_trend_view"].map(id => flow.find(n => n.id === id).format);
  t.check("the line view and the trend page link to the report", links.every(f => f.includes('href="/dashboard/report"')));

  let asked = [];
  const rep = loadFunction(flow, "ofm_sc_report", { global: { pg: fakePg(asked, { period: PERIOD(31) }) }, env: { OFM_SCREENS_DB_PASSWORD: "x" } });
  await rep.run({ payload: { cmd: "lines" }, _client: A });
  let m = rep.sent.pop();
  t.check("report: the lines go back to that browser, each saying whether it has a KPI rule",
          m && m.topic === "lines" && m._client.socketId === "browser-a" && m.payload.length === 2 && m.payload[1].hasRule === true && m.payload[0].hasRule === false);

  asked.length = 0;
  await rep.run({ payload: { cmd: "report", req: 4, line: 7, preset: "lastmonth" }, _client: A });
  m = rep.sent.pop();
  const r = m && m.payload;
  t.check("report: last month is worked out in the database in the site's time zone (not in the browser)",
          asked.some(q => /AS d0/.test(q.text) && q.params[1] === "lastmonth" && /AT TIME ZONE/.test(q.text)));
  t.check("report: one answer with the period, the line's target, totals, the previous period, days, losses, orders, products, shifts, machines",
          m && m.topic === "report" && r.req === 4 && r.period.days === 31 && r.group === "day" && r.line.target === 0.65 && r.line.tz === "Australia/Melbourne" &&
          r.total.oee === 0.778 && r.prev && r.series.length === 1 && r.losses[0].pts === 10 && r.orders[0].wo === "WO-31" &&
          r.products[0].name === "Assorted 250 g" && r.machines[0].constraint === true && r.prevMachines.length === 1);
  t.check("report: made-up operations in the period are passed on to the page (migration 032)", r.flags.testOperations === true && r.flags.testData === false);
  const tpl = flow.find(n => n.id === "ofm_sc_report_view").format;
  t.check("report page: a period without recorded operations gets one plain notice, and time without data its own chip",
          tpl.includes("No machine states, counts or orders were recorded") && tpl.includes("without data (state unknown") && tpl.includes("Made-up test operations in this period"));
  t.check("report: only the report functions are asked, all as ofm_screens (no table read)",
          asked.every(q => q.user === "ofm_screens") && asked.every(q => /hist\.fn_report_|config\.fn_screen_model/.test(q.text)) &&
          !asked.some(q => /\bFROM\s+(config|hist)\.(?!fn_)/i.test(q.text)));
  const kpiCalls = asked.filter(q => /fn_report_kpi/.test(q.text)).map(groupOf);
  t.check("report: totals of both periods, the days, products and shifts", ["total", "total", "day", "product", "shift"].every(g => kpiCalls.includes(g)));

  // no comparison: the previous period is not asked
  asked.length = 0;
  await rep.run({ payload: { cmd: "report", req: 5, line: 7, preset: "lastmonth", compare: false }, _client: A });
  m = rep.sent.pop();
  t.check("report: without comparison the previous period is not fetched", m.payload.prev === null && asked.filter(q => /fn_report_kpi/.test(q.text) && groupOf(q) === "total").length === 1);

  // periods over 42 days are drawn per week; over 93 days refused
  const rep2 = loadFunction(flow, "ofm_sc_report", { global: { pg: fakePg([], { period: PERIOD(60) }) }, env: {} });
  await rep2.run({ payload: { cmd: "report", req: 1, line: 7, preset: "custom", from: "2026-08-01", to: "2026-09-29" }, _client: A });
  t.check("report: a period over 42 days is drawn per week", rep2.sent.pop().payload.group === "week");
  const rep3 = loadFunction(flow, "ofm_sc_report", { global: { pg: fakePg([], { period: PERIOD(120) }) }, env: {} });
  await rep3.run({ payload: { cmd: "report", req: 2, line: 7, preset: "custom", from: "2026-06-01", to: "2026-09-28" }, _client: A });
  m = rep3.sent.pop();
  t.check("report: more than 93 days is refused with a reason", m.topic === "error" && m.payload.req === 2 && /93 days/.test(m.payload.text));
  await rep3.run({ payload: { cmd: "report", req: 3, line: 7, preset: "custom", from: "2026-06-01" }, _client: A });
  m = rep3.sent.pop();
  t.check("report: a custom period needs both dates", m.topic === "error" && /both dates/.test(m.payload.text));
  await rep3.run({ payload: { cmd: "report", req: 4, line: "x", preset: "lastmonth" }, _client: A });
  t.check("report: a line must be chosen", rep3.sent.pop().topic === "error");
  await rep3.run({ payload: { cmd: "report", req: 5, line: 7 } });
  t.check("report: a message without a browser gets no answer", rep3.sent.length === 0);
};

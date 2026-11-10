// Live stack: the Grafana dashboard "OFM · Line OEE" (step 3a.8b). Every
// panel query and both variables run as ofm_reader, with Grafana's macros
// filled in the way Grafana fills them, for the last 24 hours, a shift, the
// running order and an earlier order, so a
// query error shows here and not only as a red triangle in Grafana; and
// Grafana serves the dashboard from the repository.
"use strict";
const path = require("path");
const { ROOT, readJson, stack, connectDb } = require("../lib/harness");

module.exports.run = async function (t) {
  const dash = readJson(path.join(ROOT, "deploy", "grafana", "dashboards", "ofm-line-oee.json"));
  let db;
  try {
    db = await connectDb({ user: "ofm_reader", password: process.env.OFM_READER_DB_PASSWORD });
  } catch (e) {
    t.check("database reachable as ofm_reader", false, e.message);
    return;
  }
  try {
    const v = name => dash.templating.list.find(x => x.name === name);
    const lines = (await db.query(v("line").query)).rows;
    if (!lines.length) {
      t.skip("Line OEE dashboard queries", "no line has a KPI rule (config.line_kpi_rule)");
      return;
    }
    const line = String(lines[0].__value);
    const shifts = (await db.query(v("shift").query.replace(/\$\{line\}/g, line))).rows;
    t.check("Line OEE: the Line list offers the lines with a KPI rule; the Shift list starts with All",
            shifts.length >= 1 && shifts[0].__value === "all", lines.map(l => l.__text).join(", ") + "; " + shifts.length + " shift choice(s)");
    const q = d => "'" + d.toISOString() + "'";
    const now = new Date(), midnight = new Date(now.getTime() - 86400000);
    const failed = [];
    const orders = (await db.query(v("order").query.replace(/\$\{line\}/g, line))).rows;
    t.check("Line OEE: the Order list starts with Running order and None, then the line's recent orders",
            orders[0].__value === "current" && orders[1].__value === "none", orders.length - 2 + " recent order(s)");
    // the time picker, one shift, the running order, one earlier order
    const choices = [["all", "none"]].concat(shifts.length > 1 ? [[shifts[1].__value, "none"]] : [])
      .concat([["all", "current"]]).concat(orders.length > 2 ? [["all", orders[orders.length - 1].__value]] : []);
    let started = Date.now();
    for (const [shift, order] of choices) {
      for (const panel of dash.panels) {
        const sql = panel.targets[0].rawSql.replace(/\$\{line\}/g, line).replace(/\$\{shift\}/g, shift).replace(/\$\{order\}/g, order)
          .replace(/\$__timeFrom\(\)/g, q(midnight)).replace(/\$__timeTo\(\)/g, q(now));
        try { await db.query(sql); } catch (e) { failed.push(panel.title + " (" + shift + ", " + order + "): " + e.message); }
      }
    }
    const seconds = (Date.now() - started) / 1000;
    t.check("Line OEE: every panel query runs as ofm_reader (last 24 hours, a shift, the running order, an earlier order)", failed.length === 0,
            failed.slice(0, 3).join("\n             ") || dash.panels.length + " panels, " + seconds.toFixed(1) + " s");
    t.check("Line OEE: all panels of one period together in under 10 s on average", seconds / choices.length < 10, seconds.toFixed(1) + " s for " + choices.length);
  } finally {
    await db.end().catch(() => {});
  }

  const grafana = { user: process.env.GRAFANA_USER, password: process.env.GRAFANA_PASSWORD };
  try {
    const headers = { Authorization: "Basic " + Buffer.from(grafana.user + ":" + grafana.password).toString("base64") };
    const res = await fetch(stack.grafanaUrl + "/api/dashboards/uid/ofm-line-oee", { headers, signal: AbortSignal.timeout(5000) });
    const body = await res.json().catch(() => null);
    const queries = x => (x.panels || []).map(p => p.targets[0].rawSql).sort().join("\n");
    t.check("Grafana serves 'OFM · Line OEE' from the repository (provisioned, same queries)",
            res.status === 200 && body.meta.provisioned === true && queries(body.dashboard) === queries(dash),
            "HTTP " + res.status + (res.status === 200 ? " - an older copy? docker compose restart grafana" : ""));
  } catch (e) {
    t.check("Grafana serves 'OFM · Line OEE' from the repository", false, e.message);
  }
};

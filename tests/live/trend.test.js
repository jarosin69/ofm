// Live stack: OFM Trend (step H1, ADR-0029). The screens container serves
// the page, the chart library from its own image and the CSV export; the
// trend functions are quick enough for a chart of 8 signals over a year;
// made-up history (migrate test-history), if loaded, has its 1-minute and
// 1-hour averages.
"use strict";
const { stack, connectDb } = require("../lib/harness");

module.exports.run = async function (t) {
  const get = async (url, ms) => {
    const res = await fetch(stack.screensUrl + url, { signal: AbortSignal.timeout(ms || 10000) });
    return { status: res.status, type: res.headers.get("content-type") || "", disposition: res.headers.get("content-disposition") || "", body: await res.text() };
  };
  try {
    const lib = await get("/ofm/echarts.min.js");
    t.check("the chart library comes from the screens container itself (no internet)", lib.status === 200 && lib.body.length > 500000 && /javascript/.test(lib.type),
            "HTTP " + lib.status + ", " + lib.body.length + " bytes - an old image? docker compose up -d --build");
    const page = await get("/dashboard/trend");
    t.check("OFM Trend answers at /dashboard/trend", page.status === 200, "HTTP " + page.status);
  } catch (e) {
    t.check("the screens container answers (" + stack.screensUrl + ")", false, e.message);
    return;
  }

  let db;
  try {
    db = await connectDb({ user: "ofm_reader", password: process.env.OFM_READER_DB_PASSWORD });
  } catch (e) {
    t.check("database reachable as ofm_reader", false, e.message);
    return;
  }
  try {
    const tags = (await db.query("SELECT config.fn_trend_tags() AS t")).rows[0].t || [];
    t.check("the trend page offers the historised signals", tags.length > 0, tags.length + " signal(s)");
    if (!tags.length) return;
    const line = tags[0].lineId, pens = tags.filter(x => x.lineId === line).slice(0, 8);
    const now = Date.now(), year = new Date(now - 365 * 86400000).toISOString(), to = new Date(now).toISOString();
    let started = Date.now(), points = 0;
    for (const p of pens) {
      points += (await db.query("SELECT count(*) AS n FROM hist.fn_trend_data($1, $2, $3, 1500)", [p.id, year, to])).rows[0].n * 1;
      await db.query("SELECT * FROM hist.fn_trend_stats($1, $2, $3)", [p.id, year, to]);
    }
    const s = (Date.now() - started) / 1000;
    t.check("a chart of " + pens.length + " signals over a year, with statistics, in under 3 s", s < 3, s.toFixed(1) + " s, " + points + " points");
    started = Date.now();
    for (const p of pens) await db.query("SELECT count(*) FROM hist.fn_trend_data($1, $2, $3, 1500)", [p.id, new Date(now - 3600000).toISOString(), to]);
    t.check("the last hour of the same signals in under 1 s", (Date.now() - started) / 1000 < 1, ((Date.now() - started) / 1000).toFixed(2) + " s");

    const csv = await get("/trend/export?mode=raw&pens=" + pens.map(p => p.id).join(",") + "&from=" + (now - 3600000) + "&to=" + now, 60000);
    t.check("CSV export of the last hour: a file with a header line", csv.status === 200 && /text\/csv/.test(csv.type) && /attachment/.test(csv.disposition) &&
            csv.body.replace("﻿", "").startsWith("local_time,utc_ms,topic,name,value,unit,quality"),
            "HTTP " + csv.status + ", " + csv.body.split("\n").length + " lines");

    const test = (await db.query("SELECT min(from_ts) AS f, max(to_ts) AS t, count(DISTINCT property_id) AS n FROM hist.test_data_range")).rows[0];
    if (!Number(test.n)) {
      t.skip("made-up history has its averages", "none loaded (docker compose run --rm migrate test-history)");
    } else {
      const r = (await db.query("SELECT count(*) AS n FROM hist.measurement_1h h JOIN hist.test_data_range r ON r.property_id = h.property_id " +
                                "AND h.bucket >= r.from_ts AND h.bucket < r.to_ts")).rows[0];
      const hours = (new Date(test.t) - new Date(test.f)) / 3600000;
      t.check("made-up history (" + test.n + " signals) has its 1-hour averages", Number(r.n) >= Number(test.n) * hours * 0.95,
              r.n + " hours of averages for " + Math.round(hours) + " hours x " + test.n + " signals");
    }
  } finally {
    await db.end().catch(() => {});
  }
};

// Live stack: the automated part of the Phase 1 exit check (Overview §18):
// "one simulated line's values flowing OPC UA simulator -> UNS -> historian
// -> dashboard from model configuration only".
//
// Reads the model, listens to the UNS for a short while as the read-only
// user, then checks every model property end to end. The expected topics
// come from the model, not from this file: add a property in the model and
// it is checked too.
"use strict";
const path = require("path");
const { ROOT, fromNodeRed, readJson, stack, connectDb } = require("../lib/harness");
const contracts = require("../lib/contracts");

const STALE_FACTOR = 2;   // a value older than 2 x max_publish_interval_ms is stale (ADR-0007)

function listen(seconds) {
  const mqtt = fromNodeRed("mqtt");
  return new Promise((resolve, reject) => {
    const topics = new Map();              // topic -> { retained, live, last, raw }
    const client = mqtt.connect(stack.mqttUrl, {
      username: "ofm_reader",
      password: process.env.OFM_MQTT_READER_PASSWORD,
      protocolVersion: 5,
      clientId: "ofm-test-" + Math.random().toString(16).slice(2, 10),
      connectTimeout: 5000,
      reconnectPeriod: 0
    });
    let done = false;                      // once listening is over, late errors do not matter
    const finish = () => { if (done) return; done = true; client.end(true); resolve(topics); };
    client.on("error", e => { if (done) return; done = true; client.end(true); reject(e); });
    client.on("connect", () => {
      // QoS 0: the broker expects no acknowledgements, so stopping while
      // messages are still arriving cannot fail ("write after end").
      client.subscribe(["#"], { qos: 0 }, err => {
        if (err) { if (!done) { done = true; client.end(true); reject(err); } return; }
        setTimeout(finish, seconds * 1000);
      });
    });
    client.on("message", (topic, buf, packet) => {
      if (done) return;
      const e = topics.get(topic) || { retained: 0, live: 0, last: null, raw: null, invalid: [] };
      if (packet.retain) e.retained++; else e.live++;
      e.raw = buf.toString("utf8");
      e.receivedAt = Date.now();
      if (buf.length === 0) {
        e.last = null;                    // empty retained message = topic deleted
      } else {
        try { e.last = JSON.parse(e.raw); } catch (x) { e.last = undefined; }
        const schema = contracts.schemaNameForTopic(topic);
        if (schema) {
          const err = e.last === undefined ? "not JSON" : contracts.validate(schema, e.last);
          if (err) e.invalid.push(err + "  payload: " + e.raw.slice(0, 200));
        }
      }
      topics.set(topic, e);
    });
  });
}

async function http(url, auth) {
  const headers = auth ? { Authorization: "Basic " + Buffer.from(auth.user + ":" + auth.password).toString("base64") } : {};
  const res = await fetch(url, { headers, signal: AbortSignal.timeout(5000) });
  let body = null;
  try { body = await res.json(); } catch (e) { /* not JSON */ }
  return { status: res.status, body };
}

module.exports.run = async function (t) {
  const runtime = stack.runtimeName;

  // --- 1. the model ---------------------------------------------------------------------
  let db;
  try {
    db = await connectDb({ user: "ofm_reader", password: process.env.OFM_READER_DB_PASSWORD });
  } catch (e) {
    t.check("database reachable as ofm_reader", false, e.message + " - is the stack running? (docker compose up -d)");
    return;
  }
  try {
    const fullModel = (await db.query(
      "SELECT property_id, topic, datatype, unit, is_historised, max_publish_interval_ms, source_name " +
      "FROM config.vw_runtime_model WHERE runtime_name = $1 ORDER BY topic", [runtime])).rows;
    // The load-test line (step 2.9) has its own suite, "load"; checking its
    // thousands of properties one by one here would only bury the plant's.
    const model = fullModel.filter(r => !r.topic.startsWith("ofmload/"));
    if (fullModel.length > model.length) t.note((fullModel.length - model.length) + " load-test properties (ofmload/...) left to the 'load' suite");
    if (!t.check("the model gives runtime " + runtime + " properties to acquire", model.length > 0,
                 "none - load the example plant: docker compose run --rm migrate example")) return;
    const sources = [...new Set(model.map(r => r.source_name))];
    t.note(model.length + " properties from " + sources.length + " source(s): " + sources.join(", "));

    // --- 2. the UNS -------------------------------------------------------------------------
    t.note("listening to the UNS for " + stack.listenSeconds + " s as ofm_reader ...");
    let topics;
    try {
      topics = await listen(stack.listenSeconds);
    } catch (e) {
      t.check("broker reachable as ofm_reader", false, e.message);
      return;
    }
    const now = Date.now();
    const payload = topic => (topics.get(topic) || {}).last;

    const rt = payload("ofm/_system/runtime/" + runtime);
    t.check("runtime " + runtime + " reports online", rt && rt.state === "online", JSON.stringify(rt));
    for (const s of sources) {
      const st = payload("ofm/_system/sources/" + s);
      t.check("source " + s + " reports online", st && st.state === "online", JSON.stringify(st));
    }
    const hist = payload("ofm/_system/historian/" + runtime);
    t.check("historian writer is writing, nothing queued or dropped (step 2.4)",
            hist && hist.state === "writing" && hist.queueDepth === 0 && hist.droppedRows === 0, JSON.stringify(hist));
    const cache = payload("ofm/_system/cache/" + runtime);
    t.check("runtime loaded the whole model (" + fullModel.length + " rows)",
            cache && cache.rows === fullModel.length,
            cache ? "cache status says " + cache.rows + " rows - is the runtime's 'model change listener' node green?" : "no cache status");
    t.check("runtime runs on the database's model, not on its saved copy (step 2.6)",
            cache && cache.trigger !== "disk",
            cache && cache.trigger === "disk"
              ? "it started from the copy saved " + new Date(cache.savedAt).toISOString() +
                " and has not reached the database since - see docker compose logs nodered"
              : "no cache status");

    for (const p of model) {
      const v = payload(p.topic);
      const e = topics.get(p.topic);
      const limit = STALE_FACTOR * p.max_publish_interval_ms;
      let err = null;
      if (!v) err = "no value on the UNS - wrong address? See the runtime's warnings: docker compose logs nodered";
      else if (now - v.ts > limit) err = "last value is " + Math.round((now - v.ts) / 1000) + " s old (limit " + limit / 1000 + " s)";
      else if (v.q === "bad") err = v.v === null
        ? "v null, q bad - address refused by the PLC? See the runtime's warnings: docker compose logs nodered"
        : "quality bad - source offline?";
      const info = v ? " (q=" + v.q + ", " + e.live + " update(s) in " + stack.listenSeconds + " s)" : "";
      t.check(p.topic + ": current value on the UNS" + (err ? "" : info), !err, err);
      const m = payload(p.topic + "/_meta");
      t.check(p.topic + "/_meta: describes the property (step 2.2)",
              m && m.propertyId === p.property_id && m.datatype === p.datatype && (m.unit || null) === (p.unit || null),
              m ? "found " + JSON.stringify(m) : "no _meta on the UNS");
    }

    let checked = 0, unknown = 0;
    const invalid = [];
    for (const [topic, e] of topics) {
      if (!contracts.schemaNameForTopic(topic)) { unknown++; continue; }
      checked += e.retained + e.live;
      for (const i of e.invalid) invalid.push(topic + ": " + i);
    }
    t.check(checked + " UNS messages match their schemas", invalid.length === 0 && checked > 0,
            invalid.slice(0, 5).join("\n             "));
    if (unknown) t.note(unknown + " topic(s) without a schema yet (not checked)");
    const unmapped = [...topics.keys()].filter(k => k.startsWith("ofm/_unmapped/"));
    if (unmapped.length) t.note(unmapped.length + " unmapped address(es) in quarantine, e.g. " + unmapped[0]);

    // --- 3. the historian -------------------------------------------------------------------
    const historised = model.filter(p => p.is_historised);
    const latest = new Map();
    for (const table of ["hist.measurement", "hist.measurement_text"]) {
      const rows = (await db.query(
        "SELECT property_id, max(ts) AS ts FROM " + table +
        " WHERE property_id = ANY($1) AND ts > now() - interval '1 hour' GROUP BY 1",
        [historised.map(p => p.property_id)])).rows;
      for (const r of rows) latest.set(r.property_id, r.ts.getTime());
    }
    for (const p of historised) {
      const ts = latest.get(p.property_id);
      const limit = STALE_FACTOR * p.max_publish_interval_ms;
      t.check(p.topic + ": recent rows in the historian", ts !== undefined && now - ts <= limit,
              ts === undefined ? "no rows in the last hour" : "newest row is " + Math.round((now - ts) / 1000) + " s old");
    }
    const future = (await db.query(
      "SELECT count(*)::int AS n FROM hist.measurement WHERE ts > now() + interval '5 minutes'")).rows[0].n;
    t.check("no historian rows timestamped in the future (ADR-0003)", future === 0, future + " row(s)");

    // --- 4. the dashboard ---------------------------------------------------------------------
    const dash = readJson(path.join(ROOT, "deploy", "grafana", "dashboards", "ofm-live-data.json"));
    // The dashboard shows one line, and charts for one machine, at a time
    // (step 2.9): Line, then Machine, then Property must together offer every
    // acquired property.
    const lineOf = topic => topic.split("/").slice(0, 4).join("/");
    const machineOf = topic => topic.split("/")[4];
    const lit = v => v.replace(/'/g, "''");
    const withLine = (sql, line, machine) => sql.replace(/\$\{line\}|\$line\b/g, lit(line))
                                                 .replace(/\$\{machine\}|\$machine\b/g, lit(machine || ""));
    const lineVar = dash.templating.list.find(v => v.name === "line");
    const lines = (await db.query(lineVar.query)).rows.map(r => r.__value);
    t.check("dashboard Line list (from the model) offers every line with acquired properties",
            model.every(p => lines.includes(lineOf(p.topic))), lines.join(", "));
    const machineVar = dash.templating.list.find(v => v.name === "machine");
    const variable = dash.templating.list.find(v => v.name === "property");
    let choices = [], machinesOk = true;
    for (const line of lines) {
      const machines = (await db.query(withLine(machineVar.query, line))).rows.map(r => r.__value);
      machinesOk = machinesOk && model.filter(p => lineOf(p.topic) === line).every(p => machines.includes(machineOf(p.topic)));
      for (const machine of machines) choices = choices.concat((await db.query(withLine(variable.query, line, machine))).rows);
    }
    t.check("dashboard Machine list, line by line, offers every machine with acquired properties", machinesOk);
    t.check("dashboard Property list, machine by machine, offers every acquired property",
            model.every(p => choices.some(c => Number(c.__value) === p.property_id)),
            choices.length + " choices");

    // Every panel query of the dashboard, with Grafana's macros filled in the
    // way Grafana fills them (quoted UTC times), at raw, 1-minute and 1-hour
    // resolution, run as ofm_reader - so a query error shows here, not only
    // as a red triangle in Grafana.
    const to = new Date(), from = new Date(to.getTime() - 7 * 86400000);
    const q = d => "'" + d.toISOString() + "'";
    const expand = (sql, ms) => sql
      .replace(/\$__timeGroupAlias\(([^,]+),\s*\$__interval\)/g, (_, c) => "time_bucket(make_interval(secs => " + ms / 1000 + "), " + c + ") AS \"time\"")
      .replace(/\$__timeFilter\(([^)]+)\)/g, (_, c) => c + " BETWEEN " + q(from) + " AND " + q(to))
      .replace(/\$__timeFrom\(\)/g, q(from)).replace(/\$__timeTo\(\)/g, q(to))
      .replace(/\$__interval_ms/g, String(ms))
      .replace(/\$property/g, String(model[0].property_id))
      .replace(/\$\{line\}|\$line\b/g, lineOf(model[0].topic))
      .replace(/\$\{machine\}|\$machine\b/g, machineOf(model[0].topic));
    const failed = [];
    for (const panel of dash.panels || []) {
      for (const target of panel.targets || []) {
        if (!target.rawSql) continue;
        for (const ms of [1000, 600000, 7200000]) {
          try { await db.query(expand(target.rawSql, ms)); }
          catch (e) { failed.push((panel.title || "panel") + " @ " + ms / 1000 + " s per point: " + e.message); }
        }
      }
    }
    t.check("every dashboard query runs as ofm_reader (raw, 1-minute and 1-hour resolution)", failed.length === 0,
            failed.slice(0, 3).join("\n             "));

    const grafana = { user: process.env.GRAFANA_USER, password: process.env.GRAFANA_PASSWORD };
    try {
      const h = await http(stack.grafanaUrl + "/api/health");
      t.check("Grafana is up", h.status === 200 && h.body && h.body.database === "ok", "HTTP " + h.status);
      const d = await http(stack.grafanaUrl + "/api/dashboards/uid/ofm-live-data", grafana);
      t.check("Grafana serves 'OFM · Live data', provisioned from the repository",
              d.status === 200 && d.body.meta && d.body.meta.provisioned === true, "HTTP " + d.status);
      const queries = x => (x.panels || []).flatMap(p => (p.targets || []).map(q => q.rawSql || "")).sort().join("\n");
      t.check("the dashboard Grafana serves is the one in the repository (same queries)",
              d.status === 200 && queries(d.body.dashboard) === queries(dash),
              "Grafana has an older version - restart it: docker compose restart grafana");
      // Grafana reads its home page (GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH)
      // only when it starts, so after a dashboard change the home page can be
      // an old copy even while the provisioned dashboard is current (step 2.9).
      // Grafana 13 answers with a forward to the home dashboard's own address
      // (e.g. /d/default-home-dashboard/home); older versions with the dashboard.
      const home = await http(stack.grafanaUrl + "/api/dashboards/home", grafana);
      let homeDash = home.body && home.body.dashboard, homeWhere = "the home page";
      const fwd = home.body && home.body.redirectUri;
      if (!homeDash && fwd) {
        const uid = (/\/d\/([^/?]+)/.exec(fwd) || [])[1];
        homeWhere = "the home page (" + fwd + ")";
        if (uid) {
          const target = await http(stack.grafanaUrl + "/api/dashboards/uid/" + encodeURIComponent(uid), grafana);
          if (target.status === 200 && target.body) homeDash = target.body.dashboard;
        }
      }
      if (homeDash) {
        t.check("Grafana's home page is the repository's dashboard too (same queries)", queries(homeDash) === queries(dash),
                homeWhere + " is an older copy - restart Grafana: docker compose restart grafana");
      } else {
        t.skip("Grafana's home page is the repository's dashboard too",
               "Grafana answered " + home.status + " " + JSON.stringify(home.body).slice(0, 120) + " - check it in the browser: the Line selector must be there");
      }
      const ds = await http(stack.grafanaUrl + "/api/datasources/uid/ofm-historian/health", grafana);
      t.check("Grafana reaches the historian as ofm_reader", ds.status === 200 && ds.body && ds.body.status === "OK",
              "HTTP " + ds.status + " " + JSON.stringify(ds.body));
    } catch (e) {
      t.check("Grafana reachable", false, e.message);
    }

    // --- 5. the editors ------------------------------------------------------------------------
    for (const [name, url] of [["Node-RED editor", stack.noderedUrl + "/"], ["Mathesar", stack.mathesarUrl + "/"]]) {
      try {
        const r = await http(url);
        t.check(name + " responds", r.status < 400, "HTTP " + r.status);
      } catch (e) {
        t.check(name + " responds", false, e.message);
      }
    }
  } finally {
    await db.end();
  }
};

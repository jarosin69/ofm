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
    client.on("error", e => { client.end(true); reject(e); });
    client.on("connect", () => {
      client.subscribe(["#"], { qos: 1 }, err => {
        if (err) { client.end(true); reject(err); return; }
        setTimeout(() => client.end(false, () => resolve(topics)), seconds * 1000);
      });
    });
    client.on("message", (topic, buf, packet) => {
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
    const model = (await db.query(
      "SELECT property_id, topic, datatype, is_historised, max_publish_interval_ms, source_name " +
      "FROM config.vw_runtime_model WHERE runtime_name = $1 ORDER BY topic", [runtime])).rows;
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
    const cache = payload("ofm/_system/cache/" + runtime);
    t.check("runtime loaded the whole model (" + model.length + " rows)",
            cache && cache.rows === model.length,
            cache ? "cache status says " + cache.rows + " rows - restart Node-RED after a model change (Phase 1)" : "no cache status");

    for (const p of model) {
      const v = payload(p.topic);
      const e = topics.get(p.topic);
      const limit = STALE_FACTOR * p.max_publish_interval_ms;
      let err = null;
      if (!v) err = "no value on the UNS";
      else if (now - v.ts > limit) err = "last value is " + Math.round((now - v.ts) / 1000) + " s old (limit " + limit / 1000 + " s)";
      else if (v.q === "bad") err = "quality bad";
      const info = v ? " (q=" + v.q + ", " + e.live + " update(s) in " + stack.listenSeconds + " s)" : "";
      t.check(p.topic + ": current value on the UNS" + (err ? "" : info), !err, err);
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
    const variable = dash.templating.list.find(v => v.name === "property");
    const choices = (await db.query(variable.query)).rows;
    t.check("dashboard property list (from the model) offers every acquired property",
            model.every(p => choices.some(c => Number(c.__value) === p.property_id)),
            choices.length + " choices");

    const grafana = { user: process.env.GRAFANA_USER, password: process.env.GRAFANA_PASSWORD };
    try {
      const h = await http(stack.grafanaUrl + "/api/health");
      t.check("Grafana is up", h.status === 200 && h.body && h.body.database === "ok", "HTTP " + h.status);
      const d = await http(stack.grafanaUrl + "/api/dashboards/uid/ofm-live-data", grafana);
      t.check("Grafana serves 'OFM · Live data', provisioned from the repository",
              d.status === 200 && d.body.meta && d.body.meta.provisioned === true, "HTTP " + d.status);
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

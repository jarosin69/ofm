// Load meter (step 2.9): records the load-test line (db/examples/loadtest.sql)
// for a while, as a consumer would, and compares the UNS with the historian.
// Used by tests/load (performance acceptance) and tests/watch (failure drills).
//
// - UNS: every live value of the line, as ofm_reader: arrivals per second,
//   delay from the device timestamp to arrival, quality, silent properties.
// - Historian: rows of the line, counted per second of their timestamp, and
//   compared with the values seen on the UNS for the same second.
// - Platform topics: runtime, source, cache and historian writer status,
//   recorded as events with their time.
// Survives the broker or the database going away (drills): it reconnects
// and marks those periods in the timeline.
"use strict";
const { fromNodeRed, stack, connectDb } = require("./harness");

const pad = n => String(n).padStart(2, "0");
// Times for people: Melbourne time where the image knows time zones, else UTC.
function clock(ms) {
  try {
    return new Intl.DateTimeFormat("en-AU", { timeZone: "Australia/Melbourne", hour: "2-digit", minute: "2-digit",
                                               second: "2-digit", hour12: false }).format(new Date(ms));
  } catch (e) {
    const d = new Date(ms);
    return pad(d.getUTCHours()) + ":" + pad(d.getUTCMinutes()) + ":" + pad(d.getUTCSeconds()) + " UTC";
  }
}

async function loadModel() {
  const db = await connectDb({ user: "ofm_reader", password: process.env.OFM_READER_DB_PASSWORD });
  try {
    return (await db.query(
      "SELECT property_id, topic FROM config.vw_runtime_model " +
      "WHERE runtime_name = $1 AND topic LIKE 'ofmload/%' AND cache_key IS NOT NULL ORDER BY property_id",
      [stack.runtimeName])).rows;
  } finally {
    await db.end();
  }
}

// Historian rows of the given properties per second of their timestamp, [from, to) in ms.
async function historianPerSecond(ids, from, to) {
  const db = await connectDb({ user: "ofm_reader", password: process.env.OFM_READER_DB_PASSWORD });
  try {
    const rows = (await db.query(
      "SELECT floor(extract(epoch FROM ts))::bigint AS s, count(*)::int AS n FROM hist.measurement " +
      "WHERE property_id = ANY($1) AND ts >= to_timestamp($2 / 1000.0) AND ts < to_timestamp($3 / 1000.0) GROUP BY 1",
      [ids, from, to])).rows;
    const out = new Map();
    for (const r of rows) out.set(Number(r.s), r.n);
    return out;
  } finally {
    await db.end();
  }
}

// Records for `seconds`, printing a line every 10 s via note(). Returns the measurements.
async function record({ seconds, note, model }) {
  const mqtt = fromNodeRed("mqtt");
  const ids = model.map(p => p.property_id);
  const n = model.length;
  const runtime = stack.runtimeName;
  const topics = new Set(model.map(p => p.topic));
  const lastSeen = new Map();                // topic -> arrival ms
  const arrivals = new Map();                // arrival second -> values
  const byTs = new Map();                    // device-time second -> values
  const delays = new Uint32Array(601);       // 100 ms buckets up to 60 s (last = more)
  let values = 0, notGood = 0, stalls = 0;
  const events = [];
  const event = text => { events.push({ t: Date.now(), text }); note(clock(Date.now()) + "  " + text); };
  const state = {};
  const writer = { maxQueue: 0, maxDropped: 0, states: new Set() };

  const client = mqtt.connect(stack.mqttUrl, {
    username: "ofm_reader", password: process.env.OFM_MQTT_READER_PASSWORD, protocolVersion: 5,
    clientId: "ofm-loadmeter-" + Math.random().toString(16).slice(2, 10), reconnectPeriod: 1000, connectTimeout: 5000
  });
  let connected = false;
  client.on("connect", () => {
    if (state.brokerLost) { event("UNS: connected again"); state.brokerLost = false; }
    connected = true;
    client.subscribe(["ofmload/#", "ofm/_system/#"], { qos: 0 });
  });
  client.on("close", () => {
    if (connected && !state.done) { event("UNS: connection lost (broker down?)"); state.brokerLost = true; }
    connected = false;
  });
  client.on("error", () => { /* reconnects by itself */ });
  client.on("message", (topic, buf, packet) => {
    const now = Date.now();
    if (topics.has(topic)) {
      if (packet.retain || buf.length === 0) return;    // retained = old value, not a new arrival
      let v;
      try { v = JSON.parse(buf); } catch (e) { return; }
      values++;
      const sec = Math.floor(now / 1000);
      arrivals.set(sec, (arrivals.get(sec) || 0) + 1);
      const ts = Math.floor(v.ts / 1000);
      byTs.set(ts, (byTs.get(ts) || 0) + 1);
      delays[Math.min(600, Math.max(0, Math.floor((now - v.ts) / 100)))]++;
      if (v.q !== "good") notGood++;
      const prev = lastSeen.get(topic);
      if (prev !== undefined && now - prev > 5000) stalls++;
      lastSeen.set(topic, now);
      return;
    }
    if (!topic.startsWith("ofm/_system/") || buf.length === 0) return;
    let p;
    try { p = JSON.parse(buf); } catch (e) { return; }
    const watch = (key, text) => {
      if (state[key] !== text) { if (state[key] !== undefined || !packet.retain) event(text); state[key] = text; }
    };
    if (topic === "ofm/_system/runtime/" + runtime) watch("runtime", "runtime " + p.state);
    else if (topic === "ofm/_system/sources/opcplc_load") watch("source", "load source " + p.state + (p.error ? " (" + p.error + ")" : ""));
    else if (topic === "ofm/_system/cache/" + runtime) watch("cache", "model loaded: " + p.rows + " rows, trigger " + p.trigger);
    else if (topic === "ofm/_system/historian/" + runtime) {
      writer.states.add(p.state);
      writer.maxQueue = Math.max(writer.maxQueue, p.queueDepth || 0);
      writer.maxDropped = Math.max(writer.maxDropped, p.droppedRows || 0);
      writer.last = p;
      watch("writer", "historian writer " + p.state + (p.state === "buffering" ? " (" + p.queueDepth + " rows queued)" : ""));
    }
  });

  const start = Date.now();
  note("recording " + n + " values/s for " + seconds + " s, from " + clock(start) + " ...");
  let lastTick = start;
  while (Date.now() - start < seconds * 1000) {
    await new Promise(r => setTimeout(r, 10000 - ((Date.now() - start) % 10000)));
    const now = Date.now();
    const s0 = Math.floor(lastTick / 1000), s1 = Math.floor(now / 1000);
    let got = 0;
    for (let s = s0; s < s1; s++) got += arrivals.get(s) || 0;
    const rate = got / Math.max(1, s1 - s0);
    let hist = "historian unreachable";
    try {
      const h = await historianPerSecond(ids, now - 15000, now - 5000);
      let rows = 0;
      for (const v of h.values()) rows += v;
      hist = "historian " + Math.round(rows / 10) + " rows/s";
    } catch (e) { /* database down during a drill */ }
    const w = writer.last ? ", writer " + writer.last.state + (writer.last.queueDepth ? " queue " + writer.last.queueDepth : "") : "";
    note(clock(now) + "  UNS " + Math.round(rate) + " values/s (" + Math.round(100 * rate / n) + "%), " + hist + w);
    lastTick = now;
  }
  state.done = true;
  const end = Date.now();
  client.end(true);
  return { n, ids, start, end, arrivals, byTs, delays, values, notGood, stalls, events, writer };
}

// After recording: waits until the historian has caught up (database
// reachable, writer not buffering), then compares UNS and historian per second.
async function compare(m, { warmup = 0, note }) {
  const from = m.start + warmup * 1000, to = m.end - 3000;
  let hist = null;
  for (let i = 0; i < 24 && !hist; i++) {
    try {
      if (m.writer.last && m.writer.last.state === "buffering") throw new Error("writer still buffering");
      await new Promise(r => setTimeout(r, i ? 5000 : 3000));
      hist = await historianPerSecond(m.ids, from, to);
    } catch (e) {
      if (i === 0) note("waiting for the historian to catch up (" + e.message + ") ...");
      hist = null;
    }
  }
  if (!hist) return null;
  let uns = 0, rows = 0, lost = 0;
  const unsGaps = [], histGaps = [];
  const first = Math.ceil(from / 1000), last = Math.floor(to / 1000);
  // Gaps are judged by device time, on a 3-second average: a source changing
  // once a second drifts across second boundaries, leaving one second empty and
  // the next doubled - that is not a gap. Real outages last longer.
  const avg3 = (map, s) => ((map.get(s - 1) || 0) + (map.get(s) || 0) + (map.get(s + 1) || 0)) / 3;
  for (let s = first; s < last; s++) {
    const u = m.byTs.get(s) || 0, h = hist.get(s) || 0;
    uns += u; rows += h; lost += Math.max(0, u - h);
    if (s > first && s < last - 1) {
      if (avg3(m.byTs, s) < m.n / 2) unsGaps.push(s);
      if (avg3(hist, s) < m.n / 2) histGaps.push(s);
    }
  }
  const runs = list => {
    const out = [];
    for (const s of list) {
      const last = out[out.length - 1];
      if (last && s === last[1] + 1) last[1] = s; else out.push([s, s]);
    }
    return out.map(([a, b]) => clock(a * 1000) + (b > a ? "–" + clock(b * 1000) : "") + " (" + (b - a + 1) + " s)");
  };
  return { seconds: Math.floor(to / 1000) - Math.ceil(from / 1000), uns, rows, lost,
           unsGaps: runs(unsGaps), histGaps: runs(histGaps) };
}

// Percentile of the arrival delay, in seconds, from the 100 ms buckets.
function delayPercentile(delays, p) {
  const total = delays.reduce((a, b) => a + b, 0);
  if (!total) return null;
  let seen = 0;
  for (let i = 0; i < delays.length; i++) {
    seen += delays[i];
    if (seen >= p * total) return (i + 1) / 10;
  }
  return 60;
}

module.exports = { loadModel, record, compare, delayPercentile, clock };

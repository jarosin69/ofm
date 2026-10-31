// Unit tests for "heartbeat and source loss" (ADR-0007, step 2.3): unchanged
// values are republished at their max interval with gateway time; a lost
// source marks all its values bad at once (UNS and historian), keeps them bad
// while it is offline, and stops doing so when it is back.
"use strict";
const { loadFlow, loadFunction } = require("../lib/functions");
const contracts = require("../lib/contracts");

module.exports.run = async function (t) {
  const now = Date.now();
  const P = (id, name, source, datatype, extra) => Object.assign(
    { propertyId: id, topic: "a/b/c/d/m/" + name, datatype, historised: true, maxIntervalMs: 60000, source }, extra || {});
  const model = { byProperty: {
    1: P(1, "temp", "plc1", "float"),
    2: P(2, "run", "plc1", "bool"),
    3: P(3, "never_seen", "plc1", "float"),
    4: P(4, "speed", "plc2", "float", { maxIntervalMs: 5000 }),
    5: P(5, "manual", null, "float")
  } };
  const values = {
    1: { latest: { v: 21.5, q: "good", ts: now - 1000, tss: "device" }, sent: { v: 21.5, q: "good", at: now - 1000 } },
    2: { latest: { v: true, q: "good", ts: now - 1000, tss: "device" }, sent: { v: true, q: "good", at: now - 61000 } },
    4: { latest: { v: 7, q: "uncertain", ts: now - 9000, tss: "gateway" }, sent: { v: 7, q: "uncertain", at: now - 9000 } }
  };
  const fn = loadFunction(loadFlow(), "ofm_rt_hb", { global: { ofm_model: model, ofm_values: values } });
  const topicsOf = out => (out[0] || []).map(m => m.topic.split("/").pop());
  const valid = out => (out[0] || []).every(m => !contracts.validate("value", m.payload));

  let out = await fn.run({ topic: "tick" });
  t.check("tick: only values not published within their interval are republished",
    topicsOf(out).sort().join() === "run,speed", JSON.stringify(topicsOf(out)));
  const run = out[0].find(m => m.topic.endsWith("/run"));
  t.check("tick: republished with its latest value and quality, current time, tss gateway",
    run.payload.v === true && run.payload.q === "good" && run.payload.tss === "gateway" && run.payload.ts >= now && run.retain);
  t.check("tick: republished values go to the historian too (bool as 1)",
    out[1] && out[1].length === 2 && out[1].some(r => r.params[1] === 2 && r.params[2] === 1 && r.params[4] === 1));
  t.check("tick: payloads match value.schema.json", valid(out));
  out = await fn.run({ topic: "tick" });
  t.check("tick: nothing due straight after a republish", out[0] === null);

  out = await fn.run({ payload: { source: "plc1", online: false, error: "connection lost" } });
  const bad = out[0] || [];
  t.check("source lost: every property of that source republished at once, no others",
    topicsOf(out).sort().join() === "never_seen,run,temp", JSON.stringify(topicsOf(out)));
  t.check("source lost: last value kept, q bad, detection time, gateway",
    bad.every(m => m.payload.q === "bad" && m.payload.tss === "gateway") &&
    bad.find(m => m.topic.endsWith("/temp")).payload.v === 21.5);
  t.check("source lost: a property never read gets v null, stored as NULL with quality bad",
    bad.find(m => m.topic.endsWith("/never_seen")).payload.v === null &&
    (out[1] || []).some(r => r.params[1] === 3 && r.params[2] === null));
  t.check("source lost: bad rows go to the historian (quality 2)",
    (out[1] || []).length === 3 && out[1].every(r => r.params[3] === 2));
  t.check("source lost: payloads match value.schema.json", valid(out));
  out = await fn.run({ payload: { source: "plc1", online: false, error: "still lost" } });
  t.check("source lost: a repeated offline report is not marked again", out === null || out[0] === null);

  values[1].sent.at -= 61000;
  out = await fn.run({ topic: "tick" });
  t.check("while offline, the heartbeat repeats bad", out[0] && out[0].some(m => m.topic.endsWith("/temp") && m.payload.q === "bad"));

  await fn.run({ payload: { source: "plc1", online: true } });
  values[1].sent.at -= 61000;
  out = await fn.run({ topic: "tick" });
  const temp = (out[0] || []).find(m => m.topic.endsWith("/temp"));
  t.check("back online: the heartbeat republishes the latest value with its own quality",
    temp && temp.payload.q === "good" && temp.payload.v === 21.5);
  t.check("properties without a source are never touched", !topicsOf(out).includes("manual"));
};

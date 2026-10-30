// Unit tests for "start-up clean-up" (step 2.2, ADR-0004), run against a
// stand-in database and broker: only retained OFM value and _meta topics
// that no property has any more are cleared; everything else is left alone.
// Takes about 3 seconds (the clean-up listens for 3 s).
"use strict";
const { EventEmitter } = require("events");
const { loadFlow, loadFunction } = require("../lib/functions");

const E = "acme/melbourne/chocolate/eggline01";
const value = JSON.stringify({ v: 1, ts: 1793000000000, q: "good", tss: "device" });
const meta = JSON.stringify({ propertyId: 9, datatype: "float", unit: "degC", displayName: "Old", maxPublishIntervalMs: 60000 });

// Retained messages on the stand-in broker: [topic, payload, retained, expected to be cleared]
const BROKER = [
  [E + "/depositor01/chocolate_temp", value, true, false],            // in the model
  [E + "/depositor01/chocolate_temp/_meta", meta, true, false],       // in the model
  [E + "/depositor01/old_temp", value, true, true],                   // renamed while the runtime was stopped
  [E + "/depositor01/old_temp/_meta", meta, true, true],
  [E + "/depositor01/head1/old_speed", value, true, true],            // sub-asset property (7 levels)
  [E + "/kpi/oee", value, true, false],                               // reserved line-level topic
  [E + "/depositor01/state", value, true, false],                     // machine state topic
  [E + "/depositor01/other_app", '{"temperature": 3}', true, false],  // not an OFM payload
  [E + "/depositor01/live_only", value, false, false],                // not retained
  [E + "/depositor01", value, true, false],                           // too short for a property
  ["ofm/_system/cache/x", value, true, false]                         // not under an enterprise
];

function fakes() {
  const published = [];
  class Client {
    async connect() {}
    async query(sql) {
      if (/vw_runtime_model/.test(sql)) return { rows: [{ topic: E + "/depositor01/chocolate_temp" }] };
      if (/config\.enterprise/.test(sql)) return { rows: [{ name: "acme" }] };
      throw new Error("unexpected query " + sql);
    }
    async end() {}
  }
  const mqtt = {
    connect: () => {
      const c = new EventEmitter();
      c.subscribe = (filters, opts, cb) => {
        cb(null);
        for (const [topic, payload, retain] of BROKER) {
          if (filters.some(f => topic.startsWith(f.replace(/#$/, "")))) {
            c.emit("message", topic, Buffer.from(payload), { retain });
          }
        }
      };
      c.publish = (topic, payload, opts, cb) => { published.push({ topic, payload, opts }); cb(); };
      c.end = () => {};
      setTimeout(() => c.emit("connect"), 10);
      return c;
    }
  };
  return { published, global: { pg: { Client }, mqtt } };
}

module.exports.run = async function (t) {
  const { published, global } = fakes();
  const fn = loadFunction(loadFlow(), "ofm_rt_cleanup", {
    global, env: { OFM_RUNTIME_NAME: "ofm_runtime_01", OFM_RUNTIME_DB_USER: "ofm_runtime" }
  });
  await fn.run({ payload: "clean-up" });

  const cleared = published.filter(p => p.payload === "" && p.opts.retain).map(p => p.topic);
  for (const [topic, , , expected] of BROKER) {
    const short = topic.replace(E + "/", "");
    t.check((expected ? "cleared: " : "kept:    ") + short, cleared.includes(topic) === expected);
  }
  t.check("nothing but empty retained messages is published", published.every(p => p.payload === "" && p.opts.retain));
};

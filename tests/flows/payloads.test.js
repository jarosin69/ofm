// Every MQTT payload the runtime flow can produce matches its schema in
// schemas/ (the contract), and the model cache is built correctly from rows
// of config.vw_runtime_model. Runs the function code from the flow file
// itself, so it needs no broker, database or PLC.
"use strict";
const { loadFlow, loadFunction } = require("../lib/functions");
const contracts = require("../lib/contracts");

const RUNTIME = "ofm_runtime_01";
const env = { OFM_RUNTIME_NAME: RUNTIME, OFM_MQTT_RUNTIME_PASSWORD: "not-a-real-password" };

// Rows as config.vw_runtime_model returns them (only the columns the flow reads).
const NSU = "nsu=http://microsoft.com/Opc/OpcPlc/;s=";
const rows = [
  { property_id: 1, topic: "acme/melbourne/chocolate/eggline01/depositor01/chocolate_temp", datatype: "float", unit: "degC",
    low: 20, high: 40, is_historised: true, scale_factor: "0.02", scale_offset: "30.5",
    source_name: "opcplc", protocol: "opcua", endpoint: "opc.tcp://opcplc:50000", source_settings: { securityMode: "None" },
    address: NSU + "SpikeData", cache_key: "opcplc|" + NSU + "SpikeData" },
  { property_id: 3, topic: "acme/melbourne/chocolate/eggline01/depositor01/running", datatype: "bool", unit: null,
    low: null, high: null, is_historised: true, scale_factor: "1", scale_offset: "0",
    source_name: "opcplc", protocol: "opcua", endpoint: "opc.tcp://opcplc:50000", source_settings: { securityMode: "None" },
    address: NSU + "AlternatingBoolean", cache_key: "opcplc|" + NSU + "AlternatingBoolean" },
  { property_id: 6, topic: "acme/melbourne/chocolate/eggline01/depositor01/recipe", datatype: "string", unit: null,
    low: null, high: null, is_historised: true, scale_factor: null, scale_offset: null,
    source_name: null, protocol: null, endpoint: null, source_settings: null, address: null, cache_key: null }
];

module.exports.run = async function (t) {
  const flow = loadFlow();
  const global = {};
  const produced = [];                        // every { topic, payload } the flow would publish

  // --- start-up: broker connection with Last Will ----------------------------
  const connect = loadFunction(flow, "ofm_rt_mqconn", { env, global });
  const cm = await connect.run({});
  const will = cm.broker.will;
  t.check("Last Will is retained, QoS 1, on the runtime status topic",
    will.retain === true && will.qos === 1 && will.topic === "ofm/_system/runtime/" + RUNTIME, JSON.stringify(will));
  t.check("broker password comes from the environment, not the flow",
    cm.broker.password === env.OFM_MQTT_RUNTIME_PASSWORD && !JSON.stringify(flow).includes(env.OFM_MQTT_RUNTIME_PASSWORD));
  produced.push({ topic: will.topic, payload: JSON.parse(will.payload), what: "Last Will (runtime offline)" });

  const online = loadFunction(flow, "ofm_rt_online", { env, global });
  const om = await online.run({ status: { fill: "green", shape: "dot", text: "connected" } });
  produced.push({ topic: om.topic, payload: om.payload, what: "runtime online" });
  t.check("runtime online is announced once per connection",
    (await online.run({ status: { fill: "green" } })) === null);

  // --- model cache --------------------------------------------------------------
  const cache = loadFunction(flow, "ofm_rt_cache", { env, global });
  const [status, sourceMsg] = await cache.run({ payload: rows });
  produced.push({ topic: status.topic, payload: status.payload, what: "cache status after start-up" });
  const model = global.ofm_model;
  t.check("cache: every property by ID and topic, only mapped ones by source address",
    Object.keys(model.byProperty).length === 3 && Object.keys(model.byTopic).length === 3 &&
    Object.keys(model.byKey).length === 2 && model.byKey["opcplc|" + NSU + "SpikeData"].factor === 0.02,
    JSON.stringify(Object.keys(model.byKey)));
  t.check("cache: one acquisition job per source, with its addresses",
    sourceMsg.payload.length === 1 && sourceMsg.payload[0].items.length === 2,
    JSON.stringify(sourceMsg.payload));
  t.check("cache status reports the number of rows loaded",
    status.payload.rows === 3 && status.payload.trigger === "startup" && status.retain === true);

  // --- source status ------------------------------------------------------------
  const src = loadFunction(flow, "ofm_rt_srcstat", { env, global });
  for (const p of [{ source: "opcplc", online: true }, { source: "opcplc", online: false, error: "connection lost" }]) {
    const m = await src.run({ payload: p });
    produced.push({ topic: m.topic, payload: m.payload, what: "source " + (p.online ? "online" : "offline") });
  }

  // --- value path ----------------------------------------------------------------
  const norm = loadFunction(flow, "ofm_rt_norm", { env, global });
  const now = Date.now();
  const values = [
    ["float value, good", { address: NSU + "SpikeData", value: 12.5, status: "Good", sourceTimestamp: now - 500 }],
    ["float value outside range, uncertain", { address: NSU + "SpikeData", value: 9000, status: "Good", sourceTimestamp: now - 400 }],
    ["value with no device time", { address: NSU + "SpikeData", value: 1, status: "Good", sourceTimestamp: null }],
    ["bad value (v null)", { address: NSU + "SpikeData", value: null, status: "BadNoCommunication", sourceTimestamp: now - 300 }],
    ["boolean value", { address: NSU + "AlternatingBoolean", value: true, status: "Good", sourceTimestamp: now - 200 }],
    ["unmapped address", { address: "ns=3;s=Unknown/Tag", value: 5, status: "Good", sourceTimestamp: now - 100 }]
  ];
  for (const [what, p] of values) {
    const out = await norm.run({ payload: Object.assign({ source: "opcplc", receivedAt: now }, p) });
    if (out[0]) produced.push({ topic: out[0].topic, payload: out[0].payload, what });
    for (const m of out[3] || []) produced.push({ topic: m.topic, payload: m.payload, what: what + " (" + m.topic.split("/")[1] + ")" });
  }

  // --- every payload against its schema --------------------------------------------
  for (const p of produced) {
    const schema = contracts.schemaNameForTopic(p.topic);
    if (!schema) {
      t.check(p.what + ": topic has a schema", false, p.topic);
      continue;
    }
    let err = contracts.validate(schema, p.payload);
    if (!err && schema === "value" && !contracts.VALUE_TOPIC.test(p.topic)) err = "topic breaks the topic standard: " + p.topic;
    t.check(p.what + " matches " + schema + ".schema.json", !err, err + "  payload: " + JSON.stringify(p.payload));
  }
};

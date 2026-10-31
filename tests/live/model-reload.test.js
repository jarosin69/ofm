// Step 2.1: a model change reaches the running runtime without a restart.
// Sends the same database notification the configuration-table triggers send
// (migration 009) and expects the runtime to reload its model within 2 s.
// Changes no data: the model is reloaded as it is.
"use strict";
const { fromNodeRed, stack, connectDb } = require("../lib/harness");

const LIMIT_MS = 2000;

module.exports.run = async function (t) {
  const mqtt = fromNodeRed("mqtt");
  const topic = "ofm/_system/cache/" + stack.runtimeName;
  let db, client;
  try {
    db = await connectDb({ user: "ofm_reader", password: process.env.OFM_READER_DB_PASSWORD });
    client = mqtt.connect(stack.mqttUrl, {
      username: "ofm_reader", password: process.env.OFM_MQTT_READER_PASSWORD, protocolVersion: 5,
      clientId: "ofm-test-" + Math.random().toString(16).slice(2, 10), connectTimeout: 5000, reconnectPeriod: 0
    });
    const statuses = [];
    await new Promise((resolve, reject) => {
      client.on("error", reject);
      client.on("connect", () => client.subscribe(topic, { qos: 0 }, e => e ? reject(e) : resolve()));
    });
    client.on("message", (_, buf) => { try { statuses.push({ at: Date.now(), p: JSON.parse(buf.toString()) }); } catch (e) { /* ignore */ } });
    await new Promise(r => setTimeout(r, 500));                  // the retained status arrives first
    const before = statuses.length ? statuses[statuses.length - 1].p.ts : 0;

    const sent = Date.now();
    await db.query("SELECT pg_notify('model_changed', 'ofm_test')");
    let reloaded = null;
    while (!reloaded && Date.now() - sent < LIMIT_MS + 1000) {
      await new Promise(r => setTimeout(r, 100));
      reloaded = statuses.find(s => s.p.trigger === "notify" && s.p.ts > before && s.at >= sent);
    }
    t.check("model change reaches the runtime without restart" +
            (reloaded ? " (reloaded after " + (reloaded.at - sent) + " ms)" : ""),
            reloaded && reloaded.at - sent <= LIMIT_MS,
            reloaded ? "took " + (reloaded.at - sent) + " ms (limit " + LIMIT_MS + ")"
                     : "no reload seen - is the runtime's 'model change listener' node green?");
  } catch (e) {
    t.check("model change reaches the runtime without restart", false, e.message);
  } finally {
    if (client) client.end(true);
    if (db) await db.end();
  }
};

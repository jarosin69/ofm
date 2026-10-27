// Runs the code of one Node-RED function node from a flow file outside
// Node-RED, with stand-ins for node, context, global and env. The code is
// taken from the flow file itself, so the test always checks what is deployed.
"use strict";
const path = require("path");
const { ROOT, readJson } = require("./harness");

const AsyncFunction = (async () => {}).constructor;   // Node-RED runs function code as async

function loadFlow(file) {
  return readJson(file || path.join(ROOT, "flows", "ofm-runtime.json"));
}

function loadFunction(flow, id, { env = {}, global = {} } = {}) {
  const def = flow.find(n => n.id === id);
  if (!def || def.type !== "function") throw new Error("function node " + id + " not found in the flow");
  const globalStore = global;
  const contextStore = {};
  const sent = [];
  const statuses = [];
  const node = {
    status: s => statuses.push(s),
    send: m => sent.push(m),
    warn: () => {}, error: () => {}, log: () => {}
  };
  const ctx = store => ({ get: k => store[k], set: (k, v) => { store[k] = v; } });
  const fn = new AsyncFunction("msg", "global", "context", "env", "node", def.func);
  return {
    name: def.name,
    run: msg => fn(msg, ctx(globalStore), ctx(contextStore), { get: k => env[k] }, node),
    global: globalStore,
    context: contextStore,
    sent,
    statuses
  };
}

module.exports = { loadFlow, loadFunction };

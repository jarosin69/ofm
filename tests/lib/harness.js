// Shared helpers for the OFM test runner (tests/run.js).
//
// The tests run inside OFM's own Node-RED image, so they use the libraries
// already built into it (ajv for JSON Schema, mqtt, pg) and need no internet.
"use strict";
const path = require("path");
const fs = require("fs");
const { createRequire } = require("module");

const ROOT = path.resolve(__dirname, "..", "..");

// Load a library from the Node-RED installation inside the image, looking
// where npm may have placed it. OFM_NODE_MODULES lets the tests run against
// another installation.
const BASES = [
  process.env.OFM_NODE_MODULES || "/usr/src/node-red/package.json",
  "/usr/src/node-red/node_modules/node-red/package.json",
  "/usr/src/node-red/node_modules/@node-red/nodes/package.json"
].map(b => createRequire(b));

function fromNodeRed(name) {
  let first;
  for (const req of BASES) {
    try { return req(name); } catch (e) { first = first || e; }
  }
  throw new Error("library '" + name + "' not found in the Node-RED image: " + first.message);
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

// Collects results and prints one line per check.
class Results {
  constructor() {
    this.passed = 0;
    this.failed = 0;
    this.skipped = 0;
  }
  check(name, ok, detail) {
    if (ok) {
      this.passed++;
      console.log("  PASS  " + name);
    } else {
      this.failed++;
      console.log("  FAIL  " + name + (detail ? "\n          -> " + detail : ""));
    }
    return ok;
  }
  skip(name, why) {
    this.skipped++;
    console.log("  SKIP  " + name + (why ? " (" + why + ")" : ""));
  }
  note(text) {
    console.log("        " + text);
  }
}

// Settings for the stack-dependent suites. Inside the Compose network the
// services are reached by name (never localhost).
const stack = {
  runtimeName: process.env.OFM_RUNTIME_NAME || "ofm_runtime_01",
  mqttUrl: process.env.OFM_TEST_MQTT_URL || "mqtt://mosquitto:1883",
  grafanaUrl: process.env.OFM_TEST_GRAFANA_URL || "http://grafana:3000",
  noderedUrl: process.env.OFM_TEST_NODERED_URL || "http://nodered:1880",
  mathesarUrl: process.env.OFM_TEST_MATHESAR_URL || "http://mathesar:8000",
  listenSeconds: Number(process.env.OFM_TEST_LISTEN_SECONDS || 15)
};

// A database connection. Host, database, user and password come from the
// standard PGHOST, PGDATABASE, PGUSER, PGPASSWORD settings unless given.
async function connectDb(options = {}) {
  const { Client } = fromNodeRed("pg");
  const client = new Client(Object.assign({ connectionTimeoutMillis: 5000 }, options));
  await client.connect();
  return client;
}

module.exports = { ROOT, fromNodeRed, readJson, Results, stack, connectDb };

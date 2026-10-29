// Unit tests for "S7 and EtherNet/IP acquisition" (ADR-0018), run against a
// stand-in S7 library, so no PLC is needed: values are sent only when they
// change or are due again; an unreadable address is skipped with a warning
// and does not stop the others; a lost connection is reported offline, then
// online again after reconnecting. Takes about 4 seconds (real timers).
"use strict";
const { loadFlow, loadFunction } = require("../lib/functions");

const sleep = ms => new Promise(r => setTimeout(r, ms));

// A stand-in for @st-one-io/nodes7 with one PLC whose memory the test controls.
function fakeS7() {
  const plc = { values: { MR100: 21.5, MI20: 0 }, broken: false, connects: 0 };
  class S7Endpoint {
    constructor(opts) { this.opts = opts; this.isConnected = false; }
    on() {}
    async connect() {
      if (plc.broken) throw new Error("connection refused");
      plc.connects++;
      this.isConnected = true;
    }
    async disconnect() { this.isConnected = false; }
  }
  class S7ItemGroup {
    constructor(ep) { this.ep = ep; this.items = []; }
    addItems(a) {
      for (const x of [].concat(a)) {
        if (!/^(DB\d+,)?[A-Z]+\d+(\.\d+)?$/.test(x)) throw new Error("invalid address format");
        this.items.push(x);
      }
    }
    removeItems(a) { this.items = this.items.filter(x => ![].concat(a).includes(x)); }
    async readAllItems() {
      if (plc.broken) { this.ep.isConnected = false; throw new Error("Not connected"); }
      const out = {};
      for (const x of this.items) {
        if (!(x in plc.values)) { const e = new Error("Object does not exist"); e.code = 10; throw e; }
        out[x] = plc.values[x];
      }
      return out;
    }
  }
  return { plc, lib: { S7Endpoint, S7ItemGroup } };
}

module.exports.run = async function (t) {
  const { plc, lib } = fakeS7();
  const fn = loadFunction(loadFlow(), "ofm_rt_poll", { global: { s7: lib } });
  const items = [
    { address: "MR100", datatype: "float", maxIntervalMs: 350 },        // constant value
    { address: "MI20", datatype: "int", maxIntervalMs: 60000 },         // counts up
    { address: "DB99,REAL0", datatype: "float", maxIntervalMs: 60000 }, // does not exist in the PLC
    { address: "bad address", datatype: "float", maxIntervalMs: 60000 } // malformed
  ];
  const source = { name: "bench_s7", protocol: "s7", endpoint: "192.168.0.1",
                   settings: { rack: 0, slot: 1, pollIntervalMs: 100 }, items };
  const counter = setInterval(() => { plc.values.MI20++; }, 100);

  try {
    await fn.run({ payload: [source, { name: "sim", protocol: "opcua", endpoint: "x", items: [] }] });
    await sleep(650);

    const values = () => fn.sent.filter(m => m[0]).map(m => m[0].payload);
    const status = () => fn.sent.filter(m => m[1]).map(m => m[1].payload);
    const of = a => values().filter(v => v.address === a);

    t.check("source reported online once connected", status().length === 1 && status()[0].online === true,
            JSON.stringify(status()));
    t.check("only S7 and EtherNet/IP sources are handled here (OPC UA ignored)",
            status().every(s => s.source === "bench_s7"));
    t.check("unchanged value: sent at start, again only when due (max interval 350 ms)",
            of("MR100").length === 2, of("MR100").length + " messages");
    t.check("changing value: sent on every poll that sees a change", of("MI20").length >= 4,
            of("MI20").length + " messages");
    t.check("PLC values carry gateway time (no device timestamp) and Good status",
            values().every(v => v.sourceTimestamp === null && v.status === "Good" && Number.isFinite(v.receivedAt)));
    t.check("unreadable and malformed addresses are skipped, with a warning each",
            of("DB99,REAL0").length === 0 && of("bad address").length === 0 &&
            fn.warnings.some(w => w.includes("DB99,REAL0")) && fn.warnings.some(w => w.includes("bad address")),
            JSON.stringify(fn.warnings));

    plc.broken = true;
    await sleep(300);
    const off = status().filter(s => !s.online);
    t.check("lost connection reported offline, with the error", off.length === 1 && off[0].error === "Not connected",
            JSON.stringify(status()));
    const before = values().length;
    await sleep(300);
    t.check("no values sent while offline", values().length === before);

    plc.broken = false;
    await sleep(3200);                                   // reconnect after the back-off (1 s, then 2 s)
    const last = status()[status().length - 1];
    t.check("reconnected: reported online again and values flow", last.online === true && values().length > before,
            JSON.stringify(status()));
  } finally {
    clearInterval(counter);
    await fn.stop();
  }
  const after = fn.sent.length;
  await sleep(300);
  t.check("On Stop closes the connection and stops polling", fn.sent.length === after);
};

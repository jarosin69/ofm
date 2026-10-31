// Unit tests for "S7 and EtherNet/IP acquisition" (ADR-0018), run against a
// stand-in S7 library, so no PLC is needed: values are sent only when they
// change, and all again after each reconnection; an unreadable address is published bad with a warning
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
    { address: "MR100", datatype: "float" },        // constant value
    { address: "MI20", datatype: "int" },           // counts up
    { address: "DB99,REAL0", datatype: "float" },   // does not exist in the PLC
    { address: "bad address", datatype: "float" }   // malformed
  ];
  const source = { name: "bench_s7", protocol: "s7", endpoint: "192.168.0.1",
                   settings: { rack: 0, slot: 1, pollIntervalMs: 100 }, items, signature: "v1" };
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
    t.check("unchanged value: sent once after connecting, then not again (the heartbeat republishes)",
            of("MR100").length === 1, of("MR100").length + " messages");
    t.check("changing value: sent on every poll that sees a change", of("MI20").length >= 4,
            of("MI20").length + " messages");
    const read = values().filter(v => v.address === "MR100" || v.address === "MI20");
    t.check("PLC values carry gateway time (no device timestamp) and Good status",
            read.every(v => v.sourceTimestamp === null && v.status === "Good" && Number.isFinite(v.receivedAt)));
    t.check("unreadable and malformed addresses: a warning each, and published once as v null with a Bad status (step 2.4)",
            of("DB99,REAL0").length === 1 && of("bad address").length === 1 &&
            of("DB99,REAL0")[0].value === null && /^Bad/.test(of("DB99,REAL0")[0].status) &&
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
    t.check("after reconnecting, unchanged values are sent again (their quality is current again)",
            of("MR100").length === 2, of("MR100").length + " messages");

    // Model reloads (step 2.1): only changed sources are reconnected.
    const connects = plc.connects;
    await fn.run({ payload: [source] });
    await sleep(300);
    t.check("reload with the source unchanged keeps its connection", plc.connects === connects, plc.connects + " connects");
    await fn.run({ payload: [Object.assign({}, source, { signature: "v2", items: items.slice(0, 2) })] });
    await sleep(300);
    t.check("reload with the source changed reconnects it", plc.connects === connects + 1, plc.connects + " connects");
    await fn.run({ payload: [] });
    await sleep(250);
    const n = fn.sent.length;
    await sleep(300);
    t.check("reload with the source removed closes it", fn.sent.length === n);
  } finally {
    clearInterval(counter);
    await fn.stop();
  }
  const after = fn.sent.length;
  await sleep(300);
  t.check("On Stop closes the connection and stops polling", fn.sent.length === after);
};

const fs = require("fs");
// Unit tests for the "normalise and validate" function of flows/ofm-runtime.json.
// Run from the repository root (needs only Docker):
//   docker run --rm -v ${PWD}:/repo -w /repo node:22-alpine node tests/flows/normalise.test.js
const path = require("path");
const flow = JSON.parse(fs.readFileSync(process.argv[2] || path.join(__dirname, "..", "..", "flows", "ofm-runtime.json"), "utf8"));
let failures = 0;
const code = flow.find(n => n.id === "ofm_rt_norm").func;
const store = {}, ctx = {};
const globalCtx = { get: k => store[k], set: (k, v) => { store[k] = v; } };
const context = { get: k => ctx[k], set: (k, v) => { ctx[k] = v; } };
const env = { get: k => ({ OFM_RUNTIME_NAME: "ofm_runtime_01" })[k] };
const run = new Function("msg", "global", "context", "env", code);
store.ofm_model = { loadedAt: 1, byProperty: { 7: {} }, byKey: {
  "src|T": { propertyId: 7, topic: "a/b/c/d/m/temp", datatype: "float", low: 0, high: 50, historised: true, factor: 0.1, offset: 0 },
  "src|B": { propertyId: 8, topic: "a/b/c/d/m/run", datatype: "bool", historised: true, factor: 1, offset: 0 },
  "src|N": { propertyId: 9, topic: "a/b/c/d/m/count", datatype: "int", historised: false, factor: 1, offset: 0 },
  "src|S": { propertyId: 10, topic: "a/b/c/d/m/recipe", datatype: "string", historised: true, factor: 1, offset: 0 } } };
const now = Date.UTC(2026, 9, 25, 11, 0, 0);
const t = (name, payload, check) => {
  const out = run({ payload: Object.assign({ source: "src", status: "Good", receivedAt: now }, payload) }, globalCtx, context, env);
  const ok = check(out);
  if (!ok) failures++;
  console.log((ok ? "PASS " : "FAIL ") + name + (ok ? "" : "  -> " + JSON.stringify(out)));
};
t("scaled value, device time",  { address: "T", value: 255, sourceTimestamp: now - 1000 }, o => o[0].payload.v === 25.5 && o[0].payload.tss === "device" && o[0].payload.q === "good" && o[1].params[2] === 25.5);
t("outside range -> uncertain", { address: "T", value: 600, sourceTimestamp: now - 900 }, o => o[0].payload.q === "uncertain");
t("future device time -> gateway time, uncertain", { address: "T", value: 100, sourceTimestamp: now + 10 * 60000 }, o => o[0].payload.ts === now && o[0].payload.tss === "gateway" && o[0].payload.q === "uncertain");
t("PLC clock in 1970 -> gateway, uncertain", { address: "T", value: 100, sourceTimestamp: 5000 }, o => o[0].payload.tss === "gateway" && o[0].payload.q === "uncertain");
t("no device time -> gateway, good", { address: "T", value: 100, sourceTimestamp: null }, o => o[0].payload.tss === "gateway" && o[0].payload.q === "good");
t("device time goes backwards -> uncertain", { address: "T", value: 100, sourceTimestamp: now - 5000 }, o => o[0].payload.q === "uncertain");
t("OPC UA Uncertain status kept", { address: "T", value: 100, sourceTimestamp: now + 1, status: "UncertainLastUsableValue" }, o => o[0].payload.q === "uncertain");
t("Bad status, no value -> v null, bad, not historised", { address: "T", value: null, sourceTimestamp: now + 2, status: "BadNoCommunication" }, o => o[0].payload.v === null && o[0].payload.q === "bad" && o[1] === null);
t("boolean -> true, stored as 1", { address: "B", value: true, sourceTimestamp: now }, o => o[0].payload.v === true && o[1].params[2] === 1);
t("64-bit counter [hi,lo] -> number", { address: "N", value: [1, 5], sourceTimestamp: now }, o => o[0].payload.v === 4294967301 && o[1] === null);
t("text -> text historian table", { address: "S", value: "M-12", sourceTimestamp: now }, o => o[0].payload.v === "M-12" && o[2].params[2] === "M-12" && o[1] === null);
t("non-numeric for float -> bad", { address: "T", value: "abc", sourceTimestamp: now + 3 }, o => o[0].payload.v === null && o[0].payload.q === "bad");
t("unknown address -> quarantine + cache status", { address: "ns=3;s=X/Y#1", value: 1, sourceTimestamp: now }, o => o[0] === null && o[3][0].topic === "ofm/_unmapped/src/ns=3;s=X_Y_1" && o[3][0].payload.addr === "ns=3;s=X/Y#1" && o[3][1].payload.unmapped === 1);
t("same unknown address again -> no new cache status", { address: "ns=3;s=X/Y#1", value: 2, sourceTimestamp: now }, o => o[3].length === 1);
console.log(`\n${failures === 0 ? "All tests passed." : failures + " test(s) failed."}`);
process.exit(failures === 0 ? 0 : 1);

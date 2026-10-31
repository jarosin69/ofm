// Unit tests for step 2.6, "runtime starts without the database" (ADR-0001):
// "build model cache" saves every model loaded from the database to disk;
// "saved model copy" starts the runtime from that copy when the database
// cannot be reached at start-up, and never replaces a model already running.
// Uses a temporary folder for the copy; needs no database, broker or PLC.
"use strict";
const os = require("os"), fs = require("fs"), path = require("path");
const { loadFlow, loadFunction } = require("../lib/functions");
const contracts = require("../lib/contracts");

const RUNTIME = "ofm_runtime_01";
const NSU = "nsu=http://microsoft.com/Opc/OpcPlc/;s=";
const row = (id, name, address) => ({
  property_id: id, topic: "acme/melbourne/chocolate/eggline01/depositor01/" + name, datatype: "float", unit: "degC",
  display_name: name, description: null, low: 0, high: 50, alarm_low: null, alarm_high: null, deadband: "0",
  max_publish_interval_ms: 60000, is_historised: true, scale_factor: "0.02", scale_offset: "30.5",
  source_name: "opcplc", protocol: "opcua", endpoint: "opc.tcp://opcplc:50000", source_settings: { securityMode: "None" },
  address: NSU + address, cache_key: "opcplc|" + NSU + address
});
const ROWS = [row(1, "chocolate_temp", "SpikeData"), row(2, "air_temp", "DipData")];
const dbError = { error: { message: "getaddrinfo EAI_AGAIN timescaledb" }, trigger: "startup", params: [RUNTIME] };

module.exports.run = async function (t) {
  const flow = loadFlow();
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ofm-model-"));
  const file = path.join(dir, RUNTIME + ".json");
  const env = { OFM_RUNTIME_NAME: RUNTIME, OFM_MODEL_COPY_DIR: dir };
  const fresh = () => {                       // a newly started runtime: empty global context
    const global = { fs, path };
    return { global,
             cache: loadFunction(flow, "ofm_rt_cache", { env, global }),
             copy: loadFunction(flow, "ofm_rt_modelcopy", { env, global }),
             norm: loadFunction(flow, "ofm_rt_norm", { env, global }) };
  };
  const valid = p => contracts.validate("system-cache", p);

  // --- the flow is wired as intended -------------------------------------------------------
  const byId = id => flow.find(n => n.id === id);
  t.check("flow: a failed model load goes to 'saved model copy', which feeds the cache and the 10 s retry",
    JSON.stringify(byId("ofm_rt_loadcatch").wires) === '[["ofm_rt_modelcopy"]]' &&
    JSON.stringify(byId("ofm_rt_modelcopy").wires) === '[["ofm_rt_cache"],["ofm_rt_retry"]]');

  // --- 1. first start, database answers: the copy is saved ---------------------------------
  let r = fresh();
  t.check("no copy before the first load", !fs.existsSync(file));
  const [startup, , cleanup] = await r.cache.run({ payload: ROWS, trigger: "startup" });
  let saved = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : null;
  t.check("a model loaded from the database is saved to <OFM_MODEL_COPY_DIR>/<runtime>.json",
    saved && saved.format === 1 && saved.runtime === RUNTIME && saved.rows.length === 2 &&
    saved.savedAt === r.global.ofm_model.loadedAt, saved ? JSON.stringify(saved).slice(0, 200) : "no file");
  t.check("the copy holds the rows exactly as the database returned them",
    saved && JSON.stringify(saved.rows) === JSON.stringify(ROWS));
  t.check("no temporary file left behind", fs.readdirSync(dir).every(f => !f.endsWith(".tmp")), fs.readdirSync(dir).join(", "));
  t.check("start-up from the database: cache status 'startup' without savedAt, clean-up started",
    startup[0].payload.trigger === "startup" && !("savedAt" in startup[0].payload) && cleanup !== null && !valid(startup[0].payload),
    JSON.stringify(startup[0].payload));

  // --- 2. a model change is saved too ----------------------------------------------------
  const changed = ROWS.map(x => Object.assign({}, x));
  changed[1].scale_factor = "0.5";
  await new Promise(res => setTimeout(res, 5));
  await r.cache.run({ payload: changed, trigger: "notify" });
  saved = JSON.parse(fs.readFileSync(file, "utf8"));
  t.check("a reload after a model change replaces the copy", saved.rows[1].scale_factor === "0.5" &&
    saved.savedAt === r.global.ofm_model.loadedAt);
  const savedAt = saved.savedAt;

  // --- 3. a model already running is never replaced by the copy ----------------------------
  const [none, retry] = await r.copy.run(Object.assign({}, dbError));
  t.check("database lost later: the running model is kept, the copy is not read, retry continues",
    none === null && retry && retry.trigger === "startup" && r.copy.warnings.length === 0);

  // --- 4. restart while the database is down: start from the copy ----------------------------
  r = fresh();
  const [fromDisk, retry2] = await r.copy.run(Object.assign({}, dbError));
  t.check("restart without the database: the saved rows go to 'build model cache' with trigger disk",
    fromDisk && fromDisk.trigger === "disk" && fromDisk.savedAt === savedAt &&
    JSON.stringify(fromDisk.payload) === JSON.stringify(changed) && retry2 && retry2.params[0] === RUNTIME,
    JSON.stringify(fromDisk && { trigger: fromDisk.trigger, savedAt: fromDisk.savedAt }));
  t.check("the start from the copy is logged as a warning with the reason and the copy's age",
    r.copy.warnings.length === 1 && r.copy.warnings[0].includes("EAI_AGAIN") && r.copy.warnings[0].includes("starting from the copy saved"),
    r.copy.warnings.join(" | "));
  const [diskOut, diskSources, diskCleanup] = await r.cache.run(fromDisk);
  t.check("the runtime runs on the copy: every property, the sources to connect",
    Object.keys(r.global.ofm_model.byProperty).length === 2 && diskSources.payload.length === 1 &&
    r.global.ofm_model.byKey["opcplc|" + NSU + "DipData"].factor === 0.5);
  t.check("cache status says disk, with savedAt; it matches its schema",
    diskOut[0].payload.trigger === "disk" && diskOut[0].payload.savedAt === savedAt && !valid(diskOut[0].payload),
    JSON.stringify(diskOut[0].payload) + " " + (valid(diskOut[0].payload) || ""));
  t.check("a start from the copy does not run the clean-up (the copy may be out of date)", diskCleanup === null);
  t.check("_meta topics are published from the copy", diskOut.filter(m => m.topic.endsWith("/_meta")).length === 2);
  t.check("the copy is not rewritten when the runtime starts from it",
    JSON.parse(fs.readFileSync(file, "utf8")).savedAt === savedAt);
  const unmapped = (await r.norm.run({ payload: { source: "opcplc", address: "ns=3;s=Other", value: 1, status: "Good",
                                                  sourceTimestamp: null, receivedAt: Date.now() } }))[3];
  const unmappedStatus = unmapped && unmapped.find(m => m.topic.startsWith("ofm/_system/cache/"));
  t.check("cache status after an unmapped address still says disk, with savedAt (schema-valid)",
    unmappedStatus && unmappedStatus.payload.trigger === "disk" && unmappedStatus.payload.savedAt === savedAt &&
    !valid(unmappedStatus.payload), JSON.stringify(unmappedStatus && unmappedStatus.payload));
  t.check("while running on the copy, further failed retries do not reload it",
    (await r.copy.run(Object.assign({}, dbError)))[0] === null);

  // --- 5. the database answers: its model replaces the copy ----------------------------------
  await new Promise(res => setTimeout(res, 5));
  const [back, backSources, backCleanup] = await r.cache.run({ payload: changed, trigger: "startup" });
  t.check("database back: cache status 'startup', clean-up runs now",
    back[0].payload.trigger === "startup" && !("savedAt" in back[0].payload) && backCleanup !== null);
  t.check("database back with the same model: no _meta republished, no source reconnects",
    back.filter(m => m.topic.endsWith("/_meta")).length === 0 &&
    backSources.payload[0].signature === diskSources.payload[0].signature);
  t.check("database back: the copy is saved again", JSON.parse(fs.readFileSync(file, "utf8")).savedAt > savedAt);

  // --- 6. no usable copy: wait for the database -----------------------------------------------
  const refused = async (what, prepare, expect) => {
    prepare();
    const x = fresh();
    const [out1, out2] = await x.copy.run(Object.assign({}, dbError));
    const again = await x.copy.run(Object.assign({}, dbError));
    t.check(what + ": no model, a warning naming the problem (once), retry continues",
      out1 === null && out2 && again[0] === null && again[1] && x.copy.warnings.length === 1 &&
      x.copy.warnings[0].includes(expect) && x.global.ofm_model === undefined,
      x.copy.warnings.join(" | "));
  };
  await refused("no copy yet (first start ever)", () => fs.rmSync(file), "there is no saved model copy");
  await refused("damaged copy (half written)", () => fs.writeFileSync(file, '{"format":1,"runtime":"ofm_ru'), "cannot be read");
  await refused("copy in an unknown format", () => fs.writeFileSync(file, JSON.stringify({ format: 2, runtime: RUNTIME, savedAt: 1, rows: [] })), "not in the expected format");
  await refused("copy of another runtime", () => fs.writeFileSync(file, JSON.stringify({ format: 1, runtime: "ofm_runtime_02", savedAt: 1, rows: [] })), "belongs to runtime ofm_runtime_02");

  // --- 7. a copy that cannot be saved does not stop the runtime ----------------------------------
  const blocked = path.join(dir, "not-a-folder");
  fs.writeFileSync(blocked, "");
  const global = { fs, path };
  const cache = loadFunction(flow, "ofm_rt_cache", { env: { OFM_RUNTIME_NAME: RUNTIME, OFM_MODEL_COPY_DIR: blocked }, global });
  const [ok] = await cache.run({ payload: ROWS, trigger: "startup" });
  t.check("copy cannot be saved: a warning, and the model is still loaded and published",
    cache.warnings.length === 1 && cache.warnings[0].includes("could not save the model copy") &&
    Object.keys(global.ofm_model.byProperty).length === 2 && ok[0].payload.rows === 2, cache.warnings.join(" | "));

  fs.rmSync(dir, { recursive: true, force: true });
};

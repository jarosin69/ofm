// Unit tests for "historian writer (store-and-forward)" (ADR-0002, step 2.4),
// against a stand-in database and a temporary queue folder: batching; a lost
// database fills the compressed disk queue and is reported; the queue is
// written oldest first when the database returns; the size limit drops the
// oldest rows and reports them; rows the database refuses as data cannot block
// the queue; rows in memory survive a stop.
"use strict";
const os = require("os"), fs = require("fs"), path = require("path"), zlib = require("zlib");
const { loadFlow, loadFunction } = require("../lib/functions");
const contracts = require("../lib/contracts");

function fakeDb() {
  const db = { up: true, rows: [], queries: 0, text: [] };
  class Pool {
    on() {}
    async query(sql, cols) {
      db.queries++;
      if (!db.up) { const e = new Error("connect ECONNREFUSED timescaledb:5432"); e.code = "ECONNREFUSED"; throw e; }
      const rows = cols[0].map((_, i) => cols.map(c => c[i]));
      if (rows.some(r => r[1] === 666)) { const e = new Error("violates foreign key constraint"); e.code = "23503"; throw e; }
      for (const r of rows) db.rows.push(r);
      if (sql.includes("measurement_text")) for (const r of rows) db.text.push(r[1]);
    }
    async end() {}
  }
  return { db, pg: { Pool } };
}

module.exports.run = async function (t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ofm-sf-"));
  const { db, pg } = fakeDb();
  const fn = loadFunction(loadFlow(), "ofm_rt_writer", {
    global: { pg, fs, path, zlib },
    env: { OFM_RUNTIME_NAME: "ofm_runtime_01", OFM_SF_QUEUE_DIR: dir, OFM_SF_QUEUE_MAX_GB: "0.000002" }   // 2 kB limit
  });
  const now = Date.now();
  let n = 0;
  const row = (pid, v) => ({ params: [now + n++, pid, v, 0, 0] });
  const tick = () => fn.run({ topic: "tick" });
  const files = () => fs.readdirSync(dir).filter(f => f.endsWith(".json.gz"));
  const statusOk = s => s && !contracts.validate("system-historian", s.payload);

  // 1. normal writing, in batches
  await fn.run(row(1, 1.5)); await fn.run(row(1, 1.6)); await fn.run(row(2, "batch A"));
  let s = await tick();
  t.check("rows are written in one batch per table at the tick", db.rows.length === 3 && db.queries === 2, db.queries + " queries");
  t.check("status 'writing' published, valid", statusOk(s) && s.payload.state === "writing" && s.retain);
  await fn.run({ params: [now + n++, 9, null, 2, 1, "t"] });                 // text property, no value
  await fn.run({ params: [now + n++, 10, null, 2, 1] });                     // numeric property, no value
  await tick();
  t.check("rows without a value (bad) are written; the 't' mark sends a NULL to the text table",
          db.text.includes(9) && !db.text.includes(10) && db.rows.some(r => r[1] === 10 && r[2] === null));
  const q0 = db.queries;
  for (let i = 0; i < 499; i++) await fn.run(row(3, i));
  await fn.run(row(3, 499));
  t.check("500 waiting rows are written at once, without waiting for the tick", db.queries === q0 + 1 && db.rows.length === 505);

  // 2. database lost: disk queue
  db.up = false;
  for (let i = 0; i < 20; i++) await fn.run(row(4, i));
  s = await tick();
  t.check("database lost: the batch goes to the disk queue (compressed file)", files().length === 1, files().join());
  t.check("status 'buffering' with the queue depth", statusOk(s) && s.payload.state === "buffering" && s.payload.queueDepth === 20,
          JSON.stringify(s && s.payload));
  await fn.run(row(4, 99));
  await tick();
  t.check("while the database is away, new rows queue behind the old ones", files().length === 2);

  // 3. queue full: oldest dropped and reported
  for (let k = 0; k < 6; k++) {
    for (let i = 0; i < 60; i++) await fn.run(row(5, Math.random()));
    s = await tick() || s;
  }
  const dropped = s.payload.droppedRows;
  t.check("queue over its limit: oldest rows dropped and reported as droppedRows", dropped > 0 && statusOk(s),
          JSON.stringify(s.payload));
  t.check("a warning names the dropped rows", fn.warnings.some(w => w.includes("queue full")));

  // 4. database back: queue written oldest first, then deleted
  db.up = true;
  fn.context.st.nextTry = 0;                     // as if the retry back-off (at most 10 s) had passed
  const before = db.rows.length;
  s = await tick();
  s = (await tick()) || s;
  t.check("database back: the queue is written and emptied", files().length === 0 && db.rows.length > before);
  t.check("status back to 'writing', dropped rows still reported", statusOk(s) && s.payload.state === "writing" &&
          s.payload.queueDepth === 0 && s.payload.droppedRows === dropped, JSON.stringify(s && s.payload));
  const queued = db.rows.slice(before).map(r => r[0]);
  t.check("queued rows written in the order they were queued", queued.every((x, i) => i === 0 || x > queued[i - 1]));

  // 5. a row the database refuses cannot block anything
  const b2 = db.rows.length;
  await fn.run(row(7, 1)); await fn.run(row(666, 2)); await fn.run(row(7, 3));
  await tick();
  t.check("a refused row is dropped with a warning; the others are written",
          db.rows.length === b2 + 2 && fn.warnings.some(w => w.includes("refused")) && files().length === 0);

  // 6. stop with rows in memory
  await fn.run(row(8, 1)); await fn.run(row(8, 2));
  await fn.stop();
  const saved = files();
  t.check("on stop, rows still in memory are saved to the queue",
          saved.length === 1 && JSON.parse(zlib.gunzipSync(fs.readFileSync(path.join(dir, saved[0])))).length === 2);
  fs.rmSync(dir, { recursive: true, force: true });
};

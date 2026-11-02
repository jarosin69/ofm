// Drill recorder (step 2.9): watches the load-test line while you break
// things in another window (tests/README.md, drills X1-X6), then reports what
// a consumer saw - gaps on the UNS, gaps in the historian, values lost.
// Opt-in, never part of "all":
//   docker compose run --rm -e OFM_WATCH_MINUTES=4 test watch
// Gaps on the UNS are expected in some drills; the report shows when and how
// long. The one rule for every drill: nothing that reached the UNS may be
// missing from the historian - except, after a hard kill of the runtime, at
// most the values of the last second still in the writer's memory.
"use strict";
const { loadModel, record, compare } = require("../lib/loadmeter");

module.exports.run = async function (t) {
  const minutes = Number(process.env.OFM_WATCH_MINUTES || 4);
  const model = await loadModel();
  if (!t.check("the load-test line is in the model (" + model.length + " properties)", model.length > 0,
               "none - add it: docker compose run --rm migrate loadtest; docker compose --profile loadtest up -d")) return;
  t.note("start the drill in another window now; recording runs " + minutes + " minute(s)");
  const m = await record({ seconds: Math.max(60, minutes * 60), note: x => t.note(x), model });
  const c = await compare(m, { warmup: 0, note: x => t.note(x) });
  if (!t.check("historian reachable after the drill", c !== null, "database or writer did not recover within 2 minutes")) return;

  t.note("");
  t.note("REPORT (" + model.length + " values/s, " + c.seconds + " s)");
  t.note("events:" + (m.events.length ? "" : " none"));
  for (const e of m.events) t.note("  " + require("../lib/loadmeter").clock(e.t) + "  " + e.text);
  t.note("UNS gaps (under half the values): " + (c.unsGaps.length ? c.unsGaps.join(", ") : "none"));
  t.note("historian gaps (under half the rows): " + (c.histGaps.length ? c.histGaps.join(", ") : "none"));
  t.note("historian writer: largest queue reported " + m.writer.maxQueue + " rows (it reports once a minute while buffering), dropped " + m.writer.maxDropped);
  t.note("values seen on the UNS but missing from the historian: " + c.lost);
  t.check("nothing that reached the UNS is lost from the historian (a hard kill may lose at most one second: " + model.length + ")",
          c.lost <= model.length, c.lost + " values lost");
  t.check("the historian writer dropped nothing", m.writer.maxDropped === 0, m.writer.maxDropped + " rows dropped");
};

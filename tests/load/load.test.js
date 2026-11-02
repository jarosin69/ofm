// Load test (step 2.9): can one runtime carry the load-test line - by default
// 2,000 values per second - from OPC UA through the UNS into the historian?
// Opt-in, never part of "all":
//   docker compose run --rm -e OFM_LOAD_MINUTES=10 test load
// Needs the load-test line (tests/README.md, step 2.9). Targets (Overview
// §3.2): every value on the UNS and in the historian, delay small, nothing
// buffered or dropped, nothing silent.
"use strict";
const { loadModel, record, compare, delayPercentile } = require("../lib/loadmeter");

const WARMUP_S = 30;            // the first seconds after the start are not judged
const MAX_DELAY_P95_S = 2.5;    // device time -> UNS; OPC UA samples 0.5 s, publishes every 1 s (assumption)

module.exports.run = async function (t) {
  const minutes = Number(process.env.OFM_LOAD_MINUTES || 5);
  const model = await loadModel();
  if (!t.check("the load-test line is in the model (" + model.length + " properties)", model.length > 0,
               "none - add it: docker compose run --rm migrate loadtest; docker compose --profile loadtest up -d")) return;
  const n = model.length;
  const m = await record({ seconds: Math.max(60, minutes * 60), note: x => t.note(x), model });

  // --- the UNS --------------------------------------------------------------------------
  const judged = [];
  for (let s = Math.ceil((m.start + WARMUP_S * 1000) / 1000); s < Math.floor(m.end / 1000) - 1; s++) judged.push(m.arrivals.get(s) || 0);
  const sorted = judged.slice().sort((a, b) => a - b);
  const median = sorted.length ? sorted[Math.floor(sorted.length / 2)] : 0;
  let worst10 = Infinity;
  for (let i = 0; i + 10 <= judged.length; i += 10) worst10 = Math.min(worst10, judged.slice(i, i + 10).reduce((a, b) => a + b, 0) / 10);
  if (worst10 === Infinity) worst10 = 0;
  t.note("UNS: median " + median + " values/s, worst 10 s average " + Math.round(worst10) + " values/s (target " + n + ")");
  t.check("UNS carries the load: median at least 95 % of " + n + " values/s", median >= 0.95 * n, median + " values/s");
  t.check("UNS never falls behind: every 10 s average at least 90 %", worst10 >= 0.9 * n, Math.round(worst10) + " values/s");
  const p50 = delayPercentile(m.delays, 0.5), p95 = delayPercentile(m.delays, 0.95), p99 = delayPercentile(m.delays, 0.99);
  t.note("delay device time -> UNS: median " + p50 + " s, 95 % within " + p95 + " s, 99 % within " + p99 + " s");
  t.check("95 % of values reach the UNS within " + MAX_DELAY_P95_S + " s of their device time", p95 !== null && p95 <= MAX_DELAY_P95_S, p95 + " s");
  t.check("all values good", m.notGood === 0, m.notGood + " values uncertain or bad");
  t.check("no property silent for more than 5 s", m.stalls === 0, m.stalls + " silences");

  // --- the historian -------------------------------------------------------------------------
  const c = await compare(m, { warmup: WARMUP_S, note: x => t.note(x) });
  if (!t.check("historian reachable for the comparison", c !== null, "database or writer did not recover within 2 minutes")) return;
  t.note("historian: " + c.rows + " rows for " + c.seconds + " s = " + Math.round(c.rows / Math.max(1, c.seconds)) + " rows/s; UNS " + c.uns + " values");
  t.check("every value seen on the UNS is in the historian", c.lost === 0, c.lost + " missing");
  t.check("historian keeps up: at least 95 % of " + n + " rows per second", c.rows >= 0.95 * n * c.seconds,
          Math.round(c.rows / Math.max(1, c.seconds)) + " rows/s");
  t.check("historian writer never had to buffer, nothing dropped",
          !m.writer.states.has("buffering") && m.writer.maxDropped === 0,
          "states seen: " + [...m.writer.states].join(", ") + "; largest queue " + m.writer.maxQueue + "; dropped " + m.writer.maxDropped);
  t.note("CPU and memory: run 'docker stats --no-stream' in another window during the test (tests/README.md, L2)");
};

// Unit tests for the simulated packing line (ADR-0023,
// demo/packing-line/linesim-flows.json): line.json is read and checked; the
// line runs at the constraint's pace; a breakdown spreads up and down the
// line through the conveyors; rejects, breakdowns, the shift pattern,
// changeovers and pausing behave as the demo guide says. Time is simulated
// (msg.now), so hours of production take about a second.
"use strict";
const path = require("path");
const { ROOT, readJson } = require("../lib/harness");
const { loadFlow, loadFunction } = require("../lib/functions");

const FLOW = path.join(ROOT, "demo", "packing-line", "linesim-flows.json");
const LINE = path.join(ROOT, "demo", "packing-line", "line.json");
const S = { running: 1, idle: 2, blocked: 3, starved: 4, fault: 5, setup: 6, cleaning: 7 };

// A copy of line.json with the shift pattern off and a fixed seed; "ideal"
// also switches off every random stop and reject.
function makeLine(change, ideal) {
  const l = readJson(LINE);
  l.seed = 12345;
  l.schedule.enabled = false;
  if (ideal) {
    l.unknownFaultPct = 0;
    l.quality.weightSigmaPct = 0;
    for (const m of l.machines) {
      Object.assign(m, { mtbfH: 0, jamsPerH: 0, rejectPct: 0, speedPct: 100 });
      if (m.shortage) m.shortage.perShift = 0;
      if (m.palletWait) m.palletWait.probability = 0;
    }
  }
  if (change) change(l);
  return l;
}

async function start(line, t0) {
  const flow = loadFlow(FLOW);
  const e = loadFunction(flow, "linesim_engine");
  let t = t0 || Date.UTC(2026, 10, 2, 0, 0, 0);
  let snap = null;
  const faults = {};                                   // slot -> number of times the machine went to fault
  const panels = [];                                   // what the control panel received (output 2)
  await e.run({ topic: "config", payload: line, now: t });
  return {
    async run(seconds, each) {
      for (let i = 0; i < Math.round(seconds * 10); i++) {
        t += 100;
        const res = await e.run({ topic: "tick", now: t });
        if (res && res[1]) panels.push(res[1].payload);
        const out = res && res[0];
        if (!out) continue;
        for (const m of out.payload.machines) {
          const before = snap && snap.machines.find(x => x.slot === m.slot);
          if (m.state === S.fault && (!before || before.state !== S.fault)) faults[m.slot] = (faults[m.slot] || 0) + 1;
        }
        snap = out.payload;
        if (each) each(snap);
      }
      return snap;
    },
    cmd: p => e.run({ topic: "cmd", payload: p, now: t }),
    reload: l => e.run({ topic: "config", payload: l, now: t }),
    tick: () => e.run({ topic: "tick", now: (t += 100) }),
    faults,
    panels,
    get now() { return t; }
  };
}
const by = (snap, name) => snap.machines.find(m => m.name === name);

module.exports.run = async function (t) {
  // --- line.json ---------------------------------------------------------------------------
  const flow = loadFlow(FLOW);
  const fs = require("fs");
  const loader = loadFunction(flow, "linesim_config", { env: { OFM_LINESIM_CONFIG: LINE }, global: { fs } });
  const cfg = await loader.run({});
  t.check("line.json is read and passes its checks (6 machines, one constraint)",
          cfg && cfg.topic === "config" && cfg.payload.machines.length === 6, JSON.stringify(loader.statuses.slice(-1)));
  const bad = makeLine(l => { l.machines[0].constraint = true; });
  const tmp = path.join(require("os").tmpdir(), "linesim-bad.json");
  fs.writeFileSync(tmp, JSON.stringify(bad));
  const loader2 = loadFunction(flow, "linesim_config", { env: { OFM_LINESIM_CONFIG: tmp }, global: { fs } });
  t.check("a line.json with two constraints is refused with a clear status", (await loader2.run({})) === null &&
          /problem/.test(JSON.stringify(loader2.statuses)), JSON.stringify(loader2.statuses));
  fs.unlinkSync(tmp);

  // --- an ideal line: the constraint sets the pace ----------------------------------------------
  let sim = await start(makeLine(null, true));
  let changes = 0, prev = null, ticks = 0;
  let s = await sim.run(3600, snap => {             // after the first 2 minutes, an ideal line holds steady
    if (prev && ++ticks > 1200) changes += snap.machines.filter((m, i) => m.state !== prev.machines[i].state).length;
    prev = snap;
  });
  const filler = by(s, "filler"), closer = by(s, "closer"), packer = by(s, "case_packer"), pal = by(s, "palletiser");
  t.note("ideal hour: filler " + filler.count_good + ", closer " + closer.count_good + " cartons; case packer " +
         packer.count_good + ", palletiser " + pal.count_good + " cases, " + pal.process_value + " pallets");
  t.check("ideal line: the filler makes its rated 100 cartons/min (5,950-6,000 in the first hour)",
          filler.count_good >= 5950 && filler.count_good <= 6000, filler.count_good);
  t.check("ideal line: little is held on the conveyors (closer within 40 cartons of the filler)",
          filler.count_good - closer.count_good >= 0 && filler.count_good - closer.count_good <= 40, filler.count_good - closer.count_good);
  t.check("ideal line: the case packer packs 10 cartons per case", Math.abs(packer.count_good - Math.floor(closer.count_good / 10)) <= 7,
          packer.count_good + " cases for " + closer.count_good + " cartons");
  t.check("ideal line: every machine is running (faster machines keep pace without flapping to starved or blocked)",
          s.machines.every(m => m.state === S.running), s.machines.map(m => m.name + "=" + m.state).join(" "));
  t.check("ideal line: no machine changes state after the first 2 minutes (no flapping)", changes === 0, changes + " changes");
  t.check("ideal line: in = good + reject on every machine", s.machines.every(m => m.count_in === m.count_good + m.count_reject));
  t.check("ideal line: shown speed of the filler is about its setpoint (97-100)", filler.speed >= 97 && filler.speed <= 100, filler.speed);
  t.check("ideal line: faster machines show the line's pace, not their own (closer 94-100 cartons/min)",
          closer.speed >= 94 && closer.speed <= 100, closer.speed);
  t.check("ideal line: a machine that waits for each case shows its real pace (palletiser about 10 cases/min)",
          pal.speed >= 8 && pal.speed <= 12, pal.speed);
  t.check("heartbeat rises by one per second (3,600 in an hour)", Math.abs(s.heartbeat - 3600) <= 1 && filler.heartbeat === s.heartbeat, s.heartbeat);

  // --- a breakdown spreads through the conveyors ------------------------------------------------------
  await sim.cmd({ cmd: "break", slot: 4, hold: true });
  s = await sim.run(60);
  const states = n => by(s, n).state;
  t.check("closer broken (fault 401): checkweigher, filler and erector blocked within a minute",
          states("closer") === S.fault && by(s, "closer").fault_code === 401 &&
          states("checkweigher") === S.blocked && states("filler") === S.blocked && states("erector") === S.blocked,
          s.machines.map(m => m.name + "=" + m.state).join(" "));
  t.check("closer broken: case packer and palletiser starved within a minute",
          states("case_packer") === S.starved && states("palletiser") === S.starved,
          s.machines.map(m => m.name + "=" + m.state).join(" "));
  t.check("a stopped machine shows speed 0", by(s, "filler").speed === 0 && by(s, "closer").speed === 0);
  await sim.cmd({ cmd: "repair", slot: 4 });
  s = await sim.run(60);
  t.check("closer repaired: the whole line runs again within a minute", s.machines.every(m => m.state === S.running),
          s.machines.map(m => m.name + "=" + m.state).join(" "));

  // --- quality -------------------------------------------------------------------------------------------
  sim = await start(makeLine(l => { l.quality.weightSigmaPct = 0.8; }, true));
  s = await sim.run(3600);
  const w = by(s, "checkweigher");
  const rate = w.count_reject / w.count_in * 100;
  t.note("checkweigher: " + w.count_reject + " of " + w.count_in + " rejected (" + rate.toFixed(2) + " %), last weight " + w.process_value + " g");
  t.check("checkweigher rejects about 0.6 % at a 0.8 % weight spread and limits -2 %/+5 % (0.3-1.0 %)", rate >= 0.3 && rate <= 1.0, rate.toFixed(2) + " %");
  t.check("checkweigher shows the last carton's weight near 250 g", w.process_value > 240 && w.process_value < 260, w.process_value);
  t.check("rejected cartons do not travel on: closer in = checkweigher good (minus what is on the conveyor)",
          w.count_good - by(s, "closer").count_in >= 0 && w.count_good - by(s, "closer").count_in <= 15);

  // --- breakdowns ---------------------------------------------------------------------------------------
  sim = await start(makeLine(l => { l.machines[1].mtbfH = 0.5; l.machines[1].mttrMin = 2; }, true));
  s = await sim.run(5 * 3600);
  t.note("filler with MTBF 0.5 h, MTTR 2 min, 5 h: " + (sim.faults[2] || 0) + " breakdowns, good " + by(s, "filler").count_good);
  t.check("breakdowns come at about the MTBF (3-20 in 5 hours at MTBF 0.5 h)", sim.faults[2] >= 3 && sim.faults[2] <= 20, sim.faults[2]);

  // --- the default line: a plausible day --------------------------------------------------------------
  sim = await start(makeLine());
  s = await sim.run(8 * 3600);
  const good = by(s, "closer").count_good, oee = good / (8 * 6000) * 100;
  t.note("default settings, 8 h without shift pattern: " + good + " good cartons (about " + oee.toFixed(0) + " % of 48,000); stops per machine: " +
         s.machines.map(m => m.name + " " + (sim.faults[m.slot] || 0)).join(", "));
  t.check("default settings give a believable line: 40-85 % of rated output", oee >= 40 && oee <= 85, oee.toFixed(1) + " %");
  t.check("default settings: stops on most machines in 8 hours (at least 4 of 6)",
          s.machines.filter(m => (sim.faults[m.slot] || 0) > 0).length >= 4);
  t.check("in = good + reject on every machine, also with stops and rejects",
          s.machines.every(m => m.count_in === m.count_good + m.count_reject));

  // --- shift pattern (Melbourne time) ------------------------------------------------------------------------
  const at = async (iso, label, expectMode, expectState) => {
    const l = makeLine(null, true);
    l.schedule.enabled = true;
    const x = await start(l, Date.parse(iso));
    const snap = await x.run(5);
    t.check("shift pattern: " + label + " -> " + expectMode, snap.mode === expectMode &&
            snap.machines.every(m => expectState === S.running ? [S.running, S.starved].includes(m.state) : m.state === expectState),
            snap.mode + " " + snap.machines.map(m => m.state).join(","));
  };
  await at("2026-11-01T23:00:00Z", "Monday 10:00", "run", S.running);
  await at("2026-11-02T10:45:00Z", "Monday 21:45 (cleaning)", "cleaning", S.cleaning);
  await at("2026-11-02T12:00:00Z", "Monday 23:00", "off", S.idle);
  await at("2026-11-06T23:00:00Z", "Saturday 10:00", "off", S.idle);

  // --- changeover ------------------------------------------------------------------------------------------
  sim = await start(makeLine(null, true));
  await sim.run(60);
  await sim.cmd({ cmd: "product", sku: "mix500" });
  s = await sim.run(60);
  t.check("product change: every machine in setup during the changeover", s.mode === "setup" && s.machines.every(m => m.state === S.setup));
  s = await sim.run(25 * 60);
  t.check("after the changeover (20 min ± 20 %): running mix500, filler set to 80 cartons/min",
          s.mode === "run" && s.sku === "mix500" && by(s, "filler").speed_setpoint === 80, s.mode + " " + by(s, "filler").speed_setpoint);

  // a changeover of a given length (control panel), at the line.json speed
  const sim2 = await start(makeLine());
  await sim2.run(30);
  await sim2.cmd({ cmd: "product", sku: "mix500", minutes: 2 });
  let s2 = await sim2.run(110);
  t.check("changeover of 2 minutes from the panel: still in setup after 1 min 50 s", s2.mode === "setup" && s2.sku === "mix500", s2.mode);
  s2 = await sim2.run(20);
  t.check("... running mix500 after 2 minutes, filler set to 77.6 cartons/min (97 % of 80)",
          s2.mode === "run" && by(s2, "filler").speed_setpoint === 77.6, s2.mode + " " + by(s2, "filler").speed_setpoint);
  // line.json read again (a flow restart): the product stays
  await sim2.cmd({ cmd: "product", sku: "mix150", minutes: 5 });
  await sim2.run(10);
  await sim2.reload(makeLine());
  s2 = await sim2.run(5);
  t.check("line.json read again: product mix150 and its changeover are kept", s2.sku === "mix150" && s2.mode === "setup", s2.sku + " " + s2.mode);

  // --- pause: frozen values, heartbeat stopped (ADR-0025) ---------------------------------------------------------
  const hb = s.heartbeat;
  await sim.cmd({ cmd: "pause" });
  const quiet = [];
  for (let i = 0; i < 50; i++) quiet.push(await sim.tick());
  t.check("paused: nothing goes to the simulated PLCs (values and heartbeat freeze)", quiet.every(x => x === null || x[0] === null));
  const pausedPanels = quiet.filter(x => x && x[1]).map(x => x[1].payload);
  t.check("paused: the control panel still gets a message every second, saying paused",
          pausedPanels.length >= 4 && pausedPanels.length <= 6 && pausedPanels.every(p => p.paused === true), pausedPanels.length);
  await sim.cmd({ cmd: "resume" });
  s = await sim.run(3);
  t.check("resumed: heartbeat moves again", s.heartbeat > hb && s.heartbeat <= hb + 4, hb + " -> " + s.heartbeat);

  // --- commands ----------------------------------------------------------------------------------------------
  await sim.cmd({ cmd: "set", slot: 2, key: "speedPct", value: 90 });
  s = await sim.run(1);
  t.check("set: filler speed 90 % -> setpoint 72 cartons/min for mix500", by(s, "filler").speed_setpoint === 72, by(s, "filler").speed_setpoint);
  await sim.cmd({ cmd: "stop" });
  s = await sim.run(1);
  t.check("stop: the line is idle", s.mode === "off" && s.machines.every(m => m.state === S.idle));

  // --- control panel: feed, presets, command filter ---------------------------------------------------
  sim = await start(makeLine());
  await sim.run(60);
  const fed = sim.panels;
  const p = fed[fed.length - 1];
  t.check("panel fed once a second (60 in a minute) with settings, products, presets and this hour's output",
          fed.length >= 59 && fed.length <= 61 && p.machines[1].settings.speedPct === 97 && p.products.length === 3 &&
          p.presets.map(x => x.name).join() === "line,good,typical,bad" && p.hour && p.hour.good > 0 && p.lineOutput === "closer",
          fed.length + " messages; " + JSON.stringify(p.hour));
  await sim.cmd({ cmd: "preset", name: "bad" });
  s = await sim.run(1);
  const pb = sim.panels[sim.panels.length - 1], base = makeLine();
  t.check("preset bad: MTBF x0.33, MTTR x1.8, jams x3.5, filler at 90 %",
          Math.abs(pb.machines[1].settings.mtbfH - base.machines[1].mtbfH * 0.33) < 0.1 &&
          Math.abs(pb.machines[1].settings.mttrMin - base.machines[1].mttrMin * 1.8) < 0.1 &&
          Math.abs(pb.machines[0].settings.jamsPerH - base.machines[0].jamsPerH * 3.5) < 0.1 &&
          pb.machines[1].settings.speedPct === 90 && pb.preset === "bad", JSON.stringify(pb.machines[1].settings));
  await sim.cmd({ cmd: "preset", name: "line" });
  s = await sim.run(1);
  const pl = sim.panels[sim.panels.length - 1];
  t.check("preset 'as in line.json' restores the file's values", pl.machines[1].settings.mtbfH === base.machines[1].mtbfH &&
          pl.machines[1].settings.speedPct === base.machines[1].speedPct, JSON.stringify(pl.machines[1].settings));
  await sim.cmd({ cmd: "set", slot: 3, key: "mtbfH", value: 2 });
  s = await sim.run(1);
  t.check("a value set by hand shows the preset as custom", sim.panels[sim.panels.length - 1].preset === "custom");

  // New run: counters, conveyors, breakdowns and changeover cleared; product and settings kept
  await sim.cmd({ cmd: "product", sku: "mix150", minutes: 30 });
  await sim.cmd({ cmd: "break", slot: 4, hold: true });
  await sim.cmd({ cmd: "stop" });
  s = await sim.run(2);
  await sim.cmd({ cmd: "newrun" });
  s = await sim.run(0.1);                              // one tick: nothing made yet
  t.check("New run: every counter 0, conveyors empty, no fault, line running, product mix150 and the custom MTBF kept",
          s.machines.every(m => m.count_in === 0 && m.count_good === 0 && m.count_reject === 0 && m.buffer === 0 && m.fault_code === 0) &&
          s.mode === "run" && s.sku === "mix150" && sim.panels[sim.panels.length - 1].machines[2].settings.mtbfH === 2,
          s.mode + " " + s.sku + " " + s.machines.map(m => m.count_good + "/" + m.buffer + "/" + m.fault_code).join(" "));
  s = await sim.run(60);
  t.check("... and production starts again from 0", by(s, "filler").count_good > 50 && by(s, "filler").count_good < 110, by(s, "filler").count_good);

  const cmds = loadFunction(flow, "linesim_cmds");
  const okCmd = await cmds.run({ payload: { cmd: "break", slot: 2 } });
  const newRun = await cmds.run({ payload: { cmd: "newrun" } });
  const badMin = await cmds.run({ payload: { cmd: "product", sku: "mix500", minutes: "-1" } });
  const goodMin = await cmds.run({ payload: { cmd: "product", sku: "mix500", minutes: "2" } });
  const badCmd = await cmds.run({ payload: { cmd: "format_disk" } });
  const badSet = await cmds.run({ payload: { cmd: "set", slot: 2, key: "mtbfH", value: "-3" } });
  const goodSet = await cmds.run({ payload: { cmd: "set", slot: 2, key: "mtbfH", value: "4.5" } });
  t.check("panel commands: known commands pass as topic cmd; unknown commands and negative numbers are refused",
          okCmd && okCmd.topic === "cmd" && newRun && newRun.payload.cmd === "newrun" && badCmd === null && badSet === null && goodSet.payload.value === 4.5 &&
          badMin === null && goodMin.payload.minutes === 2);
};

// Unit tests for the operator screens (step 3a.8, ADR-0027, ADR-0028),
// flows/ofm-screens.json: the hub keeps live values and sessions per
// browser, refuses actions without a sign-in, signs out after the idle time
// and when the person signs in elsewhere; the database node calls only the
// functions of migration 018; the subscriptions follow the model. No
// database or broker needed.
"use strict";
const path = require("path");
const { ROOT } = require("../lib/harness");
const { loadFlow, loadFunction } = require("../lib/functions");

const flow = loadFlow(path.join(ROOT, "flows", "ofm-screens.json"));
const L = "acme/melbourne/packing/packline01";
const LINE = {
  id: 7, name: "packline01", displayName: "Packing line 1", topic: L, constraintMachineId: 2, outputMachineId: 4,
  orderRequired: true, minorStopS: 300,
  machines: [
    { id: 1, name: "erector", displayName: "Carton erector", topic: L + "/erector", faultTopic: L + "/erector/fault_code", isConstraint: false, isOutput: false },
    { id: 2, name: "filler", displayName: "Filler", topic: L + "/filler", faultTopic: null, isConstraint: true, isOutput: false }],
  reasons: [{ code: "erector_glue", displayName: "Erector: glue", machineId: 1, lossCategoryId: 9, lossCategory: "Breakdowns" },
            { code: "meal_break", displayName: "Meal break", machineId: null, lossCategoryId: 7, lossCategory: "Other planned downtime" }],
  products: [{ sku: "mix250", name: "Assorted 250 g", ratePerHour: 6000 }],
  plannedOrders: [{ id: 41, woNumber: "WO-41", sku: "mix250", productName: "Assorted 250 g", plannedQty: 1000, plannedStart: null }]
};
const STOP = { machineId: 1, machineName: "Carton erector", eventTs: "2026-11-09 05:00:00.123+00", eventMs: 1, state: "fault",
               faultCode: 999, fromMs: 1, uncodedS: 420, stopS: 420 };
const A = { socketId: "browser-a", socketIp: "10.0.0.5" }, B = { socketId: "browser-b" };

module.exports.run = async function (t) {
  const realNow = Date.now;
  let clock = Date.UTC(2026, 10, 9, 0, 0, 0);
  Date.now = () => clock;
  try {
    const hub = loadFunction(flow, "ofm_sc_hub", { env: { OFM_SCREEN_IDLE_MINUTES: "5" } });
    const toA = out => (out && out[0] || []).filter(m => m._client && m._client.socketId === A.socketId);
    const notices = out => toA(out).filter(m => m.topic === "notice").map(m => m.payload.text);

    let out = await hub.run({ topic: "model", payload: [LINE] });
    t.check("model: subscribes to each line's work order and KPIs, each machine's state and fault code",
      out[2] && out[2].payload.join() === [L + "/erector/fault_code", L + "/erector/state", L + "/filler/state", L + "/kpi/+", L + "/workorder"].join());
    await hub.run({ topic: "stops", payload: { 7: [STOP] } });
    await hub.run({ topic: L + "/erector/state", payload: { v: "fault", ts: clock - 5000, q: "good", tss: "device" } });
    await hub.run({ topic: L + "/kpi/day", payload: '{"oee":0.61,"good":1200}' });
    await hub.run({ topic: L + "/workorder", payload: { active: true, workOrderId: 40, woNumber: "WO-40", sku: "mix250", plannedQty: 500, changeover: true } });
    out = await hub.run({ topic: "tick" });
    const pic = out[0].find(m => m.topic === "picture" && !m._client);
    const line = pic && pic.payload.lines[0];
    t.check("every second, every screen gets the picture: states, fault codes, work order, KPIs, stops to code",
      line && line.machines[0].state.v === "fault" && line.kpi.day.oee === 0.61 && line.workorder.woNumber === "WO-40" &&
      line.stops.length === 1 && line.machines[1].fault === null);
    await hub.run({ topic: L + "/kpi/day", payload: "" });
    out = await hub.run({ topic: "tick" });
    t.check("a cleared topic (empty retained message) disappears from the picture", out[0][0].payload.lines[0].kpi.day === null);

    out = await hub.run({ _client: A, payload: { cmd: "hello" } });
    t.check("a new browser gets its session (not signed in) and the picture, for it alone",
      toA(out).length === 2 && toA(out)[0].payload.signedIn === false && out[0].every(m => m._client === A));

    out = await hub.run({ _client: A, payload: { cmd: "startnew", lineId: 7, sku: "mix250", qty: 100 } });
    t.check("an action without a sign-in: refused, nothing sent to the database, the screen asks for a sign-in",
      out[1] === null && toA(out).some(m => m.topic === "session" && m.payload.why === "required") && notices(out).join().includes("Sign in first"));

    out = await hub.run({ _client: A, payload: { cmd: "signin", employeeNo: " 1001 ", pin: "2468" } });
    t.check("sign-in goes to the database with the browser, the trimmed number and the screen's address",
      out[1] && out[1][0].topic === "signin" && out[1][0].req.employeeNo === "1001" && out[1][0].req.socketId === "browser-a" &&
      out[1][0].req.screen === "10.0.0.5");
    out = await hub.run({ topic: "result", req: { socketId: "browser-a", cmd: "signin", employeeNo: "1001" }, payload: { result: "wrong_pin" } });
    t.check("wrong PIN: one message for unknown number and wrong PIN alike; not signed in",
      notices(out).join() === "Wrong employee number or PIN." && !hub.context.st.sessions["browser-a"]);
    out = await hub.run({ topic: "result", req: { socketId: "browser-a", cmd: "signin", employeeNo: "1001" },
                          payload: { result: "locked", retry_at: clock + 600000 } });
    t.check("locked: says when to try again", /Too many wrong PINs: try again at \d\d:\d\d/.test(notices(out).join()));
    out = await hub.run({ topic: "result", req: { socketId: "browser-a", cmd: "signin", employeeNo: "1001" }, payload: { result: "no_pin" } });
    t.check("no PIN yet: the screen asks the person to choose one",
      toA(out).some(m => m.topic === "session" && m.payload.choosePin === true && m.payload.employeeNo === "1001"));
    out = await hub.run({ _client: A, payload: { cmd: "setpin", employeeNo: "1001", pin: "12" } });
    t.check("a new PIN of fewer than 4 digits is refused on the screen already", out[1] === null && notices(out).join().includes("4 to 8 digits"));
    out = await hub.run({ topic: "result", req: { socketId: "browser-a", cmd: "setpin", employeeNo: "1001" },
                          payload: { result: "pin_set", person_id: 22, display_name: "Alex Demo" } });
    const sa = toA(out).find(m => m.topic === "session");
    t.check("PIN chosen: signed in on this browser, for 5 minutes untouched",
      sa && sa.payload.signedIn && sa.payload.name === "Alex Demo" && sa.payload.expiresAt === clock + 300000);

    out = await hub.run({ _client: A, payload: { cmd: "startnew", lineId: 7, sku: "mix250", qty: 100 } });
    t.check("signed in: the action goes to the database as that person",
      out[1] && out[1][0].topic === "action" && out[1][0].req.personId === 22 && out[1][0].req.cmd === "startnew" && out[1][0].req.qty === 100);
    out = await hub.run({ _client: A, payload: { cmd: "startnew", lineId: 7, sku: "nope", qty: 100 } });
    t.check("a product without a rated speed on the line is refused before the database", out[1] === null);
    out = await hub.run({ _client: A, payload: { cmd: "start", lineId: 7, workOrderId: 41 } });
    t.check("start a planned order of the line", out[1] && out[1][0].req.workOrderId === 41);
    out = await hub.run({ _client: A, payload: { cmd: "complete", lineId: 7, workOrderId: 39 } });
    t.check("complete: only the order running now; the refusal names the action", out[1] === null && notices(out).join().includes("not running") &&
      toA(out).find(m => m.topic === "notice").payload.cmd === "complete");
    out = await hub.run({ _client: A, payload: { cmd: "changeoverdone", lineId: 7, workOrderId: 40 } });
    t.check("changeover done for the running order", out[1] && out[1][0].req.cmd === "changeoverdone" && out[1][0].req.workOrderId === 40);
    out = await hub.run({ _client: A, payload: { cmd: "code", lineId: 7, machineId: 2, eventTs: STOP.eventTs, reasonCode: "erector_glue" } });
    t.check("code: a reason for another machine, or a stop not in the list, is refused", out[1] === null);
    out = await hub.run({ _client: A, payload: { cmd: "code", lineId: 7, machineId: 1, eventTs: STOP.eventTs, reasonCode: "erector_glue", comment: "glue gun" } });
    t.check("code: the stop's exact event time (as text) and the reason go to the database",
      out[1] && out[1][0].req.eventTs === STOP.eventTs && out[1][0].req.reasonCode === "erector_glue" && out[1][0].req.comment === "glue gun");
    out = await hub.run({ topic: "result", req: { socketId: "browser-a", cmd: "code" }, payload: {} });
    t.check("the result goes to that browser only, naming the action it answers (the dialog waits for it)",
      notices(out).join() === "Stop coded." && out[0].every(m => m._client.socketId === "browser-a") && toA(out)[0].payload.cmd === "code");

    // the page's connection is re-established (Wi-Fi, a background tab): same page, new socket
    out = await hub.run({ topic: "result", req: { socketId: "page-p-1", screenId: "page-p", cmd: "signin", employeeNo: "1003" },
                          payload: { result: "ok", person_id: 23, display_name: "Chris Demo" } });
    out = await hub.run({ _client: { socketId: "page-p-2" }, payload: { cmd: "changeoverdone", lineId: 7, workOrderId: 40, screenId: "page-p" } });
    t.check("a page whose connection was re-established keeps its sign-in (sessions belong to the page, not the socket)",
      out[1] && out[1][0].req.personId === 23 && out[1][0].req.socketId === "page-p-2" && out[1][0].req.screenId === "page-p");
    out = await hub.run({ _client: { socketId: "page-q-1" }, payload: { cmd: "changeoverdone", lineId: 7, workOrderId: 40, screenId: "page-q" } });
    t.check("another page cannot use that sign-in", out[1] === null);
    await hub.run({ _client: { socketId: "page-p-2" }, payload: { cmd: "signout", screenId: "page-p" } });

    out = await hub.run({ _client: B, payload: { cmd: "complete", lineId: 7, workOrderId: 40 } });
    t.check("another browser is not signed in by someone else's sign-in", out[1] === null);

    clock += 4 * 60000;
    out = await hub.run({ _client: A, payload: { cmd: "touch" } });
    clock += 4 * 60000;
    out = await hub.run({ topic: "tick" });
    t.check("touching the screen keeps the person signed in", !!hub.context.st.sessions["browser-a"]);
    clock += 5 * 60000 + 1000;
    out = await hub.run({ topic: "tick" });
    t.check("5 minutes untouched: signed out, and the browser is told",
      !hub.context.st.sessions["browser-a"] && toA(out).some(m => m.topic === "session" && m.payload.why === "idle"));

    await hub.run({ topic: "result", req: { socketId: "browser-a", cmd: "signin", employeeNo: "1001" }, payload: { result: "ok", person_id: 22, display_name: "Alex Demo" } });
    out = await hub.run({ topic: "result", req: { socketId: "browser-b", cmd: "signin", employeeNo: "1001" }, payload: { result: "ok", person_id: 22, display_name: "Alex Demo" } });
    t.check("signing in on another screen signs the person out of the first",
      !hub.context.st.sessions["browser-a"] && !!hub.context.st.sessions["browser-b"] &&
      toA(out).some(m => m.topic === "session" && m.payload.why === "elsewhere"));
    out = await hub.run({ _client: B, payload: { cmd: "signout" } });
    t.check("sign out", !hub.context.st.sessions["browser-b"]);

    out = await hub.run({ topic: "model", payload: [] });
    t.check("a line taken away: its topics unsubscribed, its values forgotten",
      out[2].payload.length === 0 && Object.keys(hub.context.st.live).length === 0);

    // the database node: only the functions of migration 018, as ofm_screens
    const asked = [];
    let fail = null;
    class Pool {
      constructor(cfg) { this.cfg = cfg; }
      on() {}
      async query(text, params) {
        asked.push({ text, params, user: this.cfg.user });
        if (fail) { const e = new Error(fail.message); e.code = fail.code; throw e; }
        if (/fn_screen_model/.test(text)) return { rows: [{ m: [LINE] }] };
        if (/fn_screen_stops_to_code/.test(text)) return { rows: [{ machine_id: 1, machine_display_name: "Carton erector", event_ts: STOP.eventTs,
          event_ms: "1762664400123", state: "fault", fault_code: 999, from_ms: "1762664400123", uncoded_s: 420.4, stop_s: 420.4 }] };
        if (/fn_person_sign_in/.test(text)) return { rows: [{ result: "ok", person_id: 22, display_name: "Alex Demo", retry_at: null }] };
        return { rows: [{}] };
      }
    }
    const db = loadFunction(flow, "ofm_sc_db", { global: { pg: { Pool } }, env: { OFM_SCREENS_DB_PASSWORD: "x" } });
    out = await db.run({ topic: "load" });
    t.check("database: model and stops to code read as ofm_screens, through the screen functions only",
      out[0][0].topic === "model" && out[0][1].payload[7][0].eventTs === STOP.eventTs && out[0][1].payload[7][0].uncodedS === 420 &&
      asked.every(a => a.user === "ofm_screens" && /config\.fn_screen_model|hist\.fn_screen_stops_to_code/.test(a.text)));
    out = await db.run({ topic: "signin", req: { socketId: "s", cmd: "signin", employeeNo: "1001", pin: "2468", screen: "x" } });
    t.check("database: sign-in through config.fn_person_sign_in", out[0].payload.result === "ok" && /fn_person_sign_in/.test(asked[asked.length - 1].text));
    asked.length = 0;
    out = await db.run({ topic: "action", req: { socketId: "s", cmd: "code", personId: 22, machineId: 1, eventTs: STOP.eventTs, reasonCode: "x", comment: null } });
    t.check("database: an action as the person, then everything read again",
      /config\.fn_person_assign_reason\(\$1, \$2, \$3::timestamptz/.test(asked[0].text) && asked[0].params[2] === STOP.eventTs &&
      out[1] && out[1].topic === "load");
    fail = { code: "42501", message: "Alex Demo has not signed in" };
    out = await db.run({ topic: "action", req: { socketId: "s", cmd: "complete", personId: 22, workOrderId: 40 } });
    t.check("database: a refusal is shown to that browser; nothing read again", /Sign in again/.test(out[0].payload.error) && out[1] === null);

    // subscriptions
    const uns = loadFunction(flow, "ofm_sc_uns", { env: { OFM_MQTT_READER_PASSWORD: "pw" } });
    out = await uns.run({ payload: ["a/state", "b/state"] });
    t.check("UNS: connects as the read-only user, then subscribes",
      out[0][0].action === "connect" && out[0][0].broker.username === "ofm_reader" && out[0][1].action === "subscribe" && out[0][1].topic.length === 2);
    out = await uns.run({ payload: ["b/state", "c/state"] });
    t.check("UNS: only the difference is unsubscribed and subscribed",
      out[0].length === 2 && out[0][0].action === "unsubscribe" && out[0][0].topic.join() === "a/state" && out[0][1].topic[0].topic === "c/state");

    // wiring and settings
    const base = flow.find(n => n.type === "ui-base"), view = flow.find(n => n.id === "ofm_sc_view");
    t.check("the line view answers one browser at a time (ui-template accepts the client) and is at /dashboard",
      base.path === "/dashboard" && base.includeClientData === true && base.acceptsClientConfig.includes("ui-template") && view.wires[0][0] === "ofm_sc_hub");
    t.check("no password or secret in the screens' flow file",
      !/password"\s*:\s*"[^"]/i.test(JSON.stringify(flow)) && flow.filter(n => n.type === "mqtt-broker").every(n => !n.credentials));
  } finally {
    Date.now = realNow;
  }
};

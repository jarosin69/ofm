// Live stack: the simulated packing line (ADR-0023, step 3a.1), when it runs
// (COMPOSE_PROFILES contains "demo"). Reads every simulated PLC the way OFM
// will: one OPC UA server per machine, namespace urn:ofm:linesim:m<slot>,
// nine signals, each Good; the heartbeat moves; the state is a valid code.
// Skipped when the simulator is not running.
"use strict";
const path = require("path");
const { ROOT, readJson, fromNodeRed } = require("../lib/harness");

const SIGNALS = ["State", "FaultCode", "CountIn", "CountGood", "CountReject", "Speed", "SpeedSetpoint", "Heartbeat", "ProcessValue"];
const HOST = process.env.OFM_TEST_LINESIM_HOST || "linesim";

module.exports.run = async function (t) {
  const opcua = fromNodeRed("node-opcua");
  const line = readJson(path.join(ROOT, "demo", "packing-line", "line.json"));
  const machines = line.machines.filter(m => m.enabled !== false);

  const open = async slot => {
    const client = opcua.OPCUAClient.create({
      endpointMustExist: false, securityMode: opcua.MessageSecurityMode.None, securityPolicy: opcua.SecurityPolicy.None,
      connectionStrategy: { maxRetry: 0, initialDelay: 500, maxDelay: 1000 }
    });
    await client.connect("opc.tcp://" + HOST + ":" + (4840 + slot));
    return { client, session: await client.createSession() };
  };

  let first;
  try {
    first = await open(machines[0].slot);
  } catch (e) {
    t.skip("simulated packing line", "not running - add demo to COMPOSE_PROFILES in .env, then docker compose up -d");
    return;
  }
  await first.session.close();
  await first.client.disconnect();

  for (const m of machines) {
    let c;
    try {
      c = await open(m.slot);
    } catch (e) {
      t.check(m.name + ": simulated PLC answers on port " + (4840 + m.slot), false, e.message);
      continue;
    }
    try {
      const ns = (await c.session.readNamespaceArray()).indexOf("urn:ofm:linesim:m" + m.slot);
      const read = async () => c.session.read(SIGNALS.map(s => ({ nodeId: "ns=" + ns + ";s=" + s, attributeId: opcua.AttributeIds.Value })));
      const a = await read();
      await new Promise(r => setTimeout(r, 2500));
      const b = await read();
      const v = name => b[SIGNALS.indexOf(name)].value.value;
      t.check(m.name + " (port " + (4840 + m.slot) + "): namespace urn:ofm:linesim:m" + m.slot + ", nine signals, all Good",
              ns > 0 && b.every(d => d.statusCode.name === "Good"),
              "namespace " + ns + "; " + b.map((d, i) => SIGNALS[i] + " " + d.statusCode.name).join(", "));
      t.check(m.name + ": heartbeat moves and the state is a valid code",
              v("Heartbeat") > a[SIGNALS.indexOf("Heartbeat")].value.value && v("State") >= 1 && v("State") <= 8,
              "heartbeat " + a[SIGNALS.indexOf("Heartbeat")].value.value + " -> " + v("Heartbeat") + ", state " + v("State"));
      t.note(m.name + ": state " + v("State") + ", fault " + v("FaultCode") + ", good " + v("CountGood") + ", speed " + v("Speed") + "/min");
    } finally {
      await c.session.close();
      await c.client.disconnect();
    }
  }
};

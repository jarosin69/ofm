// Live stack: encryption (ADR-0019, step 2.7). Checks the entrances other
// computers use - MQTT over TLS on 8883 and HTTPS through the proxy - the way
// a careful client would: the server must prove itself with a certificate
// signed by OFM's certificate authority (deploy/certs/ofm-ca.crt) and named
// for the address used. Reads the public certificates from the "certs"
// volume, mounted read-only.
"use strict";
const fs = require("fs"), path = require("path"), tls = require("tls"), https = require("https"), http = require("http");
const { X509Certificate } = require("crypto");
const { ROOT, fromNodeRed, stack } = require("../lib/harness");

const DAY = 86400000;

module.exports.run = async function (t) {
  // --- 1. the certificates -------------------------------------------------------------
  let ca, server, source;
  try {
    ca = fs.readFileSync(path.join(stack.certsDir, "ca.crt"));
    server = new X509Certificate(fs.readFileSync(path.join(stack.certsDir, "server.crt")));
    source = String(fs.readFileSync(path.join(stack.certsDir, "source"))).trim();
  } catch (e) {
    t.check("TLS certificates exist (certs volume)", false,
            e.message + " - did the certs service run? docker compose logs certs");
    return;
  }
  const caCert = new X509Certificate(ca);
  t.note("certificate " + (source === "imported" ? "from plant IT" : "made by OFM") + ", valid until " +
         new Date(server.validTo).toISOString().slice(0, 10));
  t.check("the server certificate is signed by the certificate authority", server.verify(caCert.publicKey));
  const daysLeft = Math.floor((new Date(server.validTo) - Date.now()) / DAY);
  t.check("the server certificate is valid for more than 30 days (" + daysLeft + " left)", daysLeft > 30,
          source === "imported" ? "ask plant IT for a new certificate (deploy/README.md)"
                                : "docker compose up -d renews it; then docker compose restart mosquitto proxy");
  const isIp = n => /^[0-9.]+$/.test(n) || n.includes(":");
  const covers = n => isIp(n) ? server.checkIP(n) !== undefined : server.checkHost(n) !== undefined;
  const wanted = (source === "imported" ? [] : ["localhost", "127.0.0.1", "mosquitto", "proxy"]).concat(stack.tlsNames);
  const missing = wanted.filter(n => !covers(n));
  t.check("the certificate covers every name clients use (" + wanted.join(", ") + ")", missing.length === 0,
          "missing: " + missing.join(", ") + " - set OFM_TLS_NAMES in .env, docker compose up -d, docker compose restart mosquitto proxy");
  let exported = null;
  try { exported = fs.readFileSync(path.join(ROOT, "deploy", "certs", "ofm-ca.crt")); } catch (e) { /* checked below */ }
  t.check("deploy/certs/ofm-ca.crt, the file for client computers, is the authority in use",
          exported !== null && new X509Certificate(exported).fingerprint256 === caCert.fingerprint256,
          exported === null ? "file missing - docker compose up -d writes it" : "it differs - docker compose up -d rewrites it");

  // A certificate from plant IT names the server, not the Compose services:
  // check it against the server's first name, as a client computer would.
  const identity = service => source === "imported" && stack.tlsNames[0] ? stack.tlsNames[0] : service;
  const tlsOptions = service => ({
    ca, rejectUnauthorized: true,
    checkServerIdentity: (host, cert) => tls.checkServerIdentity(identity(service), cert)
  });

  // --- 2. MQTT over TLS ----------------------------------------------------------------------
  const mqtt = fromNodeRed("mqtt");
  const mqttHost = new URL(stack.mqttsUrl).hostname;
  const tryMqtt = (password, extra) => new Promise(resolve => {
    const client = mqtt.connect(stack.mqttsUrl, Object.assign({
      username: "ofm_reader", password, protocolVersion: 5, reconnectPeriod: 0, connectTimeout: 5000,
      clientId: "ofm-test-tls-" + Math.random().toString(16).slice(2, 10)
    }, extra));
    let done = false;
    const finish = r => { if (done) return; done = true; clearTimeout(timer); client.end(true); resolve(r); };
    const timer = setTimeout(() => finish({ error: "no answer within 6 s" }), 6000);
    client.on("error", e => finish({ error: e.message }));
    client.on("connect", () => {
      const topic = "ofm/_system/runtime/" + stack.runtimeName;
      client.on("message", (tp, buf) => finish({ ok: true, payload: buf.toString() }));
      client.subscribe(topic, { qos: 0 });
    });
  });
  const good = await tryMqtt(process.env.OFM_MQTT_READER_PASSWORD, tlsOptions(mqttHost));
  t.check("MQTT over TLS (8883): certificate trusted, ofm_reader logs in, the runtime's status arrives",
          good.ok === true && good.payload.includes("online"), good.error || good.payload);
  const wrongPw = await tryMqtt("not-the-password", tlsOptions(mqttHost));
  t.check("MQTT over TLS: a wrong password is refused", !wrongPw.ok, "connected with a wrong password");
  const untrusting = await tryMqtt(process.env.OFM_MQTT_READER_PASSWORD, { rejectUnauthorized: true });
  t.check("MQTT over TLS: a client that does not trust OFM's authority is refused (it is not some other certificate)",
          !untrusting.ok && /certificate|self.signed|issuer/i.test(untrusting.error || ""), untrusting.error || "connected");

  // --- 3. HTTPS through the proxy ------------------------------------------------------------
  const get = (mod, port, urlPath, options) => new Promise(resolve => {
    const req = mod.get(Object.assign({ host: stack.proxyHost, port, path: urlPath, timeout: 5000 }, options), res => {
      res.resume();
      res.on("end", () => resolve({ status: res.statusCode, location: res.headers.location }));
    });
    req.on("timeout", () => req.destroy(new Error("no answer within 5 s")));
    req.on("error", e => resolve({ error: e.message }));
  });
  const pages = [["Grafana", 3000, "/api/health", s => s === 200],
                 ["Mathesar", 8080, "/", s => s < 400],
                 ["Node-RED editor", 1880, "/", s => s < 400],
                 ["Line view", 1882, "/dashboard/line", s => s === 200]];      // operator screens (step 3a.8)
  for (const [name, port, urlPath, ok] of pages) {
    const r = await get(https, port, urlPath, tlsOptions(stack.proxyHost));
    t.check(name + " over HTTPS (port " + port + "): certificate trusted, page answers",
            r.status !== undefined && ok(r.status), r.error || "HTTP " + r.status + (r.status === 502 ? " - " + name + " itself is not running" : ""));
  }
  const plain = await get(http, 3000, "/login", {});
  t.check("plain http:// on an HTTPS port is redirected to https://",
          plain.status === 308 && /^https:\/\//.test(plain.location || ""), plain.error || "HTTP " + plain.status + " " + (plain.location || ""));
};

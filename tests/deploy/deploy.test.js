// Deployment rules, read from the files in deploy/ (no stack needed):
// - every image is pinned to a version, so a bundle and an upgrade are
//   reproducible (step 2.8); OFM's own image is built, never pulled;
// - only the encrypted entrances may be opened to the network, the database
//   never (ADR-0019);
// - no password or secret is written into docker-compose.yml (.env only);
// - no component contacts the internet by itself (step 2.8);
// - the offline bundle contains every image the installation uses.
"use strict";
const fs = require("fs"), path = require("path");
const { ROOT, fromNodeRed } = require("../lib/harness");

const read = (...p) => fs.readFileSync(path.join(ROOT, ...p), "utf8");

module.exports.run = async function (t) {
  const yaml = fromNodeRed("js-yaml");
  const compose = yaml.load(read("deploy", "docker-compose.yml"));
  const services = compose.services;
  const env = s => {
    const e = services[s].environment || {};
    return Array.isArray(e) ? Object.fromEntries(e.map(x => x.split(/=(.*)/s).slice(0, 2))) : e;
  };

  // --- images ---------------------------------------------------------------------------
  const unpinned = Object.entries(services)
    .filter(([, s]) => !/:[0-9][^:]*$/.test(s.image || "") || /:latest$/.test(s.image || ""))
    .map(([n, s]) => n + " (" + (s.image || "no image") + ")");
  t.check("every service's image is pinned to a version", unpinned.length === 0, unpinned.join(", "));
  const own = Object.entries(services).filter(([, s]) => /^ofm\//.test(s.image));
  t.check("OFM's own image is never pulled from the internet (pull_policy: never)",
          own.length > 0 && own.every(([, s]) => s.pull_policy === "never"),
          own.filter(([, s]) => s.pull_policy !== "never").map(([n]) => n).join(", "));
  t.check("OFM's own image is built from deploy/nodered",
          own.some(([, s]) => s.build === "./nodered" || (s.build && s.build.context === "./nodered")));

  // --- ports (ADR-0019) -------------------------------------------------------------------
  const NETWORK = { mosquitto: ["8883"], proxy: ["3000", "8080", "1880"] };
  const problems = [];
  for (const [name, s] of Object.entries(services)) {
    for (const p of s.ports || []) {
      const text = typeof p === "string" ? p : (p.host_ip || "") + ":" + p.published + ":" + p.target;
      const m = /^(.*):(\d+):(\d+)(\/\w+)?$/.exec(text);
      const host = m ? m[1] : "";
      const published = m ? m[2] : "?";
      if (host === "127.0.0.1") continue;
      if (host === "${OFM_LISTEN_ADDRESS:-127.0.0.1}" && (NETWORK[name] || []).includes(published)) continue;
      problems.push(name + " " + text);
    }
  }
  t.check("only the encrypted ports (MQTT 8883, HTTPS 3000/8080/1880) may be opened to the network; every other port stays on 127.0.0.1",
          problems.length === 0, problems.join(", "));
  t.check("the default listen address is this computer only (127.0.0.1)",
          /OFM_LISTEN_ADDRESS=127\.0\.0\.1/.test(read("deploy", ".env.example")) &&
          /add OFM_LISTEN_ADDRESS\s+127\.0\.0\.1/.test(read("deploy", "make-env.sh")));

  // --- secrets ------------------------------------------------------------------------------
  const literal = [];
  for (const name of Object.keys(services)) {
    for (const [k, v] of Object.entries(env(name))) {
      if (/PASSWORD|SECRET/.test(k) && !/^\$\{[A-Z0-9_]+(:?[?-][^}]*)?\}$/.test(String(v))) literal.push(name + "." + k);
    }
  }
  t.check("no password or secret written into docker-compose.yml (all come from .env)", literal.length === 0, literal.join(", "));

  // --- no outbound connections (step 2.8) ---------------------------------------------------
  for (const db of ["timescaledb", "mathesar-db"]) {
    t.check(db + ": TimescaleDB usage reports off (timescaledb.telemetry_level=off)",
            JSON.stringify(services[db].command || []).includes("timescaledb.telemetry_level=off"));
  }
  const g = env("grafana");
  t.check("Grafana: usage reports, update checks and news feed off",
          g.GF_ANALYTICS_REPORTING_ENABLED === "false" && g.GF_ANALYTICS_CHECK_FOR_UPDATES === "false" &&
          g.GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES === "false" && g.GF_NEWS_NEWS_FEED_ENABLED === "false",
          ["GF_ANALYTICS_REPORTING_ENABLED", "GF_ANALYTICS_CHECK_FOR_UPDATES", "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES",
           "GF_NEWS_NEWS_FEED_ENABLED"].map(k => k + "=" + g[k]).join(", "));
  t.check("Node-RED: telemetry and update notification off (settings.js)",
          /telemetry:\s*\{\s*enabled:\s*false,\s*updateNotification:\s*false/.test(read("deploy", "nodered", "settings.js")));
  t.check("Caddy: obtains no certificates from the internet (auto_https off)",
          /^\s*auto_https off\s*$/m.test(read("deploy", "proxy", "Caddyfile")));

  // --- the offline bundle ---------------------------------------------------------------------
  const bundle = read("tools", "make-bundle.ps1");
  const extra = (/\$ExtraImages = @\(([^)]*)\)/.exec(bundle) || [, ""])[1];
  const envImage = (/docker run --rm [^\n]*?\s(alpine:[0-9.]+)\s+sh make-env\.sh/.exec(read("deploy", "README.md")) || [])[1];
  t.check("the bundle includes the image that runs make-env.sh (" + envImage + ")",
          Boolean(envImage) && extra.includes('"' + envImage + '"'), "README uses " + envImage + ", bundle adds " + extra);
  t.check("the bundle reads its image list from docker-compose.yml (nothing to keep in step by hand)",
          bundle.includes('"docker-compose.yml"') && /\^\\s\*image:/.test(bundle));
  t.check("the bundle holds committed files only (git archive), never .env or keys",
          /"archive",[^\n]*"HEAD"/.test(bundle) && !/Copy-Item[^\n]*\.env/.test(bundle));
};

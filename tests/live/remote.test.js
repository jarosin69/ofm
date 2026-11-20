// Live stack: remote access (ADR-0032). Only when COMPOSE_PROFILES contains
// "remote": the tunnel container is connected to Cloudflare (its readiness
// endpoint on the internal network answers 200), the public names are set,
// and OFM's certificate covers the name the tunnel expects ("proxy"). What
// Cloudflare does in front (routes, paths, email-code login) is checked by
// hand (tests/README.md, RA1-RA6).
"use strict";
const http = require("http");

const get = url => new Promise(resolve => {
  const req = http.get(url, { timeout: 4000 }, res => { res.resume(); resolve(res.statusCode); });
  req.on("timeout", () => { req.destroy(); resolve("timeout"); });
  req.on("error", e => resolve(e.code || e.message));
});

module.exports.run = async function (t) {
  const profiles = (process.env.COMPOSE_PROFILES || "").split(",").map(x => x.trim());
  if (!profiles.includes("remote")) {
    t.skip("remote access (ADR-0032)", "not switched on: COMPOSE_PROFILES has no 'remote'");
    return;
  }
  const domain = (process.env.OFM_PUBLIC_DOMAIN || "").trim();
  t.check("remote access: OFM_PUBLIC_DOMAIN is set in .env (" + (domain || "empty") + ")",
          /^[a-z0-9-]+(\.[a-z0-9-]+)+$/.test(domain),
          "set e.g. OFM_PUBLIC_DOMAIN=example.com, then docker compose up -d");
  const ready = await get("http://cloudflared:20241/ready");
  t.check("remote access: the tunnel is connected to Cloudflare (cloudflared ready: " + ready + ")", ready === 200,
          "docker compose logs cloudflared --tail 30: an empty or wrong CLOUDFLARE_TUNNEL_TOKEN, or no internet");
};

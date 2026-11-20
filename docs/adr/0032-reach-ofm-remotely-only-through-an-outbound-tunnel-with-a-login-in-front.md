# ADR-0032: Reach OFM remotely only through an outbound tunnel with a login in front

- **Status:** Accepted
- **Date:** 2026-11-20
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** security, deployment, demo

## Context

The management demo (STATUS step C0) is given over Teams from the demo kit:
OFM on a small industrial PC at home, shown to a regional and a global team
from another place. The pages must be reachable from outside, without
exposing the PLCs or OFM's editors, and in a way that can be explained to a
security-minded audience. The same question will come back at a plant:
"how can I look at OFM from the office or from home?"

## Decision

1. **Only an outbound tunnel.** Remote access goes through Cloudflare Tunnel:
   the `cloudflared` container opens a connection from OFM to Cloudflare.
   No port is opened on the server, the router or a firewall, and no VPN is
   given to viewers. It runs only when asked for (`COMPOSE_PROFILES`
   containing `remote`, the tunnel's token in `.env`); without it nothing
   changes, and a plant without internet is unaffected.
2. **A login before any page.** Cloudflare Access asks for an email address
   and sends a one-time code; only listed addresses get in. Behind it, OFM's
   own logins still apply (Grafana, Mathesar, signing in on the screens).
3. **Little is published.** Public names on the domain in
   `OFM_PUBLIC_DOMAIN`: `ofm.` (line view and trend, only `/dashboard…`,
   `/trend/export` and `/ofm/…`), `grafana.`, `sim.` (the simulator's panel,
   only `/dashboard…`) and `mathesar.` (only its owner's address). The
   Node-RED editors and the broker are never published.
4. **Encrypted to the end.** The tunnel reaches the pages through OFM's
   proxy over HTTPS and checks OFM's certificate (ADR-0019): certificate
   authority pool `/certs/ca.crt`, server name `proxy`.

## Alternatives considered

1. **Port forwarding on the router.** Every page reachable by anyone who
   finds the address, protected only by OFM's own logins. Rejected.
2. **A VPN (e.g. Tailscale) for viewers.** Secure, but every viewer needs an
   app on their device, which company laptops rarely allow. Kept for
   maintenance by the owner only (SSH).
3. **Cloudflare's quick tunnels without a domain.** A random address and no
   login in front. Rejected.

## Consequences

- Answers to "is the PLC network exposed?": no inbound connection exists;
  viewers need an approved email address; PLCs and editors are not reachable.
- Cloudflare sees the traffic (it ends TLS at its edge). Acceptable for a
  demo with simulated data; for a plant, IT decides (their own remote-access
  service may replace this).
- One more container image (pinned), used only with the `remote` profile.
- Routes, paths and who may log in live in the Cloudflare dashboard, not in
  the repository; deploy README 7.8 lists them.

# ADR-0020: Run plant servers on Linux with the free Docker Engine

- **Status:** Accepted (2026-11-10)
- **Date:** 2026-11-02
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** ops

## Context

OFM is one Docker Compose stack (Overview §14). On the development laptop it
runs under Docker Desktop on Windows 11 with WSL2. Two facts about Docker
Desktop matter for a plant:

- **Licence.** Docker Desktop is free only for personal use, education,
  non-commercial open source and small businesses (fewer than 250 employees
  *and* less than US$10 million annual revenue). Professional use in a larger
  organisation needs a paid seat (Pro, Team or Business). Docker Engine
  itself (the Moby project, Apache 2.0), its command-line tool and the
  Compose plugin are free for any use.
- **It is a desktop application.** It starts when a user signs in, not when
  the computer boots, and runs the engine inside a hidden virtual machine. A
  historian that records nothing until someone logs in is not acceptable on
  a server, and Docker Desktop is not offered for Windows Server.

Nothing in OFM depends on Docker Desktop: the Compose file, scripts and tests
use only Docker Engine and Compose (no `host.docker.internal`, no Desktop
extensions). The offline bundle already has a Linux load script
(`tools/offline-load.sh`). The stack has been validated by Compose on Docker
Engine 29.8 / Compose 5.5 with stand-in images (step 2.8), but has never run
end to end with the real images on a Linux host.

## Decision

1. **Plant servers run 64-bit x86 Linux with Docker Engine** (`docker-ce`)
   and the Compose plugin, installed from Docker's own packages, on a
   distribution Docker supports. Preferred: **Ubuntu Server 26.04 LTS**
   (released April 2026, standard security updates until 2031; Docker
   supports it); 24.04 LTS is acceptable where IT already runs it. Debian
   or Red Hat Enterprise Linux are equally acceptable where plant IT
   standardises on them.
2. **OFM requires only Docker Engine and Compose.** No OFM file, script or
   instruction may depend on a Docker Desktop feature (such as
   `host.docker.internal` or Desktop's settings screens).
3. **Development computers** may use any Docker that provides the Engine
   and Compose v2: Docker Desktop where its licence allows (personal use or a
   paid seat), Rancher Desktop with its `dockerd (moby)` engine, or Docker
   Engine installed inside a WSL2 Ubuntu distribution. Jarek's laptop keeps Docker Desktop for
   development (decided 2026-11-02).
4. **Docker reaches an offline plant server** either through plant IT's own
   package mirror, or as Docker's `.deb`/`.rpm` packages copied with the
   offline bundle (decided with plant IT in step C1).

## Alternatives considered

1. **Docker Desktop with a paid subscription on a Windows server** — no
   install change, but a per-seat cost, starts only at sign-in, adds a
   hidden VM and Windows feature updates to the data path, and is not
   supported on Windows Server. Rejected for servers; kept as one option for
   laptops.
2. **Windows Server with Docker Engine inside WSL2** — avoids the licence,
   but WSL2 is designed around an interactive user; starting it at boot and
   keeping it running needs workarounds. Rejected.
3. **Podman** (free, Red Hat's default) — mostly Docker-compatible, but
   Compose behaviour, networking and volume ownership differ in details OFM
   relies on, and it is untested. Rejected for v1; revisit if a plant
   mandates RHEL without Docker.
4. **Kubernetes** — rejected in Overview §14 (operational cost not justified
   for a single-site, restart-tolerant system).

## Consequences

- Positive: no licence cost or compliance question at any plant; the server
  starts OFM at boot (`systemctl enable docker` plus the containers'
  `restart: unless-stopped`); one less virtualisation layer; the plant runs
  the same engine the tests were validated on.
- Negative / cost: plant installation needs Linux instructions (deploy
  README section 7) and someone at the plant able to operate a Linux server;
  Docker Engine has no vendor support (community only); on Linux, members of
  the `docker` group are effectively administrators of the server.
- Linux details OFM must handle, all in deploy README section 7: `flows/`
  writable by user 1000; `.env` readable by its owner only; container log
  rotation (Docker Engine's default log files grow without limit); ports
  published by Docker bypass host firewall tools such as `ufw`, so
  `OFM_LISTEN_ADDRESS` and the network firewall are the controls; Docker
  switches on IP forwarding, so a server with two network cards must be
  checked not to route between them.
- Follow-up work: a first end-to-end run on a Linux VM with the real images
  and the full test suite before the plant (step C2.1); optionally Docker's
  packages in the offline bundle (`make-bundle.ps1`).

## Notes / references

- Docker Desktop licence: https://docs.docker.com/subscription/desktop-license/
- Docker Engine install and supported distributions, Apache 2.0 licence:
  https://docs.docker.com/engine/install/
- Docker Engine 28 networking changes (FORWARD policy):
  https://www.docker.com/blog/docker-engine-28-hardening-container-networking-by-default/
- Related: Overview §14; ADR-0019 (listen address); STATUS open question 2.

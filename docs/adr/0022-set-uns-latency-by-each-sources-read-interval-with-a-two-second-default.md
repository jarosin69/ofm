# ADR-0022: Set UNS latency by each source's read interval, with a two-second default

- **Status:** Accepted (2026-11-10)
- **Date:** 2026-11-02
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** runtime, uns

## Context

Overview §3.2 set the target "UNS latency (PLC change → MQTT publish)
< 250 ms typical". The load test of step 2.9 measured what actually decides
it:

| Read settings | Delay device time → UNS |
|---|---|
| OPC UA sampling 0.5 s, publishing 1 s (example settings) | laptop: median 0.7 s, 99 % within 1.1 s; replica: median 1.3 s |
| OPC UA sampling 0.1 s, publishing 0.1 s | replica: about 0.3 s |

OFM's own share — from a value arriving in Node-RED to its publication — is
therefore small, at most about 0.2 s (inferred from the 0.1 s run; not
measured on its own). The rest is the time the source waits before sending:
an OPC UA server delivers changes once per publishing interval; S7 and
EtherNet/IP values are seen at the next poll (default 1 s) and stamped with
arrival time, so their timestamp is late by up to one poll interval too.

No consumer in OFM's v1 scope needs sub-second delivery: Grafana refreshes
every few seconds, machine states and OEE work in minutes (minor-stop
threshold 5 min), the historian files values by their timestamps, and
control stays in the PLCs (§3.1). Reading faster costs communication load on
the CPU (most on small CPUs such as the S7-1200) and, for noisy signals,
more values on the UNS and in the historian.

A separate concern is *resolution*: a signal where every value matters
(checkweigher weights for SPC) is lost between polls if it changes faster
than it is read, whatever the latency.

## Decision

1. **The target becomes two numbers** (Overview §3.2):
   - with the default read settings, 95 % of values reach the UNS within
     **2 s** of the change;
   - OFM's own processing (value received → published) stays **under
     250 ms** typical.
2. **The defaults stay:** OPC UA sampling 500 ms and publishing 1000 ms;
   S7 and EtherNet/IP polling every 1000 ms.
3. **Faster only per source, and only for a named need.** A source's
   `settings` in the model (`samplingIntervalMs`, `publishingIntervalMs`,
   `pollIntervalMs`; minimum 100 ms) are lowered where a consumer needs it,
   after checking the CPU's communication load with the PLC owner.
4. **Resolution is not solved by latency settings.** Signals whose every
   value matters get their own design when Phase 3c needs them (for example
   OPC UA with sampling at least as fast as the events, or a counter or
   buffer in the PLC).
5. **The load test checks the new target:** `MAX_DELAY_P95_S` in
   `tests/load/load.test.js` goes from 2.5 to 2.0 s.

## Alternatives considered

1. **Keep < 250 ms and default to 100 ms reads everywhere** — meets the
   number, but multiplies PLC communication load for no v1 consumer, and
   would be the first thing a PLC owner asks to undo. Rejected.
2. **Keep the 250 ms target as written** — a target every installation
   fails at default settings teaches people to ignore targets. Rejected.
3. **No latency target at all** — loses the check that OFM itself stays
   fast as it grows (more properties, Phase 3 logic). Rejected.

## Consequences

- Positive: the target matches what default installations deliver and what
  v1 consumers need; PLC owners are asked for the lightest load by default;
  OFM's own speed is still watched.
- Negative / cost: a future fast consumer (an andon light, an interlock-like
  display) must be configured per source and its owner must know to ask.
- Follow-up work: measure OFM's own share directly on a polled source at the
  plant (its timestamp is the arrival time, so the delay to the UNS is OFM's
  own); Overview §3.2 and §15 updated with this ADR.

## Notes / references

- Measurements: STATUS, Phase 2 exit check (L1) and notes on step 2.9.
- OPC UA monitored items keep up to 10 samples per publishing interval
  (`queueSize: 10`), so sampling faster than publishing loses no samples.
- Related: ADR-0003, ADR-0007, ADR-0017, ADR-0018; STATUS open question 26.

# ADR-0025: Detect frozen machine data with a heartbeat property

- **Status:** Accepted
- **Date:** 2026-11-02
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** runtime, uns

## Context

ADR-0007 makes a lost *connection* visible: the source goes offline, its
values are republished `bad`, machines become `unknown`. It cannot see data
that is reachable but no longer alive:

- an S7 CPU in STOP may still answer reads, with every value frozen
  (assumption: to confirm on the bench, drill F2 below);
- an export data block (ADR-0021) or a gateway keeps serving the last values
  after the program that fills it stopped;
- in the demo, the simulator stops while a PLC backend or its OPC UA server
  still answers (ADR-0023).

Worse, the heartbeat republish of ADR-0007 then stamps the frozen values with
the current time, as if the gateway vouched for them. A stable process and a
frozen machine look the same.

Many machines already offer a value that changes all the time: a life-bit, a
watchdog counter, the demo's `heartbeat` signal (+1 every second).

## Decision

1. **A heartbeat role.** `config.machine_property` gets a `role` column
   (Phase 3a uses it for `state`, `fault_code` and the count roles too); at
   most one property per machine has the role `heartbeat`, with a
   `heartbeat_timeout_ms` setting (default 5 000; must exceed the source's
   read interval plus the heartbeat's own period).
2. **Frozen = no change within the timeout.** The runtime's one-second check
   (ADR-0007 amendment) marks a machine *frozen* when its heartbeat value has
   not changed for `heartbeat_timeout_ms`, while its source is online.
3. **Frozen is treated like a lost source, for that machine only:**
   - every property of the machine is republished at once with its last
     value and `q: "bad"`, `tss: "gateway"`, and repeated `bad` by the
     heartbeat republish, never as good;
   - the machine gets an `unknown` state event at the later of the last
     observed heartbeat change and its last state event (as ADR-0006 does
     after a runtime outage);
   - a warning in the runtime log names the machine and the heartbeat value.
4. **Recovery.** At the next change of the heartbeat the machine is live
   again: current values are published with their own quality and the
   machine's actual state is recorded.
5. **Optional.** A machine without a heartbeat property behaves as today.
   The rule is the same for every protocol.

## Alternatives considered

1. **Rely on the source status only** — misses every case above. Rejected.
2. **A "data valid" bit set by the PLC program** — needs PLC logic, and a
   stopped program cannot clear it. Rejected.
3. **A frozen check on every value** — unchanged values are normal (a
   setpoint, a stopped line), so it would raise false alarms. Rejected.
4. **Mark frozen values `uncertain` instead of `bad`** — frozen data says
   nothing about the present, exactly like lost data; one meaning for one
   situation. Rejected.

## Consequences

- Positive: a frozen machine is visible within seconds on the UNS, in the
  historian and in OEE (as `unknown`, which counts as unaccounted, never as
  running); the demo can show it by stopping the simulator.
- Negative / cost: one more state per machine for the runtime to track; a
  heartbeat must be configured with a timeout that suits its source.
- Follow-up work: in step 3a.3 (machine states); drills F1 (simulator
  stopped, PLC backend still answering) and F2 (S7 CPU switched to STOP).

## Notes / references

- Related: ADR-0003, ADR-0006, ADR-0007, ADR-0021, ADR-0023.

## Amendments

- 2026-11-05: **As built (step 3a.3, migration 013).** Roles: `state_code`
  (the PLC's state code; `state` is the machine state topic), `fault_code`,
  `heartbeat`, `count_in`, `count_good`, `count_reject`, at most one of each
  per active machine. `heartbeat_timeout_ms` is allowed only on the heartbeat
  role, 1 s to 1 h, empty = 5 000. The check runs in the runtime's one-second
  tick (node *heartbeat, source loss and frozen data*); a heartbeat without a
  good value counts as not changing. While a machine is frozen, *normalise*
  also publishes its new values `bad` (their own quality is kept for the
  recovery). While the machine's source is offline, ADR-0007 applies instead,
  and the timeout starts again once it is back. Drill F1 passed on the local
  replica (2026-11-05): `unknown` on the UNS about 6–7 s after the simulator
  stopped, stamped with the last heartbeat change; live again about 2 s
  after it resumed. Drill F2 is in `tests/README.md` (step 3a.3).

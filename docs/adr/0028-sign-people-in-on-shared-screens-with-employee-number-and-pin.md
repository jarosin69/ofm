# ADR-0028: Sign people in on shared screens with employee number and PIN

- **Status:** Accepted
- **Date:** 2026-11-09
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** screens, security, history

## Context

Operators start and complete work orders and code stops on the line view
(ADR-0027); food-safety records (ADR-0015 decision 7) will need to show
who entered them. The screens are shared: a panel PC or tablet at the line,
used by several people in a shift, often with gloves. Individual network
logins do not suit that: a browser login stays until someone remembers to
log out, and plant IT accounts are not available to every operator. History
is keyed by ID (ADR-0004), so a name in a text column is not enough.

## Decision

1. **People.** `config.person` (employee number, name), edited in Mathesar.
   People are retired, not deleted, once they have recorded anything.
2. **PIN.** 4 to 8 digits, chosen by the person at their first sign-in.
   Only a bcrypt hash (PostgreSQL `pgcrypto`, a one-way scramble) is stored,
   in `config.person_pin`, which the runtime and Grafana cannot read. To
   reset a forgotten PIN, an administrator deletes the person's row; they
   choose a new one at their next sign-in.
3. **Lockout.** Five wrong PINs within 10 minutes (since the last good
   sign-in) lock that person for 10 minutes. The screen shows the same
   message for an unknown number and a wrong PIN. Every attempt is kept in
   `hist.person_sign_in` (append-only).
4. **Session.** A sign-in holds on that browser page only, until *Sign
   out*, 5 minutes untouched (`OFM_SCREEN_IDLE_MINUTES`), a reload, or the
   same person signing in on another screen. It survives the page's
   connection being re-established (Wi-Fi, a tab in the background): the
   page names itself with a random ID on every message. Viewing needs no sign-in; every
   action does. The database also refuses an action for a person without a
   good sign-in in the last 12 hours.
5. **Recorded by ID and name.** Work order events and reasons get a
   `person_id` column; `entered_by` / `assigned_by` keep the name as it was,
   for reading. Machine and automatic entries (`plc`, `ofm`, the
   auto-operator) have no `person_id`.
6. **One role for now.** Everyone signed in may do everything the line view
   offers. A supervisor role comes with recoding stops and food-safety
   verification.

## Alternatives considered

1. **Pick your name from a list, no PIN.** Fastest, but anyone can act as
   anyone; not acceptable for food-safety records. Rejected.
2. **Badge readers (RFID).** Best on the floor, but needs hardware at every
   screen. Later: a keyboard-wedge reader types the number into the same
   field, so this decision stays.
3. **Plant network accounts (Active Directory).** Strong, but not every
   operator has one, and shared screens would stay logged in. Rejected for
   the line view; possible for office tools later.
4. **A PIN for every action.** No session to forget, but slow with gloves
   when coding several stops. Rejected in the 3a.8 design.

## Consequences

- Positive: every order event and coded stop names a real person, by ID;
  nobody can read a PIN back; no extra hardware.
- Negative: a PIN is accountability, not strong security: anyone watching
  can see it typed. A person who never signed in can be "claimed" by whoever
  chooses their first PIN, so new people should sign in once soon after
  being added.
- Follow-up: badge readers; the supervisor role; whether sign-ins need
  keeping beyond the historian's own retention (no limit set now).

# ADR-0033: Report a period on a printable OFM page

- **Status:** Accepted
- **Date:** 2026-11-22
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** screens, kpi, reports

## Context

The line view shows this hour, today and this order; Grafana *Line OEE*
shows any period, one panel at a time. Operations and management also want
a document: last month (or any dates) with the KPIs against target and
against the previous period, the losses ranked with their share of the lost
time, the orders, the products, the shifts and the machines, handed out or
filed as a PDF. The free Grafana has no PDF export or scheduled reports
(Grafana Enterprise and Cloud only), and printing a dashboard from the
browser gives a poor layout. A month of history also made
`hist.fn_line_kpi` slow (about 8 s), and a report asks for many groups of
the same period.

## Decision

1. **A report page in the screens container.** *OFM Report* at
   `https://<server>:1882/dashboard/report`, beside the line view and the
   trend page (ADR-0027, ADR-0029): line, period (yesterday, last 7 days,
   last week, this month, last month, or two dates), comparison with the
   previous period (the month before for a month, else the same length just
   before). Viewing needs no sign-in. The line, period and comparison are in
   the page address, so a link opens the same report. Periods are worked out
   in the site's time zone, so viewers abroad get the plant's days.
2. **PDF by the browser.** The page is laid out for A4 portrait; *Save as
   PDF* opens the browser's print dialogue, which prints only the report.
   No PDF software is added to OFM.
3. **Grouped in the database, never averaged.** Migration 031 adds
   `hist.fn_report_kpi` (total, day, week, shift, order, product from one
   pass over the time ledger), `fn_report_losses` (stop reasons per machine,
   speed and quality loss, with stops, share of the lost time and OEE
   points, which add up to 100 − OEE), `fn_report_orders`,
   `fn_report_machines` and `fn_report_summary`. They group the existing
   ledger and counts; no KPI changes its definition (ADR-0008). Combining
   periods, orders or products always adds up seconds before dividing.
   `hist.fn_line_kpi` keeps its result and becomes about 30 times faster.
4. **A target per line.** `config.line.oee_target` (fraction, default 0.65),
   edited in Mathesar: the target line and colours. Display only.
5. **Limits.** The page reports at most 93 days (per week above 42 days);
   the functions refuse more than 400 days.
6. **Grafana for digging.** *Line OEE* gets the same *Top losses*, the
   fuller *Work orders* and *OEE by product*, from the same functions.

## Alternatives considered

1. **Grafana Enterprise or Cloud reporting** — real PDF and e-mail, but paid
   and, for Cloud, outside the plant. Rejected.
2. **A third-party report service (e.g. Skedler)** — another product to
   licence and run. Rejected.
3. **PDFs made on the server with a headless browser** — gives scheduled
   e-mail, but adds a large image and a mail server. Later, with step H3
   (scheduled reports), if wanted.
4. **Printing the Grafana dashboard** — no page layout, panels cut. Rejected.

## Consequences

- Positive: a monthly review document in two clicks, from any place OFM is
  reachable (also through the remote access of ADR-0032); every figure
  traceable to the same ledger as the dashboards; long Grafana periods
  are fast too.
- Negative: the PDF depends on the browser's print (Chrome and Edge tested);
  no scheduled delivery yet.
- Follow-up (step R2): shift handover mode, comparison of two chosen
  periods, changeover analysis by product pair.

## Amendments

- 2026-11-28: **No data, made-up operations (migration 032).** A period
  without any recorded state, count or order shows one notice instead of
  empty figures; time without data (state unknown) is its own chip under
  *Data quality*. `migrate test-operations [1-12]` makes up months of
  operations for the demo line before its real history (ADR-0006
  amendment), so reports and *Line OEE* can be shown with history; the
  report and Grafana's *Period shown* mark it. RP1–RP9 passed on the demo
  kit 2026-11-28.

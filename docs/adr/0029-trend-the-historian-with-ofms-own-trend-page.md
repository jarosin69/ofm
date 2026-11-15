# ADR-0029: Trend the historian with OFM's own trend page

- **Status:** Accepted
- **Date:** 2026-11-11
- **Deciders:** Jarek (OFM project, with Claude)
- **Tags:** historian, screens, trends

## Context

OFM records every historised signal (ADR-0002), compresses it after
7 days and keeps 1-minute and 1-hour averages (migration 011). What is
missing is the way engineers and supervisors use a historian every day,
in the manner of Canary Axiom: pick a few signals, choose a period, lay
them over each other or stack them, zoom, compare with last week, see
when a limit was crossed, export the values and save a picture.

Grafana could show trends, but each of these needs its own workaround:
picking signals means dashboard variables; a time shift applies to a whole
panel; limits are typed into each panel instead of coming from the model;
a picture needs an extra image-renderer container (a hidden web browser of
about 1 GB); scheduled reports exist only in the paid Enterprise edition;
annotations live in Grafana's own store under Grafana logins, not by the
OFM person who made them.

## Decision

1. **Own page.** OFM Trend is a page of the screens container (ADR-0027):
   `https://<server>:1882/dashboard/trend`, beside the line view. It draws
   with **Apache ECharts** (Apache 2.0), a chart library built into OFM's
   image and served by the screens container itself
   (`/ofm/echarts.min.js`), so it needs no internet.
2. **The historian through functions only.** The page reads the database
   as `ofm_screens`, through the functions of migration 023 and nothing
   else: `config.fn_trend_tags` (the historised numeric signals as a tree,
   with unit, range and limits), `hist.fn_trend_data`,
   `hist.fn_trend_stats`, `hist.fn_trend_export`, `hist.fn_historian_tags`.
   `ofm_reader` may call them too, for Grafana, Power BI or Python.
3. **At most about one point per pixel.** `hist.fn_trend_data` returns
   every stored value when the period holds at most four values per point
   of the chart; otherwise the minimum, average and maximum per round
   interval (1 s … 1 week), from raw values below a minute, else from the
   1-minute averages, from an hour from the 1-hour averages (local days for
   day intervals). The page draws the minimum–maximum band behind the
   average, so averaging never hides a spike. Raw values are drawn holding
   until the next value, but at most twice the signal's publish interval:
   after that the signal was silent and the line shows a gap (ADR-0007).
4. **Limits from the model.** Each property has four limits: LoLo, Lo
   (`alarm_low`), Hi (`alarm_high`) and HiHi, edited in Mathesar and
   published in `_meta`. The trend line is amber beyond Hi or Lo and red
   beyond HiHi or LoLo; the statistics give the time spent beyond each.
5. **What goes into the historian stays in the model.** The
   `is_historised` tick box of each property (Mathesar) decides; the page
   only offers historised signals and lists them with their last value,
   values in 24 hours and history since.
6. **Bookmarkable.** The chart (signals, scales, period, layout) lives in
   the page's address, so a link or a bookmark opens the same chart.
7. **Exports from the screens container.** CSV "as stored" (every value,
   local time and UTC, written to the browser as it is read, at most
   1,000,000 values) and "as shown" (the chart's intervals); PNG and JPG
   are drawn in the browser.
8. **Made-up history is marked.** A year of test history for the demo
   line (`migrate test-history`) is recorded in `hist.test_data_range`;
   every chart marks it "made-up test data", and `test-history-remove`
   deletes exactly those values.

Later steps (H2): time shift, event bands (states, orders, shifts),
annotations by signed-in person, per-person preferences, saved charts.
H3: scheduled reports, calculated pens.

## Alternatives considered

1. **Grafana.** Already in the stack and good for dashboards, which stay
   there (*Line OEE*). For ad-hoc trending see Context. Rejected for this
   purpose.
2. **A commercial historian client** (Canary Axiom, AVEVA, Ignition).
   Licensed per client or per tag, against OFM's zero-licence-cost aim.
3. **Another chart library** (uPlot, Chart.js). uPlot is faster for very
   large point counts but lacks banded areas, limit colouring and picture
   export without extra code; Chart.js is what Dashboard 2.0 used before,
   and ECharts is what it uses now (the same version is in the image).

## Consequences

- One more page in the screens container; the runtime is untouched.
- OFM's image gains one library (`echarts`), so the image tag is raised
  (`ofm/node-red:4.1.16-ofm.4`) and rebuilt once.
- Migration 023 also compresses the 1-minute and 1-hour averages after
  35 days. A year of made-up history showed them about 20 times larger
  than the compressed raw values they summarise.
- The page shows times in the browser's local time; plant PCs are set to
  the plant's time zone. CSV files carry the site's local time and UTC.

# ETL (Python + PostgreSQL)

Launch from the repository root after adding the step 4.2 files:

```bash
docker compose build etl
docker compose run --rm etl
```

The Python module `etl.run` orchestrates set-based SQL under `sql/03_etl_stage.sql`,
`sql/04_etl_insert_core.sql` and `sql/05_etl_insert_quarantine.sql`.
It automatically applies the idempotent Core schema migration `sql/01_core.sql`.

## Date window and backfill

Default inclusive window (all generated historical and future requests):
`2023-01-01` through `2027-12-31`. Override by setting the `ETL_START_DATE`
and `ETL_END_DATE` environment variables for Docker Compose before `run`.
Filtering is by `public.prices.loading_date` (not by `price_dates.price_date`).

A successful run refreshes the requested date range in a single transaction:
`DELETE` old rows for that window, `INSERT` all currently valid records and
quarantine the rest. Core and quarantine are mutually exclusive at the `price_id`
grain, so overlap/retries cannot duplicate deals; each attempt is still audited
separately in `core.etl_runs`.

## Data-quality policy

- Source-validation: price > 0, for RUB price > 1000; distance > 0;
  weight and volume non-negative; both `gc_id` references exist.
- Currency `643` uses 1 RUB; `840`/`978` require the exact FX rate
  for their stored `nearest_rate_date`. No fallback on loading date.
- Weight category is recalculated from weight rounded to 0.1 tonne;
  volume category is FTL only when `0 < volume <= 120` cubic meters.
- Price and distance precision is checked after normalization.
- `outlier_mark` is **preserved**, not recalculated or used as a DQ reject;
  the market mart will filter flagged anomalies in the next stage.
- A loading/unloading pair with the same city is not automatically invalid.
- No dimension joins multiply rows: city checks use `EXISTS`, and this Core
  table stores one row per source `price_id`. Multi-month/multi-body expansion
  belongs to the future Mart layer.
- `raw_record` in quarantine is the original source row, not a derived row.

## Checks

`sql/06_check_etl.sql` reports source/Core/quarantine counts, completeness,
recent runs, reason counts and normalized amounts per currency.

**Snapshot caveat:** the newest 2026-10-26 records may not yet be flagged as
outliers by the synthetic source's nightly job. This source-data limitation
should be highlighted in the final project README.

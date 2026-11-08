-- Idempotent refresh: repeatable, no duplicated rows; raw/Core untouched.
-- REFRESH is not concurrent: appropriate for a local, scheduled batch pipeline.
-- Both refreshes are in a transaction so BI doesn't see a half-updated DWH.
BEGIN;
REFRESH MATERIALIZED VIEW mart.market_observations;
REFRESH MATERIALIZED VIEW mart.market_corridor;
COMMIT;

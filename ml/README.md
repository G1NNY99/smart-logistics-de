# CatBoost tariff prediction (steps 6.1–6.2)

- **Train**: actual, direct (`is_fact=true`, `complex=false`), non-outlier shipments: `[2026-07-26, 2026-10-05)`.
- **Test**: same eligibility, `[2026-10-05, 2026-10-26]` inclusive.
- **Future**: all valid Core applications with `loading_date > 2026-10-26`. Source prices in this cohort are **never selected as targets**; the persisted `actual_price_rub`, `abs_error_rub`, `ape_pct` are `NULL`.
- Model: `CatBoostRegressor`, fixed seed `20261026`, 350 iterations, 4 CPU threads, RMSE loss, native category handling.
- Geography: canonical source `cities` row by minimum `id` per `gc_id`; separately encodes origin/destination regions and cities, plus latitude/longitude.
- Temporal: year/month/day-of-week/day-of-year and cyclical sin/cos features.
- Exclusions: `price_rub` or price-related statistics, `outlier_mark`, VAT price, per-km current tariffs, profits, `price_group_stats`, same-month target aggregates. Feature columns are an **explicit allowlist**.
- Result tables: `mart.ml_price_predictions` (one row per `price_id`) and `mart.ml_model_runs` (metrics/audit).
- Local artifacts (not committed): `artifacts/catboost_v1.cbm`, `artifacts/ml_metrics.json`.
- Re-runnable with `docker compose run --rm --no-deps ml` when the database is ready; predictions are replaced atomically after successful training. Tests compare a fingerprint excluding `scored_at`.

**Full pipeline from repository root:** `docker compose up --build -d`. To verify all four services, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify_full_pipeline.ps1`.

As of step 6.2, ML is a default one-shot Compose service dependent on the successful completion of `mart`. For documentation and manual operation, see `docs/PIPELINE.md`.

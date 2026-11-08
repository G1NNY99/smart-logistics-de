# ETL regression checks

The following files are part of the repository (not personal notes):

- `07_etl_assertions.sql`: read-only SQL assertions for partition completeness, DQ, exact FX conversion, weight/volume categories, source flag preservation, and quarantine provenance.
- `08_etl_snapshot.sql`: a deterministic business-data fingerprint of `core.prices` and `core.dq_quarantine_prices`, excluding ingestion timestamps and audit logs.
- `verify_etl.ps1`: Windows PowerShell 5.1+ test runner. Repeats a full ETL load, runs an overlapping date-window backfill, and asserts snapshots are unchanged. It does **not** modify raw/source tables or remove Docker volumes.

Run from the repo root in Windows PowerShell:

```powershell
.\tests\verify_etl.ps1
```

Expected outcome: two `[PASS]` repeatability statements, DQ checks without SQL errors, and a final `[PASS] ETL regression suite finished successfully.`

Important: `core.etl_runs` appends records for repeat executions, and `etl_loaded_at`/`quarantined_at` change on atomic date-window replacement. They are operational metadata; the strict data repeatability check intentionally covers **all business columns, including quarantine reason codes and original JSON records**, while excluding only those metadata fields.

If the PowerShell execution policy blocks the script, run it without changing a machine-wide policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\verify_etl.ps1
```

When running checks on a non-Windows environment, apply the SQL via `psql` and compare the single-line snapshot output manually before and after rerunning the date-window ETL.

-- Smoke check: returns three row counts and does not change data.
SELECT 'source_prices' AS object_name, count(*) AS row_count FROM public.prices
UNION ALL
SELECT 'core_prices', count(*) FROM core.prices
UNION ALL
SELECT 'quarantine', count(*) FROM core.dq_quarantine_prices
ORDER BY object_name;

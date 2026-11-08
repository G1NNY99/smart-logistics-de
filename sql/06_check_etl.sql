-- Read-only verification of the default full-data ETL run.
SELECT 'source_prices' AS object_name, count(*) AS row_count
FROM public.prices
UNION ALL SELECT 'core_prices', count(*) FROM core.prices
UNION ALL SELECT 'quarantine', count(*) FROM core.dq_quarantine_prices
ORDER BY object_name;

-- All source prices should be either normalized or quarantined after full loading.
SELECT
    (SELECT count(*) FROM public.prices) AS source_count,
    (SELECT count(*) FROM core.prices) AS valid_count,
    (SELECT count(*) FROM core.dq_quarantine_prices) AS quarantine_count,
    (SELECT count(*) FROM public.prices) =
       (SELECT count(*) FROM core.prices) +
       (SELECT count(*) FROM core.dq_quarantine_prices) AS partition_is_complete;

SELECT run_id, start_date, end_date, status, source_count,
       loaded_count, quarantine_count
FROM core.etl_runs ORDER BY run_id DESC LIMIT 3;

SELECT reason_code, count(*) AS affected_rows
FROM core.dq_quarantine_prices
CROSS JOIN LATERAL unnest(reason_codes) AS reason_code
GROUP BY reason_code ORDER BY affected_rows DESC, reason_code;

SELECT currency_code, count(*) AS valid_rows,
       round(sum(price_rub), 2) AS sum_price_rub
FROM core.prices GROUP BY currency_code ORDER BY currency_code;

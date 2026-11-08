-- Read-only regression assertions for the full-window ETL run.
-- Execute via: psql -X -v ON_ERROR_STOP=1 -f /tmp/07_etl_assertions.sql
-- No INSERT/UPDATE/DELETE/DDL is performed by this file.

DO $assert$
DECLARE
    bad_count bigint;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM core.etl_runs WHERE status = 'success'
    ) THEN
        RAISE EXCEPTION 'No successful ETL run recorded';
    END IF;

    -- Source must be partitioned into exactly one destination per price_id.
    SELECT count(*) INTO bad_count
    FROM public.prices s
    LEFT JOIN core.prices c ON c.price_id = s.id
    LEFT JOIN core.dq_quarantine_prices q ON q.price_id = s.id
    WHERE (c.price_id IS NULL) = (q.price_id IS NULL);
    IF bad_count <> 0 THEN
        RAISE EXCEPTION 'Partition violated: % source rows have zero or two destinations', bad_count;
    END IF;

    SELECT count(*) INTO bad_count
    FROM (
        SELECT c.price_id AS id FROM core.prices c
        LEFT JOIN public.prices s ON s.id = c.price_id WHERE s.id IS NULL
        UNION ALL
        SELECT q.price_id AS id FROM core.dq_quarantine_prices q
        LEFT JOIN public.prices s ON s.id = q.price_id WHERE s.id IS NULL
    ) orphans;
    IF bad_count <> 0 THEN
        RAISE EXCEPTION '% destination rows lack a source', bad_count;
    END IF;
    RAISE NOTICE '[PASS] Every source price is in exactly one destination; no orphans';

    -- Check DQ rules against the RAW values, not rounded/core equivalents.
    SELECT count(*) INTO bad_count
    FROM core.prices c
    JOIN public.prices s ON s.id = c.price_id
    WHERE s.price <= 0
       OR (s.currency_code = '643' AND s.price <= 1000)
       OR s.distance <= 0
       OR s.total_weight < 0
       OR s.total_volume < 0
       OR s.currency_code NOT IN ('643', '840', '978')
       OR NOT EXISTS (SELECT 1 FROM public.cities city WHERE city.gc_id = s.loading_city_gcid)
       OR NOT EXISTS (SELECT 1 FROM public.cities city WHERE city.gc_id = s.unloading_city_gcid);
    IF bad_count <> 0 THEN
        RAISE EXCEPTION '% invalid source rows reached core.prices', bad_count;
    END IF;
    RAISE NOTICE '[PASS] Invalid physical parameters, prices, cities and currencies rejected';

    -- Exact FX lookup (nearest_rate_date), RUB = 1; price and km normalization.
    SELECT count(*) INTO bad_count
    FROM core.prices c
    JOIN public.prices s ON s.id = c.price_id
    WHERE c.currency_code IS DISTINCT FROM s.currency_code
       OR c.nearest_rate_date IS DISTINCT FROM s.nearest_rate_date
       OR c.price_original <> round(s.price::numeric, 4)
       OR c.distance_km <> round(s.distance::numeric, 3)
       OR (c.currency_code = '643' AND c.fx_rate <> 1)
       OR (c.currency_code IN ('840', '978') AND NOT EXISTS (
            SELECT 1 FROM public.exchange_rates er
            WHERE er.num_code = c.currency_code
              AND er.setting_date = c.nearest_rate_date
              AND round(er.value::numeric, 6) = c.fx_rate
       ))
       OR c.price_rub <> round(s.price::numeric * c.fx_rate, 2)
       OR c.price_km_rub <> round(c.price_rub / c.distance_km, 6);
    IF bad_count <> 0 THEN
        RAISE EXCEPTION '% core rows violate FX/currency/price normalization', bad_count;
    END IF;
    RAISE NOTICE '[PASS] Exact FX dates and RUB/km normalization';

    -- Weight is bucketed after rounding to 0.1 t; volume uses original units.
    SELECT count(*) INTO bad_count
    FROM core.prices c
    JOIN public.prices s ON s.id = c.price_id
    WHERE c.weight_category <> CASE
          WHEN round(s.total_weight::numeric, 1) >= 30 THEN 'G20T'
          WHEN round(s.total_weight::numeric, 1) >= 10 THEN 'FTL'
          WHEN round(s.total_weight::numeric, 1) >= 5 THEN '10T'
          WHEN round(s.total_weight::numeric, 1) >= 2.5 THEN '5T'
          WHEN round(s.total_weight::numeric, 1) >= 0.5 THEN 'L5T'
          ELSE 'OTH' END
       OR c.volume_category <> CASE WHEN s.total_volume > 0 AND s.total_volume <= 120
                                    THEN 'FTL' ELSE 'OTH' END
       OR c.outlier_mark IS DISTINCT FROM s.outlier_mark
       OR c.is_fact IS DISTINCT FROM s.is_fact
       OR c.complex IS DISTINCT FROM s.complex;
    IF bad_count <> 0 THEN
        RAISE EXCEPTION '% core rows have incorrect business classifications/flags', bad_count;
    END IF;
    RAISE NOTICE '[PASS] Weight/volume category boundaries and source flags';

    -- Quarantine must preserve the source row, with causes for known defects.
    SELECT count(*) INTO bad_count
    FROM core.dq_quarantine_prices q
    JOIN public.prices s ON s.id = q.price_id
    WHERE q.raw_record IS DISTINCT FROM to_jsonb(s)
       OR cardinality(q.reason_codes) = 0
       OR (s.price <= 0 AND NOT ('INVALID_PRICE' = ANY(q.reason_codes)))
       OR (s.currency_code = '643' AND s.price <= 1000
           AND NOT ('RUB_PRICE_TOO_LOW' = ANY(q.reason_codes)))
       OR (s.distance <= 0 AND NOT ('INVALID_DISTANCE' = ANY(q.reason_codes)))
       OR (s.total_weight < 0 AND NOT ('NEGATIVE_WEIGHT' = ANY(q.reason_codes)))
       OR (s.total_volume < 0 AND NOT ('NEGATIVE_VOLUME' = ANY(q.reason_codes)))
       OR (s.currency_code IN ('840','978') AND NOT EXISTS (
              SELECT 1 FROM public.exchange_rates er
              WHERE er.num_code = s.currency_code
                AND er.setting_date = s.nearest_rate_date
                AND er.value > 0
           ) AND NOT ('FX_RATE_MISSING_OR_INVALID' = ANY(q.reason_codes)));
    IF bad_count <> 0 THEN
        RAISE EXCEPTION '% quarantine records have missing reasons or altered source data', bad_count;
    END IF;
    RAISE NOTICE '[PASS] Quarantine reasons and unmodified raw records';
END
$assert$;

SELECT 'PASS' AS result,
       (SELECT count(*) FROM public.prices) AS source_count,
       (SELECT count(*) FROM core.prices) AS core_count,
       (SELECT count(*) FROM core.dq_quarantine_prices) AS quarantine_count,
       (SELECT count(*) FROM core.etl_runs WHERE status = 'success') AS successful_runs;

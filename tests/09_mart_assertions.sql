-- Read-only SQL regression checks for the DWH mart (PostgreSQL 17).
-- Run AFTER refreshing both materialized views.
\set ON_ERROR_STOP on

DO $checks$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM mart.market_observations) THEN
        RAISE EXCEPTION 'DWH observation view is empty';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM mart.market_corridor) THEN
        RAISE EXCEPTION 'DWH corridor view is empty';
    END IF;
    IF EXISTS (
        SELECT 1 FROM mart.market_observations
        WHERE month > DATE '2026-10-26'
           OR month <> date_trunc('month', month)::date
           OR latest_price_date > DATE '2026-10-26'
    ) THEN
        RAISE EXCEPTION 'Future/inconsistent month leaked into historic mart';
    END IF;
    IF EXISTS (
        SELECT 1 FROM mart.market_observations AS o
        WHERE NOT EXISTS (
            SELECT 1 FROM public.price_dates AS pd
            WHERE pd.price_id = o.price_id
              AND date_trunc('month', pd.price_date)::date = o.month
              AND pd.price_date <= DATE '2026-10-26'
        )
    ) THEN
        RAISE EXCEPTION 'Observation month is not present in price_dates';
    END IF;
    IF EXISTS (
        SELECT 1 FROM mart.market_observations
        GROUP BY month, price_id, body_group_id
        HAVING COUNT(*) <> 1
    ) THEN
        RAISE EXCEPTION 'Duplicated price within month/body group';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM mart.market_observations AS o
        JOIN core.prices AS p ON p.price_id = o.price_id
        WHERE p.is_fact IS NOT TRUE OR p.complex IS NOT FALSE
           OR p.outlier_mark IS NOT FALSE
           OR p.price_type NOT IN (1,2,3,4,5,9)
           OR p.price_rub <= 0 OR p.distance_km <= 0
    ) THEN
        RAISE EXCEPTION 'Ineligible deal present in market mart';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM mart.market_observations AS o
        JOIN public.cities AS c ON c.gc_id = o.loading_city_gcid
        GROUP BY o.month, o.price_id, o.body_group_id, o.loading_city
        HAVING o.loading_city <> (ARRAY_AGG(c.name ORDER BY c.id))[1]
    ) THEN
        RAISE EXCEPTION 'Non-canonical loading city found';
    END IF;
    IF EXISTS (
        SELECT 1 FROM mart.market_corridor
        WHERE trips_count < 1 OR carriers_count < 0 OR carriers_count > trips_count
           OR p25_trip > median_trip OR median_trip > p75_trip
           OR p25_km > median_km OR median_km > p75_km
           OR (trips_count < 2 AND cv_rate IS NOT NULL)
    ) THEN
        RAISE EXCEPTION 'Invalid corridor metrics or sample counts';
    END IF;
    IF (
        SELECT COUNT(*) FROM mart.market_observations
    ) <> (
        SELECT COALESCE(SUM(trips_count), 0) FROM mart.market_corridor
    ) THEN
        RAISE EXCEPTION 'Lost or duplicated observation in corridor aggregation';
    END IF;
    RAISE NOTICE '[PASS] Historical filtering, city/body de-duplication, metrics and counts';

    IF EXISTS (
        SELECT 1
        FROM mart.market_corridor AS m
        LEFT JOIN mart.market_corridor AS prev
          ON prev.month = (m.month - INTERVAL '1 month')::date
         AND prev.loading_city_gcid = m.loading_city_gcid
         AND prev.unloading_city_gcid = m.unloading_city_gcid
         AND prev.body_group_id = m.body_group_id
         AND prev.weight_category = m.weight_category
        WHERE m.mom_pct IS DISTINCT FROM
              CASE WHEN prev.median_trip IS NULL OR prev.median_trip = 0
                   THEN NULL
                   ELSE ROUND(100 * (m.median_trip / prev.median_trip - 1), 2)
              END
    ) THEN
        RAISE EXCEPTION 'Incorrect calendar MoM comparison';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM mart.market_corridor AS m
        LEFT JOIN mart.market_corridor AS prev
          ON prev.month = (m.month - INTERVAL '1 year')::date
         AND prev.loading_city_gcid = m.loading_city_gcid
         AND prev.unloading_city_gcid = m.unloading_city_gcid
         AND prev.body_group_id = m.body_group_id
         AND prev.weight_category = m.weight_category
        WHERE m.yoy_pct IS DISTINCT FROM
              CASE WHEN prev.median_trip IS NULL OR prev.median_trip = 0
                   THEN NULL
                   ELSE ROUND(100 * (m.median_trip / prev.median_trip - 1), 2)
              END
    ) THEN
        RAISE EXCEPTION 'Incorrect calendar YoY comparison';
    END IF;
    RAISE NOTICE '[PASS] MoM/YoY follow exact calendar periods';

    IF EXISTS (
        SELECT 1 FROM mart.market_corridor AS m
        WHERE m.reliability_level IS DISTINCT FROM
              CASE WHEN m.trips_count >= 30 AND m.carriers_count >= 5
                         AND m.latest_price_date >= DATE '2026-10-26' - 30
                   THEN 'HIGH'
                   WHEN m.trips_count >= 10 THEN 'MEDIUM'
                   ELSE 'LOW_DATA'
              END
    ) THEN
        RAISE EXCEPTION 'Incorrect Data Trust reliability level';
    END IF;
    RAISE NOTICE '[PASS] Data Trust level from trips/carriers/freshness';
END
$checks$;

-- Compact diagnostics with reproducible counts.
SELECT 'observations' AS metric, COUNT(*) AS value FROM mart.market_observations
UNION ALL
SELECT 'corridor_cells', COUNT(*) FROM mart.market_corridor
UNION ALL
SELECT 'months', COUNT(DISTINCT month) FROM mart.market_corridor
UNION ALL
SELECT 'high_trust_cells', COUNT(*) FROM mart.market_corridor WHERE reliability_level = 'HIGH'
UNION ALL
SELECT 'medium_trust_cells', COUNT(*) FROM mart.market_corridor WHERE reliability_level = 'MEDIUM'
ORDER BY metric;

-- Example of a market corridor, recent months first.
SELECT month, loading_city, unloading_city, body_group, weight_category,
       trips_count, carriers_count, p25_trip, median_trip, p75_trip,
       median_km, mom_pct, yoy_pct, reliability_level
FROM mart.market_corridor
ORDER BY trips_count DESC, month DESC, loading_city_gcid, unloading_city_gcid
LIMIT 5;

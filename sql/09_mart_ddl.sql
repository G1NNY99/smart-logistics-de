-- Smart Logistics / DWH step 5.1
-- Source: core.prices and public.cities, public.body_types,
--         public.price_body_types, public.price_dates.
-- Static snapshot: as_of = 2026-10-26 (NOT current_date).
-- Materialized observations keep one row per (month, price_id, body_group_id).
-- A price may legitimately appear in different groups or months.
-- Run with psql -v ON_ERROR_STOP=1 before sql/10_mart_refresh.sql.

BEGIN;
CREATE SCHEMA IF NOT EXISTS mart;

CREATE MATERIALIZED VIEW IF NOT EXISTS mart.market_observations AS
WITH eligible AS (
    SELECT p.*
    FROM core.prices AS p
    WHERE p.is_fact = TRUE
      AND p.price_type IN (1, 2, 3, 4, 5, 9)
      AND p.complex = FALSE
      AND p.outlier_mark = FALSE
      AND p.price_rub > 0
      AND p.distance_km > 0
),
canonical_cities AS (
    -- Important: gc_id is NOT unique; use the smallest source city ID.
    SELECT DISTINCT ON (gc_id)
           gc_id, id AS city_id, name, full_name_local
    FROM public.cities
    ORDER BY gc_id, id
),
normalized_body_groups AS (
    -- LEFT JOIN uses prices.body_type if the price has no association rows.
    -- DISTINCT collapses multiple child types of the SAME standard group.
    -- Different standard groups remain separate analytic observations.
    SELECT DISTINCT
           p.price_id,
           CASE
               WHEN COALESCE(bt.std_id, pbt.body_type_id, p.body_type)
                    IN (56, 57, 58, 59, 60, 61) THEN 56
               WHEN COALESCE(bt.std_id, pbt.body_type_id, p.body_type)
                    IN (4, 46, 47, 48) THEN 4
               WHEN COALESCE(bt.std_id, pbt.body_type_id, p.body_type) = 2 THEN 2
               WHEN COALESCE(bt.std_id, pbt.body_type_id, p.body_type)
                    IN (1, 15) THEN 15
               WHEN COALESCE(pbt.body_type_id, p.body_type) IS NULL THEN -1
               ELSE 0
           END::integer AS body_group_id
    FROM eligible AS p
    LEFT JOIN public.price_body_types AS pbt ON pbt.price_id = p.price_id
    LEFT JOIN public.body_types AS bt
      ON bt.id = COALESCE(pbt.body_type_id, p.body_type)
),
monthly_dates AS (
    -- Month is sourced from price_dates, NOT from loading_date.
    -- Multiple price_dates inside one month must not multiply a fact.
    SELECT pd.price_id,
           date_trunc('month', pd.price_date)::date AS month,
           MAX(pd.price_date) AS latest_price_date
    FROM public.price_dates AS pd
    WHERE pd.price_date <= DATE '2026-10-26'
    GROUP BY pd.price_id, date_trunc('month', pd.price_date)::date
)
SELECT
    md.month,
    p.price_id,
    p.loading_city_gcid,
    oc.name AS loading_city,
    oc.full_name_local AS loading_city_full,
    p.unloading_city_gcid,
    dc.name AS unloading_city,
    dc.full_name_local AS unloading_city_full,
    bg.body_group_id,
    CASE bg.body_group_id
        WHEN 56 THEN 'Тент'
        WHEN 4  THEN 'Рефрижератор'
        WHEN 2  THEN 'Изотерм'
        WHEN 15 THEN 'Борт'
        WHEN -1 THEN 'Не указан'
        ELSE 'Прочие'
    END::text AS body_group,
    p.weight_category,
    p.volume_category,
    p.price_type,
    p.organization_id,
    p.price_rub,
    p.price_rub / NULLIF(p.distance_km, 0) AS price_km_rub,
    md.latest_price_date
FROM eligible AS p
JOIN normalized_body_groups AS bg ON bg.price_id = p.price_id
JOIN monthly_dates AS md ON md.price_id = p.price_id
JOIN canonical_cities AS oc ON oc.gc_id = p.loading_city_gcid
JOIN canonical_cities AS dc ON dc.gc_id = p.unloading_city_gcid
WITH NO DATA;

-- The unique index documents and enforces the observation grain.
CREATE UNIQUE INDEX IF NOT EXISTS market_observations_grain_uq
    ON mart.market_observations (month, price_id, body_group_id);
CREATE INDEX IF NOT EXISTS market_observations_route_idx
    ON mart.market_observations
       (month, loading_city_gcid, unloading_city_gcid, body_group_id, weight_category);

CREATE MATERIALIZED VIEW IF NOT EXISTS mart.market_corridor AS
WITH grouped AS (
    SELECT
        o.month,
        o.loading_city_gcid,
        MIN(o.loading_city) AS loading_city,
        o.unloading_city_gcid,
        MIN(o.unloading_city) AS unloading_city,
        o.body_group_id,
        MIN(o.body_group) AS body_group,
        o.weight_category,
        COUNT(DISTINCT o.price_id)::bigint AS trips_count,
        COUNT(DISTINCT o.organization_id)
            FILTER (WHERE o.price_type IN (3, 9))::bigint AS carriers_count,
        MAX(o.latest_price_date) AS latest_price_date,
        percentile_cont(ARRAY[0.25, 0.50, 0.75]::double precision[])
            WITHIN GROUP (ORDER BY o.price_rub::double precision) AS trip_quartiles,
        percentile_cont(ARRAY[0.25, 0.50, 0.75]::double precision[])
            WITHIN GROUP (ORDER BY o.price_km_rub::double precision) AS km_quartiles,
        AVG(o.price_rub) AS raw_avg_trip,
        STDDEV_SAMP(o.price_rub) AS raw_stddev_trip
    FROM mart.market_observations AS o
    GROUP BY o.month, o.loading_city_gcid, o.unloading_city_gcid,
             o.body_group_id, o.weight_category
),
metrics AS (
    SELECT
        g.month, g.loading_city_gcid, g.loading_city,
        g.unloading_city_gcid, g.unloading_city,
        g.body_group_id, g.body_group, g.weight_category,
        g.trips_count, g.carriers_count, g.latest_price_date,
        ROUND(g.trip_quartiles[1]::numeric, 2) AS p25_trip,
        ROUND(g.trip_quartiles[2]::numeric, 2) AS median_trip,
        ROUND(g.trip_quartiles[3]::numeric, 2) AS p75_trip,
        ROUND(g.raw_avg_trip, 2) AS avg_trip,
        ROUND(g.km_quartiles[1]::numeric, 2) AS p25_km,
        ROUND(g.km_quartiles[2]::numeric, 2) AS median_km,
        ROUND(g.km_quartiles[3]::numeric, 2) AS p75_km,
        CASE WHEN g.trips_count < 2 OR g.raw_avg_trip = 0 THEN NULL
             ELSE ROUND(g.raw_stddev_trip / g.raw_avg_trip, 4)
        END AS cv_rate,
        CASE WHEN g.trips_count >= 30
                   AND g.carriers_count >= 5
                   AND g.latest_price_date >= DATE '2026-10-26' - 30
             THEN 'HIGH'
             WHEN g.trips_count >= 10 THEN 'MEDIUM'
             ELSE 'LOW_DATA'
        END::text AS reliability_level
    FROM grouped AS g
)
SELECT
    c.month, c.loading_city_gcid, c.loading_city,
    c.unloading_city_gcid, c.unloading_city,
    c.body_group_id, c.body_group, c.weight_category,
    c.p25_trip, c.median_trip, c.p75_trip, c.avg_trip,
    c.p25_km, c.median_km, c.p75_km,
    c.trips_count, c.carriers_count, c.cv_rate,
    c.latest_price_date,
    c.reliability_level,
    CASE WHEN prev_month.median_trip IS NULL OR prev_month.median_trip = 0
         THEN NULL
         ELSE ROUND(100 * (c.median_trip / prev_month.median_trip - 1), 2)
    END AS mom_pct,
    CASE WHEN prev_year.median_trip IS NULL OR prev_year.median_trip = 0
         THEN NULL
         ELSE ROUND(100 * (c.median_trip / prev_year.median_trip - 1), 2)
    END AS yoy_pct
FROM metrics AS c
LEFT JOIN metrics AS prev_month
  ON prev_month.month = (c.month - INTERVAL '1 month')::date
 AND prev_month.loading_city_gcid = c.loading_city_gcid
 AND prev_month.unloading_city_gcid = c.unloading_city_gcid
 AND prev_month.body_group_id = c.body_group_id
 AND prev_month.weight_category = c.weight_category
LEFT JOIN metrics AS prev_year
  ON prev_year.month = (c.month - INTERVAL '1 year')::date
 AND prev_year.loading_city_gcid = c.loading_city_gcid
 AND prev_year.unloading_city_gcid = c.unloading_city_gcid
 AND prev_year.body_group_id = c.body_group_id
 AND prev_year.weight_category = c.weight_category
WITH NO DATA;

-- Fixed business grain: (month, source city, destination city, body group, weight class).
CREATE UNIQUE INDEX IF NOT EXISTS market_corridor_grain_uq
    ON mart.market_corridor
       (month, loading_city_gcid, unloading_city_gcid, body_group_id, weight_category);
CREATE INDEX IF NOT EXISTS market_corridor_route_idx
    ON mart.market_corridor
       (loading_city_gcid, unloading_city_gcid, month DESC);

COMMIT;

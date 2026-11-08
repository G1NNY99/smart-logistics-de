-- Stage one row per raw price for the requested inclusive loading_date window.
-- The temporary table exists only inside the atomic ETL transaction.
-- Keep ALL source rows in staging so invalid ones can be quarantined.
-- Exists/semijoins avoid multiplying prices when cities.gc_id is duplicated.
-- FX uses an exact (currency_code, nearest_rate_date) match, never loading_date.
CREATE TEMP TABLE etl_stage ON COMMIT DROP AS
WITH fx_rates AS (
    SELECT DISTINCT ON (num_code, setting_date)
           num_code, setting_date, value
    FROM public.exchange_rates
    WHERE num_code IN ('840', '978')
    ORDER BY num_code, setting_date, id
), source_rows AS (
    SELECT
        p.*,
        to_jsonb(p) AS raw_record,
        EXISTS (
            SELECT 1 FROM public.cities c WHERE c.gc_id = p.loading_city_gcid
        ) AS loading_city_exists,
        EXISTS (
            SELECT 1 FROM public.cities c WHERE c.gc_id = p.unloading_city_gcid
        ) AS unloading_city_exists,
        CASE WHEN p.currency_code = '643' THEN 1::numeric
             ELSE fx.value::numeric END AS fx_rate
    FROM public.prices p
    LEFT JOIN fx_rates fx
      ON fx.num_code = p.currency_code
     AND fx.setting_date = p.nearest_rate_date
    WHERE p.loading_date >= %(start_date)s
      AND p.loading_date <= %(end_date)s
), normalized AS (
    SELECT
        s.*,
        round(s.price::numeric, 4) AS normalized_price_original,
        round(s.distance::numeric, 3) AS normalized_distance_km,
        round(s.total_weight::numeric, 3) AS normalized_total_weight,
        round(s.total_volume::numeric, 3) AS normalized_total_volume,
        round(s.price::numeric * s.fx_rate, 2) AS normalized_price_rub,
        CASE
            WHEN round(s.total_weight::numeric, 1) >= 30 THEN 'G20T'
            WHEN round(s.total_weight::numeric, 1) >= 10 THEN 'FTL'
            WHEN round(s.total_weight::numeric, 1) >= 5 THEN '10T'
            WHEN round(s.total_weight::numeric, 1) >= 2.5 THEN '5T'
            WHEN round(s.total_weight::numeric, 1) >= 0.5 THEN 'L5T'
            ELSE 'OTH'
        END AS normalized_weight_category,
        CASE WHEN s.total_volume > 0 AND s.total_volume <= 120
             THEN 'FTL' ELSE 'OTH' END AS normalized_volume_category
    FROM source_rows s
), validated AS (
    SELECT
        n.*,
        round(n.normalized_price_rub / nullif(n.normalized_distance_km, 0), 6)
            AS normalized_price_km_rub,
        array_remove(ARRAY[
            CASE WHEN n.price <= 0 THEN 'INVALID_PRICE' END,
            CASE WHEN n.currency_code = '643' AND n.price <= 1000
                 THEN 'RUB_PRICE_TOO_LOW' END,
            CASE WHEN n.distance <= 0 THEN 'INVALID_DISTANCE' END,
            CASE WHEN n.total_weight < 0 THEN 'NEGATIVE_WEIGHT' END,
            CASE WHEN n.total_volume < 0 THEN 'NEGATIVE_VOLUME' END,
            CASE WHEN NOT n.loading_city_exists THEN 'UNKNOWN_LOADING_CITY' END,
            CASE WHEN NOT n.unloading_city_exists THEN 'UNKNOWN_UNLOADING_CITY' END,
            CASE WHEN n.currency_code NOT IN ('643', '840', '978')
                 THEN 'UNSUPPORTED_CURRENCY' END,
            CASE WHEN n.currency_code IN ('840', '978')
                       AND (n.fx_rate IS NULL OR n.fx_rate <= 0)
                 THEN 'FX_RATE_MISSING_OR_INVALID' END,
            CASE WHEN n.normalized_price_original <= 0
                 THEN 'PRICE_PRECISION_LOSS' END,
            CASE WHEN n.normalized_distance_km <= 0
                 THEN 'DISTANCE_PRECISION_LOSS' END,
            CASE WHEN n.normalized_price_rub <= 0
                 THEN 'RUB_PRICE_PRECISION_LOSS' END,
            CASE WHEN n.normalized_price_rub > 0
                      AND n.normalized_distance_km > 0
                      AND round(n.normalized_price_rub / n.normalized_distance_km, 6) <= 0
                 THEN 'KM_PRICE_PRECISION_LOSS' END
        ]::text[], NULL) AS reason_codes
    FROM normalized n
)
SELECT
    v.id::bigint AS price_id,
    v.created_at,
    v.updated_at,
    v.loading_date,
    v.end_loading_date,
    v.loading_city_gcid,
    v.unloading_city_gcid,
    v.normalized_distance_km AS distance_km,
    v.normalized_total_weight AS total_weight,
    v.normalized_total_volume AS total_volume,
    v.body_type,
    v.normalized_weight_category AS weight_category,
    v.normalized_volume_category AS volume_category,
    v.currency_code,
    v.nearest_rate_date,
    v.fx_rate,
    v.normalized_price_original AS price_original,
    v.normalized_price_rub AS price_rub,
    v.normalized_price_km_rub AS price_km_rub,
    v.price_type,
    v.is_fact,
    v.complex,
    v.outlier_mark,
    v.subscriber_id,
    v.organization_id,
    v.source,
    v.external_item_uuid,
    v.raw_record,
    v.reason_codes
FROM validated v;

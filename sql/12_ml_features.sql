-- ML source features only (one row per price_id).
-- Historical labels only: future price is NULL at the SQL boundary.
-- Never join price_group_stats or the target-derived DWH market corridor.
-- Source dimensions use canonical cities: MIN(id) per gc_id.
-- Training/test eligibility: factual, direct trips, not outlier-marked.
-- Future cohort: every valid normalized future application is scored,
-- regardless of synthetic source price/is_fact; its label is hidden.
WITH canonical_cities AS (
    SELECT DISTINCT ON (gc_id)
           gc_id, name, full_name_local, latitude, longitude
    FROM public.cities
    ORDER BY gc_id, id
), cohort AS (
    SELECT p.*
    FROM core.prices AS p
    WHERE (
        p.loading_date >= %(train_start)s
        AND p.loading_date <= %(as_of)s
        AND p.is_fact = TRUE
        AND p.complex = FALSE
        AND p.outlier_mark = FALSE
        AND p.price_rub > 0
        AND p.distance_km > 0
    ) OR p.loading_date > %(as_of)s
)
SELECT
    p.price_id,
    p.loading_date,
    p.loading_city_gcid,
    p.unloading_city_gcid,
    p.distance_km,
    p.total_weight,
    p.total_volume,
    p.weight_category,
    p.volume_category,
    p.price_type,
    oc.name AS origin_city,
    dc.name AS destination_city,
    COALESCE(NULLIF(btrim(split_part(oc.full_name_local, ',', 2)), ''), 'UNKNOWN') AS origin_region,
    COALESCE(NULLIF(btrim(split_part(dc.full_name_local, ',', 2)), ''), 'UNKNOWN') AS destination_region,
    oc.latitude AS origin_lat,
    oc.longitude AS origin_lon,
    dc.latitude AS destination_lat,
    dc.longitude AS destination_lon,
    CASE COALESCE(main_body.std_id, child_body.std_id, p.body_type, -1)
        WHEN 56 THEN 'Тент'
        WHEN 4  THEN 'Рефрижератор'
        WHEN 2  THEN 'Изотерм'
        WHEN 15 THEN 'Борт'
        WHEN -1 THEN 'Не указан'
        ELSE 'Прочие'
    END AS body_group,
    CASE WHEN p.loading_date <= %(as_of)s THEN p.price_rub ELSE NULL END AS actual_price_rub
FROM cohort AS p
JOIN canonical_cities AS oc ON oc.gc_id = p.loading_city_gcid
JOIN canonical_cities AS dc ON dc.gc_id = p.unloading_city_gcid
LEFT JOIN public.body_types AS main_body ON main_body.id = p.body_type
LEFT JOIN LATERAL (
    SELECT COALESCE(bt.std_id, pbt.body_type_id) AS std_id
    FROM public.price_body_types AS pbt
    LEFT JOIN public.body_types AS bt ON bt.id = pbt.body_type_id
    WHERE pbt.price_id = p.price_id
    ORDER BY pbt.body_type_id
    LIMIT 1
) AS child_body ON TRUE
ORDER BY p.loading_date, p.price_id;

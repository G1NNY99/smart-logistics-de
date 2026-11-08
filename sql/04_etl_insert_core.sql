-- Insert the valid rows after the date-window DELETE, in the same transaction.
INSERT INTO core.prices (
    price_id, created_at, updated_at, loading_date, end_loading_date,
    loading_city_gcid, unloading_city_gcid, distance_km, total_weight,
    total_volume, body_type, weight_category, volume_category, currency_code,
    nearest_rate_date, fx_rate, price_original, price_rub, price_km_rub,
    price_type, is_fact, complex, outlier_mark, subscriber_id,
    organization_id, source, external_item_uuid
)
SELECT
    price_id, created_at, updated_at, loading_date, end_loading_date,
    loading_city_gcid, unloading_city_gcid, distance_km, total_weight,
    total_volume, body_type, weight_category, volume_category, currency_code,
    nearest_rate_date, fx_rate, price_original, price_rub, price_km_rub,
    price_type, is_fact, complex, outlier_mark, subscriber_id,
    organization_id, source, external_item_uuid
FROM etl_stage
WHERE cardinality(reason_codes) = 0;

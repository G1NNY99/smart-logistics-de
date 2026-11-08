-- Deterministic fingerprint of business-visible rows, independent of refresh time.
-- Use psql -A -t to get a single output line for comparison.
WITH observations AS (
    SELECT COUNT(*) AS row_count,
           md5(COALESCE(string_agg(
               md5(to_jsonb(o)::text), ''
               ORDER BY o.month, o.price_id, o.body_group_id
           ), '')) AS fingerprint
    FROM mart.market_observations AS o
), corridor AS (
    SELECT COUNT(*) AS row_count,
           md5(COALESCE(string_agg(
               md5(to_jsonb(c)::text), ''
               ORDER BY c.month, c.loading_city_gcid, c.unloading_city_gcid,
                        c.body_group_id, c.weight_category
           ), '')) AS fingerprint
    FROM mart.market_corridor AS c
)
SELECT CONCAT_WS('|', observations.row_count, observations.fingerprint,
                      corridor.row_count, corridor.fingerprint)
FROM observations CROSS JOIN corridor;

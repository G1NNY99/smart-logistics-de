-- Returns exactly ONE string representing business data (not audit metadata).
-- Changes to etl_loaded_at/quarantined_at and etl_runs are deliberately ignored.
-- Hashes are order-independent with respect to query plan: ORDER BY price_id.
SELECT concat(
    'core=', (SELECT count(*) FROM core.prices),
    ';quarantine=', (SELECT count(*) FROM core.dq_quarantine_prices),
    ';core_hash=', (
        SELECT md5(coalesce(string_agg(
            md5((to_jsonb(p) - 'etl_loaded_at')::text), '' ORDER BY p.price_id
        ), '')) FROM core.prices p
    ),
    ';quarantine_hash=', (
        SELECT md5(coalesce(string_agg(
            md5((to_jsonb(q) - 'quarantined_at')::text), '' ORDER BY q.price_id
        ), '')) FROM core.dq_quarantine_prices q
    )
) AS business_snapshot;

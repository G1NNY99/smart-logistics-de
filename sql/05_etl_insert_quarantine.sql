-- Keep the original record and all reasons for every rejected price.
INSERT INTO core.dq_quarantine_prices (price_id, loading_date, reason_codes, raw_record)
SELECT price_id, loading_date, reason_codes, raw_record
FROM etl_stage
WHERE cardinality(reason_codes) > 0;

-- Smart Logistics Data & ML Platform: ETL target schemas.
-- This migration is intentionally separate from the employer's task/sql scripts.
-- Run with psql -v ON_ERROR_STOP=1. Safe to rerun; does not truncate source data.
-- Source tables remain in public (the raw/source layer).

BEGIN;

CREATE SCHEMA IF NOT EXISTS core;

-- Exactly one normalized record per source price ID.
-- Dates from public.price_dates are deliberately NOT expanded in this table:
-- one price can represent several months and will be expanded in the mart step.
CREATE TABLE IF NOT EXISTS core.prices (
    price_id                bigint PRIMARY KEY,
    created_at              timestamp,
    updated_at              timestamp,
    loading_date            date NOT NULL,
    end_loading_date        date,
    loading_city_gcid       integer NOT NULL,
    unloading_city_gcid     integer NOT NULL,
    distance_km             numeric(16, 3) NOT NULL CHECK (distance_km > 0),
    total_weight            numeric(14, 3) NOT NULL CHECK (total_weight >= 0),
    total_volume            numeric(14, 3) NOT NULL CHECK (total_volume >= 0),
    body_type               integer,
    weight_category         varchar(4) NOT NULL
                            CHECK (weight_category IN ('G20T', 'FTL', '10T', '5T', 'L5T', 'OTH')),
    volume_category         varchar(4) NOT NULL
                            CHECK (volume_category IN ('FTL', 'OTH')),
    currency_code           varchar(3) NOT NULL
                            CHECK (currency_code IN ('643', '840', '978')),
    nearest_rate_date       date,
    fx_rate                 numeric(16, 6) NOT NULL CHECK (fx_rate > 0),
    price_original          numeric(20, 4) NOT NULL CHECK (price_original > 0),
    price_rub               numeric(20, 2) NOT NULL CHECK (price_rub > 0),
    price_km_rub            numeric(20, 6) NOT NULL CHECK (price_km_rub > 0),
    price_type              smallint NOT NULL,
    is_fact                 boolean NOT NULL,
    complex                 boolean NOT NULL,
    outlier_mark            boolean NOT NULL,
    subscriber_id           integer,
    organization_id         integer,
    source                  varchar(255),
    external_item_uuid      uuid,
    etl_loaded_at           timestamptz NOT NULL DEFAULT now()
);

-- Efficient date-window backfills and chronological ML train/test selection.
CREATE INDEX IF NOT EXISTS core_prices_loading_date_idx
    ON core.prices (loading_date);

-- Fast grouping/filtering for the historical market corridor.
CREATE INDEX IF NOT EXISTS core_prices_market_idx
    ON core.prices (loading_city_gcid, unloading_city_gcid, weight_category, loading_date)
    WHERE is_fact = true AND complex = false AND outlier_mark = false;

-- One quarantine entry per source price ID, with all applicable reason codes.
-- A full original row is preserved so bad data can be investigated.
CREATE TABLE IF NOT EXISTS core.dq_quarantine_prices (
    price_id                bigint PRIMARY KEY,
    loading_date            date NOT NULL,
    reason_codes            text[] NOT NULL CHECK (cardinality(reason_codes) > 0),
    raw_record              jsonb NOT NULL,
    quarantined_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS dq_quarantine_loading_date_idx
    ON core.dq_quarantine_prices (loading_date);

-- Execution history for monitoring/debugging, not a data source for ML features.
-- Multiple attempts for the same date interval are allowed and recorded separately.
CREATE TABLE IF NOT EXISTS core.etl_runs (
    run_id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    start_date              date NOT NULL,
    end_date                date NOT NULL,
    started_at              timestamptz NOT NULL DEFAULT now(),
    finished_at             timestamptz,
    status                  varchar(12) NOT NULL DEFAULT 'running'
                            CHECK (status IN ('running', 'success', 'failed')),
    source_count            bigint NOT NULL DEFAULT 0 CHECK (source_count >= 0),
    loaded_count            bigint NOT NULL DEFAULT 0 CHECK (loaded_count >= 0),
    quarantine_count        bigint NOT NULL DEFAULT 0 CHECK (quarantine_count >= 0),
    error_message           text,
    CONSTRAINT etl_runs_window_check CHECK (start_date <= end_date)
);

COMMIT;

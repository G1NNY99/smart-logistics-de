-- Step 6.1: reproducible CatBoost batch inference targets.
-- One active prediction per raw/core price ID. Re-running the same cohort
-- replaces predictions atomically; run history is append-only.
BEGIN;
CREATE SCHEMA IF NOT EXISTS mart;

CREATE TABLE IF NOT EXISTS mart.ml_price_predictions (
    price_id              bigint PRIMARY KEY
                          REFERENCES core.prices(price_id) ON DELETE CASCADE,
    loading_date          date NOT NULL,
    loading_city_gcid     integer NOT NULL,
    unloading_city_gcid   integer NOT NULL,
    body_group            text NOT NULL,
    dataset_split         varchar(6) NOT NULL CHECK (dataset_split IN ('test', 'future')),
    actual_price_rub      numeric(20, 2),
    predicted_price_rub   numeric(20, 2) NOT NULL CHECK (predicted_price_rub > 0),
    abs_error_rub         numeric(20, 2),
    ape_pct               numeric(12, 4),
    model_name            text NOT NULL,
    scored_at             timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ml_predictions_observed_data_check CHECK (
        (dataset_split = 'future' AND actual_price_rub IS NULL
         AND abs_error_rub IS NULL AND ape_pct IS NULL)
        OR
        (dataset_split = 'test' AND actual_price_rub IS NOT NULL
         AND actual_price_rub > 0 AND abs_error_rub IS NOT NULL AND abs_error_rub >= 0
         AND ape_pct IS NOT NULL AND ape_pct >= 0)
    )
);
CREATE INDEX IF NOT EXISTS ml_predictions_split_date_idx
    ON mart.ml_price_predictions (dataset_split, loading_date);

CREATE TABLE IF NOT EXISTS mart.ml_model_runs (
    run_id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    model_name             text NOT NULL,
    random_seed            integer NOT NULL,
    train_start            date NOT NULL,
    train_end_exclusive    date NOT NULL,
    test_start             date NOT NULL,
    test_end               date NOT NULL,
    train_rows             integer NOT NULL CHECK (train_rows > 0),
    test_rows              integer NOT NULL CHECK (test_rows > 0),
    future_rows            integer NOT NULL CHECK (future_rows >= 0),
    r2                     double precision NOT NULL,
    mape_pct               double precision NOT NULL,
    rmse_rub               double precision NOT NULL,
    mae_rub                double precision NOT NULL,
    features               jsonb NOT NULL,
    trained_at             timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ml_model_runs_train_window CHECK (train_start < train_end_exclusive),
    CONSTRAINT ml_model_runs_test_window CHECK (test_start <= test_end)
);
COMMIT;

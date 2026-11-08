-- Fresh-database acceptance gates: deterministic employer seed + all output layers.
-- Use psql -X -v ON_ERROR_STOP=1 -f /tmp/12_cleanroom_assertions.sql.
DO $$
DECLARE
    n_source bigint;
    n_core bigint;
    n_bad bigint;
    n_observations bigint;
    n_corridor bigint;
    n_test bigint;
    n_future bigint;
    n_leaks bigint;
    n_train bigint;
BEGIN
    SELECT count(*) INTO n_source FROM public.prices;
    SELECT count(*) INTO n_core FROM core.prices;
    SELECT count(*) INTO n_bad FROM core.dq_quarantine_prices;
    SELECT count(*) INTO n_observations FROM mart.market_observations;
    SELECT count(*) INTO n_corridor FROM mart.market_corridor;
    SELECT count(*) INTO n_test FROM mart.ml_price_predictions WHERE dataset_split = 'test';
    SELECT count(*) INTO n_future FROM mart.ml_price_predictions WHERE dataset_split = 'future';
    SELECT count(*) INTO n_leaks FROM mart.ml_price_predictions
      WHERE dataset_split = 'future'
        AND (actual_price_rub IS NOT NULL OR abs_error_rub IS NOT NULL OR ape_pct IS NOT NULL);
    SELECT train_rows INTO n_train FROM mart.ml_model_runs ORDER BY run_id DESC LIMIT 1;

    IF n_source <> 300000 OR n_core <> 299797 OR n_bad <> 203 THEN
        RAISE EXCEPTION 'Clean-room source/core/quarantine mismatch: %/%/%', n_source,n_core,n_bad;
    END IF;
    IF n_observations <> 291020 OR n_corridor <> 203644 THEN
        RAISE EXCEPTION 'Clean-room mart mismatch: %/%',n_observations,n_corridor;
    END IF;
    IF n_train <> 24226 OR n_test <> 12808 OR n_future <> 5998 OR n_leaks <> 0 THEN
        RAISE EXCEPTION 'Clean-room ML mismatch: train %, test %, future %, leaks %',
          n_train,n_test,n_future,n_leaks;
    END IF;
    IF (SELECT status FROM core.etl_runs ORDER BY run_id DESC LIMIT 1) <> 'success' THEN
        RAISE EXCEPTION 'Clean-room ETL audit not successful';
    END IF;
    RAISE NOTICE '[PASS] CLEANROOM source=%, core=%, quarantine=%, observations=%, corridor=%, train=%, test=%, future=%, leaks=%',
      n_source,n_core,n_bad,n_observations,n_corridor,n_train,n_test,n_future,n_leaks;
END $$;

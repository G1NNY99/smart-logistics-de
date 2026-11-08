-- Read-only SQL regression checks for ML batch predictions.
DO $ml_assertions$
DECLARE
    expected_test bigint;
    expected_future bigint;
    actual_test bigint;
    actual_future bigint;
    latest mart.ml_model_runs%ROWTYPE;
BEGIN
    SELECT count(*) INTO expected_test
    FROM core.prices
    WHERE loading_date >= DATE '2026-10-05'
      AND loading_date <= DATE '2026-10-26'
      AND is_fact = TRUE AND complex = FALSE AND outlier_mark = FALSE
      AND price_rub > 0 AND distance_km > 0;
    SELECT count(*) INTO expected_future
    FROM core.prices
    WHERE loading_date > DATE '2026-10-26';
    SELECT count(*) FILTER (WHERE dataset_split = 'test'),
           count(*) FILTER (WHERE dataset_split = 'future')
    INTO actual_test, actual_future
    FROM mart.ml_price_predictions;
    IF actual_test <> expected_test OR actual_future <> expected_future
       OR expected_test <= 0 OR expected_future <= 0 THEN
        RAISE EXCEPTION 'Cohort coverage mismatch: expected test/future=%/%, actual=%/%',
            expected_test, expected_future, actual_test, actual_future;
    END IF;
    RAISE NOTICE '[PASS] All eligible test and future prices were scored exactly once';

    IF EXISTS (
        SELECT 1 FROM mart.ml_price_predictions AS m
        JOIN core.prices AS p USING (price_id)
        WHERE m.loading_date <> p.loading_date
           OR (m.dataset_split = 'test' AND (
                m.loading_date NOT BETWEEN DATE '2026-10-05' AND DATE '2026-10-26'
                OR p.is_fact IS FALSE OR p.complex IS TRUE OR p.outlier_mark IS TRUE
                OR m.actual_price_rub IS NULL OR m.abs_error_rub IS NULL
                OR m.ape_pct IS NULL OR m.actual_price_rub <> p.price_rub
           ))
           OR (m.dataset_split = 'future' AND m.loading_date <= DATE '2026-10-26')
    ) THEN
        RAISE EXCEPTION 'Incorrect ML split/label or date relation';
    END IF;
    IF EXISTS (
        SELECT 1 FROM mart.ml_price_predictions
        WHERE dataset_split = 'future' AND (
            actual_price_rub IS NOT NULL OR abs_error_rub IS NOT NULL OR ape_pct IS NOT NULL
        )
    ) THEN
        RAISE EXCEPTION 'Future target leaked into predictions';
    END IF;
    RAISE NOTICE '[PASS] Exact chronological test split; future targets and errors are NULL';

    IF EXISTS (
        SELECT 1 FROM mart.ml_price_predictions
        WHERE dataset_split = 'test' AND (
            abs_error_rub <> abs(actual_price_rub - predicted_price_rub)
            OR ape_pct <> round((abs(actual_price_rub - predicted_price_rub)
                                 / actual_price_rub * 100), 4)
        )
    ) THEN
        RAISE EXCEPTION 'Error/APE not consistent with actual and predicted rates';
    END IF;
    RAISE NOTICE '[PASS] Test absolute and percentage errors match predictions';

    SELECT * INTO latest FROM mart.ml_model_runs ORDER BY run_id DESC LIMIT 1;
    IF NOT FOUND OR latest.test_rows <> actual_test
       OR latest.future_rows <> actual_future
       OR latest.random_seed <> 20261026
       OR latest.train_start <> DATE '2026-07-26'
       OR latest.train_end_exclusive <> DATE '2026-10-05'
       OR latest.test_start <> DATE '2026-10-05'
       OR latest.test_end <> DATE '2026-10-26'
       OR latest.r2 IS NULL OR latest.mape_pct IS NULL
       OR latest.rmse_rub IS NULL OR latest.mae_rub IS NULL
       OR latest.features ? 'price_rub'
       OR latest.features ? 'price_km_rub'
       OR latest.features ? 'outlier_mark'
       OR latest.features ? 'price_group_id' THEN
        RAISE EXCEPTION 'Invalid ML audit, features or training dates';
    END IF;
    RAISE NOTICE '[PASS] Run audit, fixed dates, random seed and feature safety';
END;
$ml_assertions$;

SELECT model_name, run_id, train_rows, test_rows, future_rows,
       round(r2::numeric, 4) AS r2,
       round(mape_pct::numeric, 2) AS mape_pct,
       round(rmse_rub::numeric, 2) AS rmse_rub,
       round(mae_rub::numeric, 2) AS mae_rub
FROM mart.ml_model_runs ORDER BY run_id DESC LIMIT 1;
SELECT dataset_split, COUNT(*) AS predictions,
       COUNT(actual_price_rub) AS with_actual,
       COUNT(abs_error_rub) AS with_error
FROM mart.ml_price_predictions GROUP BY dataset_split ORDER BY dataset_split;
SELECT '[PASS] ML database assertions finished successfully.' AS result;

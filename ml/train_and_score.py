"""Train CatBoost on a strict historical time split and score test + future.

Run inside Docker using libpq PG* environment variables. PostgreSQL is the
source of labels and the destination for idempotent batch predictions.
"""
from __future__ import annotations

import json
import logging
import math
import os
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd
import psycopg
from catboost import CatBoostRegressor
from psycopg.rows import dict_row
from sklearn.metrics import (
    mean_absolute_error,
    mean_absolute_percentage_error,
    mean_squared_error,
    r2_score,
)

from ml.features import (
    AS_OF,
    CATEGORICAL_FEATURES,
    FEATURE_COLUMNS,
    MODEL_NAME,
    RANDOM_SEED,
    TEST_START,
    TRAIN_START,
    make_features,
    score_records,
    split_for_loading_date,
)

ROOT = Path(__file__).resolve().parents[1]
SQL_DIR = ROOT / "sql"
ARTIFACT_DIR = ROOT / "artifacts"
LOG = logging.getLogger("smart_logistics.ml")


def sql_file(name: str) -> str:
    return (SQL_DIR / name).read_text(encoding="utf-8")


def load_cohort(conn: psycopg.Connection) -> pd.DataFrame:
    with conn.cursor(row_factory=dict_row) as cursor:
        cursor.execute(
            sql_file("12_ml_features.sql"),
            {"train_start": TRAIN_START, "as_of": AS_OF},
        )
        data = cursor.fetchall()
    if not data:
        raise RuntimeError("No rows returned for ML cohorts")
    cohort = pd.DataFrame(data)
    if cohort["price_id"].duplicated().any():
        raise RuntimeError("Feature SQL multiplied prices: duplicated price_id")
    cohort["dataset_split"] = cohort["loading_date"].map(split_for_loading_date)
    if cohort["dataset_split"].isna().any():
        raise RuntimeError("A row lies outside the train/test/future date windows")
    # Defense in depth: future labels must be NULL before any model operation.
    if cohort.loc[cohort.dataset_split == "future", "actual_price_rub"].notna().any():
        raise RuntimeError("Potential future target leakage detected")
    return cohort


def fit_and_evaluate(cohort: pd.DataFrame, seed: int, iterations: int, threads: int):
    features = make_features(cohort)
    train_mask = cohort.dataset_split.eq("train").to_numpy()
    test_mask = cohort.dataset_split.eq("test").to_numpy()
    future_mask = cohort.dataset_split.eq("future").to_numpy()

    n_train, n_test, n_future = (int(m.sum()) for m in (train_mask, test_mask, future_mask))
    if n_train < 100 or n_test < 30 or n_future == 0:
        raise RuntimeError(
            f"Unexpected cohort sizes: train={n_train}, test={n_test}, future={n_future}"
        )

    y_train = pd.to_numeric(cohort.loc[train_mask, "actual_price_rub"], errors="raise").to_numpy(dtype=float)
    y_test = pd.to_numeric(cohort.loc[test_mask, "actual_price_rub"], errors="raise").to_numpy(dtype=float)
    if not (np.isfinite(y_train).all() and np.isfinite(y_test).all()):
        raise RuntimeError("Missing or non-finite historical targets")
    if (y_train <= 0).any() or (y_test <= 0).any():
        raise RuntimeError("Training/test targets must be positive")

    model = CatBoostRegressor(
        iterations=iterations,
        depth=6,
        learning_rate=0.07,
        loss_function="RMSE",
        l2_leaf_reg=4,
        random_seed=seed,
        thread_count=threads,
        verbose=False,
        allow_writing_files=False,
    )
    LOG.info("Training CatBoost: train=%s test=%s future=%s features=%s", n_train, n_test, n_future, len(FEATURE_COLUMNS))
    model.fit(features.loc[train_mask], y_train, cat_features=list(CATEGORICAL_FEATURES))

    # Never fit or tune on test. Predictions are clipped to valid positive tariffs.
    test_predictions = np.maximum(model.predict(features.loc[test_mask]), 0.01)
    future_predictions = np.maximum(model.predict(features.loc[future_mask]), 0.01)
    metrics = {
        "r2": float(r2_score(y_test, test_predictions)),
        "mape_pct": float(100 * mean_absolute_percentage_error(y_test, test_predictions)),
        "rmse_rub": float(math.sqrt(mean_squared_error(y_test, test_predictions))),
        "mae_rub": float(mean_absolute_error(y_test, test_predictions)),
    }
    if not all(math.isfinite(v) for v in metrics.values()):
        raise RuntimeError(f"ML metrics are not finite: {metrics}")
    scores = pd.concat(
        [
            cohort.loc[test_mask].assign(prediction=test_predictions),
            cohort.loc[future_mask].assign(prediction=future_predictions),
        ],
        ignore_index=True,
    ).sort_values("price_id", kind="stable")
    return model, scores, metrics, (n_train, n_test, n_future)


def save_predictions(conn, records: list[tuple], metrics: dict, counts: tuple, seed: int) -> int:
    if not records:
        raise ValueError("No predictions to store")
    # Replacing the active model predictions is atomic. The advisory lock
    # serializes concurrent ML jobs for this project database.
    with conn.transaction():
        with conn.cursor() as cur:
            cur.execute("SELECT pg_advisory_xact_lock(20261026, 63)")
            cur.execute("DELETE FROM mart.ml_price_predictions")
            with cur.copy(
                """COPY mart.ml_price_predictions (
                    price_id, loading_date, loading_city_gcid, unloading_city_gcid,
                    body_group, dataset_split, actual_price_rub, predicted_price_rub,
                    abs_error_rub, ape_pct, model_name
                ) FROM STDIN"""
            ) as copy:
                for record in records:
                    copy.write_row(record)
            cur.execute(
                """INSERT INTO mart.ml_model_runs (
                    model_name, random_seed, train_start, train_end_exclusive,
                    test_start, test_end, train_rows, test_rows, future_rows,
                    r2, mape_pct, rmse_rub, mae_rub, features
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s,
                          %s, %s, %s, %s, %s::jsonb)
                RETURNING run_id""",
                (
                    MODEL_NAME, seed, TRAIN_START, TEST_START, TEST_START, AS_OF,
                    *counts, metrics["r2"], metrics["mape_pct"],
                    metrics["rmse_rub"], metrics["mae_rub"],
                    json.dumps(list(FEATURE_COLUMNS)),
                ),
            )
            run_id = int(cur.fetchone()[0])
    return run_id


def run() -> None:
    seed = int(os.getenv("ML_RANDOM_SEED", str(RANDOM_SEED)))
    iterations = int(os.getenv("ML_ITERATIONS", "350"))
    threads = int(os.getenv("ML_THREADS", "4"))
    if iterations < 10 or not (1 <= threads <= 16):
        raise ValueError("ML_ITERATIONS must be >= 10; ML_THREADS in [1,16]")
    np.random.seed(seed)

    LOG.info("Starting ML pipeline, as_of=%s, train=[%s,%s), test=[%s,%s]",
             AS_OF, TRAIN_START, TEST_START, TEST_START, AS_OF)
    with psycopg.connect(autocommit=True, connect_timeout=20) as conn:
        conn.execute(sql_file("11_ml_predictions.sql"))
        cohort = load_cohort(conn)
        model, scores, metrics, counts = fit_and_evaluate(cohort, seed, iterations, threads)

        predictions = np.asarray(scores["prediction"].to_numpy(dtype=float))
        records = list(score_records(scores.drop(columns="prediction"), predictions))
        if len(records) != counts[1] + counts[2]:
            raise RuntimeError("Scoring did not cover all test and future records")
        run_id = save_predictions(conn, records, metrics, counts, seed)

    ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
    model.save_model(str(ARTIFACT_DIR / "catboost_v1.cbm"))
    report = {
        "run_id": run_id,
        "model_name": MODEL_NAME,
        "as_of": AS_OF.isoformat(),
        "train_start": TRAIN_START.isoformat(),
        "train_end_exclusive": TEST_START.isoformat(),
        "test_start": TEST_START.isoformat(),
        "test_end_inclusive": AS_OF.isoformat(),
        "train_rows": counts[0],
        "test_rows": counts[1],
        "future_rows": counts[2],
        "random_seed": seed,
        "iterations": iterations,
        "features": list(FEATURE_COLUMNS),
        **metrics,
    }
    (ARTIFACT_DIR / "ml_metrics.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    LOG.info("ML_SUCCESS %s", json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    run()

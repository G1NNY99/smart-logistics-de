"""Target-safe feature engineering and deterministic chronological split.

Importantly, *only* FEATURE_COLUMNS are passed to CatBoost. This is an
allowlist, not a dynamic dataframe.drop() of a few prohibited columns.
"""
from __future__ import annotations

from datetime import date
from decimal import Decimal, ROUND_HALF_UP
from typing import Iterator

import numpy as np
import pandas as pd

AS_OF = date(2026, 10, 26)
TRAIN_START = date(2026, 7, 26)
TEST_START = date(2026, 10, 5)
MODEL_NAME = "catboost_v1"
RANDOM_SEED = 20261026

CATEGORICAL_FEATURES = (
    "origin_city", "destination_city", "origin_region", "destination_region",
    "body_group", "weight_category", "volume_category", "price_type",
)
NUMERICAL_FEATURES = (
    "distance_km", "total_weight", "total_volume",
    "origin_lat", "origin_lon", "destination_lat", "destination_lon",
    "year", "month", "day_of_week", "day_of_year",
    "month_sin", "month_cos", "weekday_sin", "weekday_cos",
    "yearday_sin", "yearday_cos",
)
FEATURE_COLUMNS = CATEGORICAL_FEATURES + NUMERICAL_FEATURES

# Leaky or post-factum information must NEVER enter the feature allowlist.
FORBIDDEN_FEATURES = {
    "price_rub", "actual_price_rub", "predicted_price_rub", "price_original",
    "price_km_rub", "price_with_vat", "customer_cost", "carrier_cost",
    "transportation_cost", "profit", "price_group_id", "avg_price",
    "min_km_price", "max_km_price", "outlier_mark", "is_fact",
    "created_at", "updated_at", "etl_loaded_at", "scored_at",
}
assert not set(FEATURE_COLUMNS).intersection(FORBIDDEN_FEATURES)


def split_for_loading_date(value: date) -> str | None:
    """Time split: train [Jul-26, Oct-05), test [Oct-05, Oct-26]."""
    if isinstance(value, pd.Timestamp):
        value = value.date()
    if TRAIN_START <= value < TEST_START:
        return "train"
    if TEST_START <= value <= AS_OF:
        return "test"
    if value > AS_OF:
        return "future"
    return None


def make_features(source: pd.DataFrame) -> pd.DataFrame:
    """Build feature frame with no fitted transformations or target columns."""
    frame = source.copy()
    dates = pd.to_datetime(frame["loading_date"], errors="raise")
    frame["year"] = dates.dt.year.astype("int32")
    frame["month"] = dates.dt.month.astype("int32")
    frame["day_of_week"] = dates.dt.dayofweek.astype("int32")  # Monday = 0
    frame["day_of_year"] = dates.dt.dayofyear.astype("int32")

    phase = 2.0 * np.pi
    frame["month_sin"] = np.sin(phase * (frame["month"] - 1) / 12.0)
    frame["month_cos"] = np.cos(phase * (frame["month"] - 1) / 12.0)
    frame["weekday_sin"] = np.sin(phase * frame["day_of_week"] / 7.0)
    frame["weekday_cos"] = np.cos(phase * frame["day_of_week"] / 7.0)
    frame["yearday_sin"] = np.sin(phase * (frame["day_of_year"] - 1) / 365.25)
    frame["yearday_cos"] = np.cos(phase * (frame["day_of_year"] - 1) / 365.25)

    for column in CATEGORICAL_FEATURES:
        frame[column] = frame[column].fillna("UNKNOWN").astype(str).replace("", "UNKNOWN")
    for column in NUMERICAL_FEATURES:
        frame[column] = pd.to_numeric(frame[column], errors="raise").astype("float64")

    result = frame.loc[:, FEATURE_COLUMNS].copy()
    if len(result.columns) != len(set(result.columns)):
        raise AssertionError("Duplicate feature names")
    return result


def _rub(value: object) -> Decimal:
    return Decimal(str(value)).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def score_records(
    cohort: pd.DataFrame, predictions: np.ndarray, model_name: str = MODEL_NAME
) -> Iterator[tuple]:
    """Convert predictions to COPY rows. Future labels are always explicitly NULL.

    This is a second guardrail even if future labels were accidentally included
    in a source dataframe. Those values are NEVER used for future error metrics.
    """
    if len(cohort) != len(predictions):
        raise ValueError("Predictions and rows have different lengths")
    for row, prediction in zip(cohort.itertuples(index=False), predictions, strict=True):
        split = row.dataset_split
        if split not in ("test", "future"):
            raise ValueError(f"Unexpected split in scoring: {split}")
        if not np.isfinite(float(prediction)):
            raise ValueError(f"Non-finite prediction for price_id={row.price_id}")
        pred = _rub(float(prediction))
        if pred <= 0:
            raise ValueError(f"Non-positive/non-finite prediction for price_id={row.price_id}")

        if split == "future":
            actual = None
            absolute_error = None
            ape = None
        else:
            actual = _rub(row.actual_price_rub)
            if actual <= 0:
                raise ValueError(f"Invalid actual for test price_id={row.price_id}")
            absolute_error = abs(actual - pred)
            ape = ((absolute_error / actual) * 100).quantize(
                Decimal("0.0001"), rounding=ROUND_HALF_UP
            )

        loading_date = row.loading_date
        if isinstance(loading_date, pd.Timestamp):
            loading_date = loading_date.date()
        yield (
            int(row.price_id), loading_date,
            int(row.loading_city_gcid), int(row.unloading_city_gcid),
            str(row.body_group), str(split), actual, pred,
            absolute_error, ape, str(model_name),
        )

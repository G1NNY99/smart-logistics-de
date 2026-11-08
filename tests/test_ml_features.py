"""Small offline tests: feature allowlist, date boundaries and future masking."""
from __future__ import annotations

import math
import unittest
from datetime import date
from decimal import Decimal

import numpy as np
import pandas as pd

from ml.features import (
    CATEGORICAL_FEATURES,
    FEATURE_COLUMNS,
    FORBIDDEN_FEATURES,
    make_features,
    score_records,
    split_for_loading_date,
)


class FeatureEngineeringTests(unittest.TestCase):
    @staticmethod
    def fixture(loading_date: str) -> pd.DataFrame:
        return pd.DataFrame([{
            "price_id": 7,
            "loading_date": date.fromisoformat(loading_date),
            "loading_city_gcid": 1001,
            "unloading_city_gcid": 1003,
            "distance_km": Decimal("812.5"),
            "total_weight": Decimal("17.2"),
            "total_volume": Decimal("95.0"),
            "weight_category": "FTL", "volume_category": "FTL",
            "price_type": 3,
            "origin_city": "Москва", "destination_city": "Казань",
            "origin_region": "г. Москва", "destination_region": "Республика Татарстан",
            "origin_lat": 55.75, "origin_lon": 37.62,
            "destination_lat": 55.79, "destination_lon": 49.11,
            "body_group": "Тент",
            "actual_price_rub": Decimal("123456.78"),
            "price_rub": Decimal("123456.78"),
            "price_km_rub": Decimal("151.94"),
            "outlier_mark": False,
        }])

    def test_train_test_future_boundaries(self):
        expected = {
            date(2026, 7, 25): None,
            date(2026, 7, 26): "train",
            date(2026, 10, 4): "train",
            date(2026, 10, 5): "test",
            date(2026, 10, 26): "test",
            date(2026, 10, 27): "future",
        }
        for value, split in expected.items():
            self.assertEqual(split_for_loading_date(value), split)

    def test_only_explicit_allowlist_reaches_model(self):
        features = make_features(self.fixture("2026-10-05"))
        self.assertEqual(tuple(features.columns), FEATURE_COLUMNS)
        self.assertFalse(set(features.columns) & FORBIDDEN_FEATURES)
        self.assertNotIn("actual_price_rub", features)
        self.assertNotIn("outlier_mark", features)
        self.assertTrue(all(features[col].dtype == "object" for col in CATEGORICAL_FEATURES))
        self.assertEqual(features.iloc[0]["origin_region"], "г. Москва")

    def test_year_end_cyclical_encoding_is_continuous(self):
        december = make_features(self.fixture("2025-12-31")).iloc[0]
        january = make_features(self.fixture("2026-01-01")).iloc[0]
        month_distance = math.hypot(
            december.month_sin - january.month_sin,
            december.month_cos - january.month_cos,
        )
        year_day_distance = math.hypot(
            december.yearday_sin - january.yearday_sin,
            december.yearday_cos - january.yearday_cos,
        )
        self.assertLess(month_distance, 0.55)
        self.assertLess(year_day_distance, 0.03)
        self.assertAlmostEqual(january.month_sin, 0.0, places=12)

    def test_future_labels_are_forced_to_null_even_if_present_in_input(self):
        future = self.fixture("2026-10-27").assign(dataset_split="future")
        records = list(score_records(future, np.array([127500.25])))
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0][5], "future")
        self.assertIsNone(records[0][6])
        self.assertIsNone(records[0][8])
        self.assertIsNone(records[0][9])
        self.assertEqual(records[0][7], Decimal("127500.25"))

    def test_test_error_and_ape_are_calculated(self):
        test = self.fixture("2026-10-05").assign(dataset_split="test")
        records = list(score_records(test, np.array([120000.00])))
        self.assertEqual(records[0][6], Decimal("123456.78"))
        self.assertEqual(records[0][8], Decimal("3456.78"))
        self.assertGreater(records[0][9], Decimal("2.7"))


if __name__ == "__main__":
    unittest.main()

"""Idempotent date-window ETL; set-based SQL transformations orchestrated by Python.

Environment variables: PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD,
ETL_START_DATE and ETL_END_DATE. No passwords are stored in the source code.
"""

from __future__ import annotations

import json
import logging
import os
from datetime import date
from pathlib import Path

import psycopg

LOG = logging.getLogger("smart_logistics.etl")
ROOT = Path(__file__).resolve().parents[1]
SQL = ROOT / "sql"


def load_sql(name: str) -> str:
    return (SQL / name).read_text(encoding="utf-8")


def load_window() -> tuple[date, date]:
    start = date.fromisoformat(os.getenv("ETL_START_DATE", "2023-01-01"))
    end = date.fromisoformat(os.getenv("ETL_END_DATE", "2027-12-31"))
    if start > end:
        raise ValueError("ETL_START_DATE must be <= ETL_END_DATE")
    return start, end


def run() -> None:
    start, end = load_window()
    LOG.info("Starting ETL: inclusive loading_date window [%s, %s]", start, end)

    # libpq reads PGHOST/PGPORT/PGDATABASE/PGUSER/PGPASSWORD from environment.
    with psycopg.connect(autocommit=True, connect_timeout=20) as conn:
        # Auto-create the Core layer on a fresh database. The schema SQL is
        # transaction-wrapped and re-runnable (CREATE IF NOT EXISTS).
        conn.execute(load_sql("01_core.sql"))

        # Commit the run identifier before the data transaction. If the data
        # transaction fails, a separate transaction can mark the audit as failed.
        with conn.transaction():
            run_id = conn.execute(
                """INSERT INTO core.etl_runs (start_date, end_date)
                   VALUES (%s, %s) RETURNING run_id""",
                (start, end),
            ).fetchone()[0]

        try:
            with conn.transaction():
                with conn.cursor() as cur:
                    # Serialize windows, including overlapping backfills.
                    cur.execute("SELECT pg_advisory_xact_lock(20261026, 42)")
                    cur.execute(
                        load_sql("03_etl_stage.sql"),
                        {"start_date": start, "end_date": end},
                    )
                    source_count, loaded_count, quarantine_count = cur.execute(
                        """SELECT count(*),
                                  count(*) FILTER (WHERE cardinality(reason_codes) = 0),
                                  count(*) FILTER (WHERE cardinality(reason_codes) > 0)
                           FROM etl_stage"""
                    ).fetchone()

                    # Atomic partition replacement: deletes and inserts either
                    # all commit or all roll back. PKs guarantee no duplicates.
                    cur.execute(
                        "DELETE FROM core.prices WHERE loading_date BETWEEN %s AND %s",
                        (start, end),
                    )
                    cur.execute(
                        "DELETE FROM core.dq_quarantine_prices "
                        "WHERE loading_date BETWEEN %s AND %s",
                        (start, end),
                    )
                    cur.execute(load_sql("04_etl_insert_core.sql"))
                    cur.execute(load_sql("05_etl_insert_quarantine.sql"))

                    reasons = cur.execute(
                        """SELECT reason_code, count(*)
                           FROM etl_stage CROSS JOIN LATERAL
                                unnest(reason_codes) AS reason_code
                           GROUP BY reason_code ORDER BY reason_code"""
                    ).fetchall()
                    cur.execute(
                        """UPDATE core.etl_runs
                           SET finished_at = now(), status = 'success',
                               source_count = %s, loaded_count = %s,
                               quarantine_count = %s
                           WHERE run_id = %s""",
                        (source_count, loaded_count, quarantine_count, run_id),
                    )

            LOG.info(
                "ETL_SUCCESS %s",
                json.dumps({
                    "run_id": run_id,
                    "start_date": start.isoformat(),
                    "end_date": end.isoformat(),
                    "source_count": source_count,
                    "loaded_count": loaded_count,
                    "quarantine_count": quarantine_count,
                    "quarantine_reasons": dict(reasons),
                }, ensure_ascii=False),
            )
        except Exception as exc:
            with conn.transaction():
                conn.execute(
                    """UPDATE core.etl_runs
                       SET finished_at = now(), status = 'failed',
                           error_message = left(%s, 4000)
                       WHERE run_id = %s""",
                    (str(exc), run_id),
                )
            LOG.exception("ETL_FAILED run_id=%s", run_id)
            raise


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    run()

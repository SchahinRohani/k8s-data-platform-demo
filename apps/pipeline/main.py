#!/usr/bin/env python3
"""Small demo pipeline: seed CSV data in S3, transform it with DuckDB."""

from __future__ import annotations

import argparse
import logging
import os
import tempfile
import time
from pathlib import Path

import boto3
import duckdb
from botocore.config import Config
from botocore.exceptions import ClientError


logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
LOG = logging.getLogger("demo-pipeline")

S3_ENDPOINT = os.getenv(
    "S3_ENDPOINT", "http://rustfs.storage.svc.cluster.local:9000"
)
RAW_BUCKET = os.getenv("RAW_BUCKET", "raw")
PROCESSED_BUCKET = os.getenv("PROCESSED_BUCKET", "processed")
RAW_KEY = os.getenv("RAW_KEY", "orders/orders.csv")
PROCESSED_KEY = os.getenv(
    "PROCESSED_KEY", "orders_by_country/orders_by_country.parquet"
)
INPUT_WAIT_SECONDS = int(os.getenv("INPUT_WAIT_SECONDS", "120"))


def s3_client():
    """Create an S3 client configured for an S3-compatible local endpoint."""
    return boto3.client(
        "s3",
        endpoint_url=S3_ENDPOINT,
        config=Config(
            signature_version="s3v4",
            s3={"addressing_style": "path"},
            retries={"max_attempts": 5, "mode": "standard"},
            request_checksum_calculation="when_required",
            response_checksum_validation="when_required",
        ),
    )


def object_exists(client, bucket: str, key: str) -> bool:
    try:
        client.head_object(Bucket=bucket, Key=key)
        return True
    except ClientError as exc:
        code = str(exc.response.get("Error", {}).get("Code", ""))
        if code in {"404", "NoSuchKey", "NotFound"}:
            return False
        raise


def wait_for_object(client, bucket: str, key: str, timeout: int) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if object_exists(client, bucket, key):
            return
        LOG.info("Waiting for s3://%s/%s", bucket, key)
        time.sleep(2)
    raise TimeoutError(f"s3://{bucket}/{key} did not appear within {timeout}s")


def seed(force: bool) -> None:
    client = s3_client()
    source = Path(__file__).parent / "data" / "orders.csv"

    if object_exists(client, RAW_BUCKET, RAW_KEY) and not force:
        LOG.info("s3://%s/%s already exists; nothing to do", RAW_BUCKET, RAW_KEY)
        return

    client.upload_file(
        str(source),
        RAW_BUCKET,
        RAW_KEY,
        ExtraArgs={"ContentType": "text/csv"},
    )
    LOG.info("Uploaded %s to s3://%s/%s", source, RAW_BUCKET, RAW_KEY)


def sql_string(value: Path) -> str:
    """Quote a local path as a DuckDB SQL string literal."""
    return "'" + str(value).replace("'", "''") + "'"


def transform() -> None:
    client = s3_client()
    wait_for_object(client, RAW_BUCKET, RAW_KEY, INPUT_WAIT_SECONDS)

    with tempfile.TemporaryDirectory(prefix="demo-pipeline-") as directory:
        workdir = Path(directory)
        input_csv = workdir / "orders.csv"
        output_parquet = workdir / "orders_by_country.parquet"
        client.download_file(RAW_BUCKET, RAW_KEY, str(input_csv))

        connection = duckdb.connect()
        try:
            connection.execute(
                f"""
                COPY (
                    SELECT
                        customer_country,
                        count(*) AS order_count,
                        round(sum(amount), 2) AS revenue
                    FROM read_csv_auto({sql_string(input_csv)}, header = true)
                    WHERE status = 'completed'
                    GROUP BY customer_country
                    ORDER BY revenue DESC, customer_country
                )
                TO {sql_string(output_parquet)}
                (FORMAT PARQUET, COMPRESSION ZSTD)
                """
            )
            rows = connection.execute(
                f"SELECT * FROM read_parquet({sql_string(output_parquet)})"
            ).fetchall()
        finally:
            connection.close()

        client.upload_file(
            str(output_parquet),
            PROCESSED_BUCKET,
            PROCESSED_KEY,
            ExtraArgs={"ContentType": "application/vnd.apache.parquet"},
        )

    LOG.info("Wrote %d rows to s3://%s/%s", len(rows), PROCESSED_BUCKET, PROCESSED_KEY)
    for country, order_count, revenue in rows:
        LOG.info(
            "country=%s order_count=%s revenue=%s", country, order_count, revenue
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    seed_parser = commands.add_parser("seed", help="Upload bundled demo CSV")
    seed_parser.add_argument(
        "--force", action="store_true", help="Replace an existing raw object"
    )
    commands.add_parser("transform", help="Aggregate the raw CSV and write Parquet")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.command == "seed":
        seed(args.force)
    else:
        transform()


if __name__ == "__main__":
    main()

"""Database access layer for Azure SQL."""

from __future__ import annotations

import logging
import threading
from typing import Tuple

import certifi
import pytds

from config import Settings
from quotes import FAMOUS_QUOTES

LOGGER = logging.getLogger(__name__)


class QuoteRepository:
    def __init__(self, settings: Settings) -> None:
        # Stores immutable connection settings and local state for one-time schema bootstrap.
        self._settings = settings
        self._seed_lock = threading.Lock()
        self._seeded = False

    def _connect(self) -> pytds.Connection:
        # Opens an encrypted SQL connection with certificate validation for secure data transport.
        return pytds.connect(
            server=self._settings.sql_server_fqdn,
            database=self._settings.sql_database_name,
            user=self._settings.sql_username,
            password=self._settings.sql_password,
            encrypt=True,
            validate_host=True,
            cafile=certifi.where(),
            login_timeout=15,
            timeout=30,
            as_dict=True,
            autocommit=True,
            appname="critical-pii-quotes-app",
        )

    def ensure_schema_and_seed(self) -> None:
        # Creates the quotes table and inserts defaults exactly once per process in an idempotent way.
        if self._seeded:
            return

        with self._seed_lock:
            if self._seeded:
                return

            with self._connect() as connection:
                with connection.cursor() as cursor:
                    cursor.execute(
                        """
                        IF OBJECT_ID(N'dbo.Quotes', N'U') IS NULL
                        BEGIN
                            CREATE TABLE dbo.Quotes (
                                quote_id INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
                                quote_text NVARCHAR(1024) NOT NULL,
                                quote_author NVARCHAR(256) NOT NULL,
                                pii_classification NVARCHAR(64) NOT NULL
                                    CONSTRAINT DF_Quotes_PiiClassification DEFAULT ('CRITICAL_PII'),
                                created_utc DATETIME2(3) NOT NULL
                                    CONSTRAINT DF_Quotes_CreatedUtc DEFAULT (SYSUTCDATETIME())
                            );

                            CREATE UNIQUE INDEX UX_Quotes_TextAuthor
                                ON dbo.Quotes (quote_text, quote_author);
                        END;
                        """
                    )

                    for quote_text, quote_author in FAMOUS_QUOTES:
                        # Inserts only missing seed rows so repeated starts do not duplicate application data.
                        cursor.execute(
                            """
                            INSERT INTO dbo.Quotes (quote_text, quote_author)
                            SELECT %s, %s
                            WHERE NOT EXISTS (
                                SELECT 1
                                FROM dbo.Quotes
                                WHERE quote_text = %s
                                  AND quote_author = %s
                            );
                            """,
                            (quote_text, quote_author, quote_text, quote_author),
                        )

            self._seeded = True
            LOGGER.info("Quotes table verified and seeded idempotently.")

    def get_random_quote(self) -> Tuple[str, str]:
        # Ensures schema exists, then fetches one random row for the UI/API response path.
        self.ensure_schema_and_seed()

        with self._connect() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT TOP 1 quote_text, quote_author
                    FROM dbo.Quotes WITH (READPAST)
                    ORDER BY NEWID();
                    """
                )
                row = cursor.fetchone()

        if not row:
            raise RuntimeError("No quote rows available in dbo.Quotes.")

        return str(row["quote_text"]), str(row["quote_author"])

    def ping(self) -> bool:
        # Performs a lightweight DB check used by health endpoints and platform probes.
        try:
            with self._connect() as connection:
                with connection.cursor() as cursor:
                    cursor.execute("SELECT 1 AS ok;")
                    row = cursor.fetchone()
                    return bool(row and row["ok"] == 1)
        except Exception:  # pylint: disable=broad-exception-caught
            LOGGER.exception("Health probe failed while checking SQL connectivity.")
            return False

"""Configuration and secret-loading utilities."""

from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache

from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient


@dataclass(frozen=True)
class Settings:
    # Captures runtime config needed to build secure SQL connections and app metadata.
    sql_server_fqdn: str
    sql_database_name: str
    sql_username: str
    sql_password: str
    app_title: str


@lru_cache(maxsize=1)
def load_settings() -> Settings:
    # Reads required connection settings from environment variables provided by infrastructure/app config.
    sql_server_fqdn = os.environ["SQL_SERVER_FQDN"]
    sql_database_name = os.environ["SQL_DATABASE_NAME"]
    sql_username = os.environ["SQL_USERNAME"]
    app_title = os.environ.get("APP_TITLE", "Critical PII Quote Vault")

    key_vault_uri = os.environ.get("KEY_VAULT_URI")
    password_secret_name = os.environ.get("SQL_PASSWORD_SECRET_NAME")

    if key_vault_uri and password_secret_name:
        # Prefers managed identity + Key Vault so SQL secrets are not stored as plain app settings.
        credential = DefaultAzureCredential()
        client = SecretClient(vault_url=key_vault_uri, credential=credential)
        sql_password = client.get_secret(password_secret_name).value
    else:
        # Falls back to direct env var for local/dev runs where Key Vault integration is unavailable.
        sql_password = os.environ["SQL_PASSWORD"]

    return Settings(
        sql_server_fqdn=sql_server_fqdn,
        sql_database_name=sql_database_name,
        sql_username=sql_username,
        sql_password=sql_password,
        app_title=app_title,
    )

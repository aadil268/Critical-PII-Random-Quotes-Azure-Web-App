"""Flask entrypoint for random quote app."""

from __future__ import annotations

import logging
import os
from functools import lru_cache
from http import HTTPStatus

from flask import Flask, jsonify, render_template

from config import load_settings
from db import QuoteRepository

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
# Initializes process-wide logging early so startup and request failures are consistently captured.
logging.basicConfig(level=LOG_LEVEL, format="%(asctime)s %(levelname)s %(name)s %(message)s")
LOGGER = logging.getLogger(__name__)

# Creates the Flask application object used by both local run and App Service hosting.
app = Flask(__name__)


@lru_cache(maxsize=1)
def get_repository() -> QuoteRepository:
    # Reuses one repository instance per worker to avoid rebuilding DB configuration each request.
    settings = load_settings()
    return QuoteRepository(settings=settings)


@app.after_request
def add_security_headers(response):
    # Applies baseline browser hardening headers to reduce common client-side attack vectors.
    response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Referrer-Policy"] = "no-referrer"
    response.headers["Content-Security-Policy"] = (
        "default-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; "
        "img-src 'self' data:; font-src 'self' https://fonts.gstatic.com data:; script-src 'self'"
    )
    return response


@app.route("/")
def index():
    # Renders the HTML view backed by a SQL quote lookup, with graceful fallback when data access fails.
    app_title = os.environ.get("APP_TITLE", "Critical PII Quote Vault")
    try:
        repository = get_repository()
        settings = load_settings()
        quote_text, quote_author = repository.get_random_quote()
        app_title = settings.app_title
        return render_template(
            "index.html",
            app_title=app_title,
            quote_text=quote_text,
            quote_author=quote_author,
        )
    except Exception:  # pylint: disable=broad-exception-caught
        LOGGER.exception("Failed to fetch quote from SQL.")
        return render_template(
            "index.html",
            app_title=app_title,
            quote_text="Quote temporarily unavailable.",
            quote_author="Please try again shortly",
        ), HTTPStatus.SERVICE_UNAVAILABLE


@app.route("/api/quote")
def api_quote():
    # Returns a machine-readable quote payload for API clients and frontend integrations.
    repository = get_repository()
    quote_text, quote_author = repository.get_random_quote()
    return jsonify({"quote": quote_text, "author": quote_author})


@app.route("/healthz")
def healthz():
    # Exposes readiness/liveness status based on active SQL connectivity for platform health probes.
    repository = get_repository()
    if repository.ping():
        return jsonify({"status": "ok"}), HTTPStatus.OK
    return jsonify({"status": "unhealthy"}), HTTPStatus.SERVICE_UNAVAILABLE


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))

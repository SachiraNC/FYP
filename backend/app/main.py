"""FastAPI application factory.

Run:  uvicorn app.main:create_app --factory
"""
from __future__ import annotations

import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from . import db
from .config import Settings
from .routers import audit_log, auth, hosts
from .vault import Vault, VaultError

log = logging.getLogger(__name__)


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    vault = Vault.from_env()  # fail fast: no master key, no API
    db.init_db(settings.db_path)

    app = FastAPI(title="CIS Compliance Platform API", version="0.1.0")
    app.state.settings = settings
    app.state.vault = vault

    @app.exception_handler(RequestValidationError)
    async def _validation_error(request: Request, exc: RequestValidationError):
        # FastAPI's default 422 body echoes the submitted input, which may contain passwords
        # or private keys. Return location, message and type only.
        errors = [{"loc": list(e.get("loc", ())), "msg": e.get("msg", ""), "type": e.get("type", "")}
                  for e in exc.errors()]
        return JSONResponse(status_code=422, content={"detail": errors})

    @app.exception_handler(VaultError)
    async def _vault_error(request: Request, exc: VaultError):
        log.error("vault error: %s", exc)
        return JSONResponse(status_code=500, content={"detail": str(exc)})

    app.include_router(auth.router)
    app.include_router(hosts.router)
    app.include_router(audit_log.router)
    return app

"""FastAPI dependencies: DB connection, vault, settings, authenticated admin."""
from __future__ import annotations

import sqlite3
from collections.abc import Iterator
from dataclasses import dataclass

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from . import db
from .config import Settings
from .security import hash_token
from .vault import Vault

_bearer = HTTPBearer(auto_error=False)


@dataclass(frozen=True)
class Admin:
    id: int
    username: str
    token_hash: str


def get_settings(request: Request) -> Settings:
    return request.app.state.settings


def get_vault(request: Request) -> Vault:
    return request.app.state.vault


def get_db(request: Request) -> Iterator[sqlite3.Connection]:
    conn = db.connect(request.app.state.settings.db_path)
    try:
        yield conn
    finally:
        conn.close()


def client_ip(request: Request) -> str | None:
    return request.client.host if request.client else None


def current_admin(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
    conn: sqlite3.Connection = Depends(get_db),
) -> Admin:
    unauthorised = HTTPException(
        status.HTTP_401_UNAUTHORIZED, "not authenticated", headers={"WWW-Authenticate": "Bearer"}
    )
    if creds is None or creds.scheme.lower() != "bearer" or not creds.credentials:
        raise unauthorised
    token_hash = hash_token(creds.credentials)
    row = conn.execute(
        "SELECT a.id, a.username FROM sessions s JOIN admins a ON a.id = s.admin_id "
        "WHERE s.token_hash = ? AND s.expires_at > ? AND a.disabled = 0",
        (token_hash, db.utcnow()),
    ).fetchone()
    if row is None:
        raise unauthorised
    return Admin(row["id"], row["username"], token_hash)

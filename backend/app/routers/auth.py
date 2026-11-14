"""Local admin login / logout."""
from __future__ import annotations

import sqlite3

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status

from .. import audit, db
from ..config import Settings
from ..deps import Admin, client_ip, current_admin, get_db, get_settings
from ..schemas import AdminOut, LoginRequest, LoginResponse
from ..security import new_session_token, verify_password

router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.post("/login", response_model=LoginResponse)
def login(
    body: LoginRequest,
    request: Request,
    conn: sqlite3.Connection = Depends(get_db),
    settings: Settings = Depends(get_settings),
):
    row = conn.execute(
        "SELECT id, username, password_hash, disabled FROM admins WHERE username = ?", (body.username,)
    ).fetchone()
    ok = verify_password(body.password.get_secret_value(), row["password_hash"] if row else None)
    if not ok or row["disabled"]:
        audit.record(conn, actor=body.username, action="auth.login", outcome="failure",
                     client_ip=client_ip(request), details={"reason": "invalid credentials or disabled account"})
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid username or password")

    now = db.utcnow()
    conn.execute("DELETE FROM sessions WHERE expires_at <= ?", (now,))
    token, token_hash = new_session_token()
    expires_at = db.utc_in(settings.session_ttl_seconds)
    conn.execute(
        "INSERT INTO sessions (token_hash, admin_id, created_at, expires_at) VALUES (?, ?, ?, ?)",
        (token_hash, row["id"], now, expires_at),
    )
    audit.record(conn, actor=row["username"], action="auth.login", client_ip=client_ip(request),
                 details={"expires_at": expires_at})
    return LoginResponse(token=token, expires_at=expires_at)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(request: Request, admin: Admin = Depends(current_admin), conn: sqlite3.Connection = Depends(get_db)):
    conn.execute("DELETE FROM sessions WHERE token_hash = ?", (admin.token_hash,))
    audit.record(conn, actor=admin.username, action="auth.logout", client_ip=client_ip(request))
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/me", response_model=AdminOut)
def me(admin: Admin = Depends(current_admin)):
    return AdminOut(id=admin.id, username=admin.username)

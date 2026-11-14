"""Append-only audit log of every action.

``record`` refuses details that contain secret-looking keys, so a coding mistake
cannot write a credential into the log.
"""
from __future__ import annotations

import json
import sqlite3
from typing import Any

from .db import utcnow

SECRET_KEYS = frozenset({
    "password", "private_key", "key_passphrase", "sudo_password",
    "secret", "token", "master_key", "ciphertext",
})


def _reject_secret_keys(obj: Any) -> None:
    if isinstance(obj, dict):
        for k, v in obj.items():
            if str(k).lower() in SECRET_KEYS:
                raise ValueError(f"refusing to write secret field {k!r} to the audit log")
            _reject_secret_keys(v)
    elif isinstance(obj, (list, tuple)):
        for v in obj:
            _reject_secret_keys(v)


def record(
    conn: sqlite3.Connection,
    *,
    actor: str,
    action: str,
    outcome: str = "success",
    target: str | None = None,
    client_ip: str | None = None,
    details: dict[str, Any] | None = None,
) -> None:
    """Insert one audit entry and commit (together with any pending work on ``conn``)."""
    details = details or {}
    _reject_secret_keys(details)
    conn.execute(
        "INSERT INTO audit_log (ts, actor, action, target, outcome, client_ip, details) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        (utcnow(), actor, action, target, outcome, client_ip, json.dumps(details, sort_keys=True)),
    )
    conn.commit()


def list_entries(conn: sqlite3.Connection, *, limit: int = 100, before_id: int | None = None) -> list[dict]:
    sql = "SELECT * FROM audit_log"
    args: list[Any] = []
    if before_id is not None:
        sql += " WHERE id < ?"
        args.append(before_id)
    sql += " ORDER BY id DESC LIMIT ?"
    args.append(limit)
    out = []
    for r in conn.execute(sql, args):
        d = dict(r)
        d["details"] = json.loads(d["details"])
        out.append(d)
    return out

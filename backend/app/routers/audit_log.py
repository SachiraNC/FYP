"""Read-only access to the append-only audit log."""
from __future__ import annotations

import sqlite3

from fastapi import APIRouter, Depends, Query

from .. import audit
from ..deps import Admin, current_admin, get_db
from ..schemas import AuditEntry

router = APIRouter(prefix="/api/audit-log", tags=["audit"])


@router.get("", response_model=list[AuditEntry])
def list_audit_log(
    limit: int = Query(100, ge=1, le=1000),
    before_id: int | None = Query(None, ge=1),
    _: Admin = Depends(current_admin),
    conn: sqlite3.Connection = Depends(get_db),
):
    return audit.list_entries(conn, limit=limit, before_id=before_id)

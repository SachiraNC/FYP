"""Host inventory helpers shared by the API (and, later, the scan/remediation code)."""
from __future__ import annotations

import json
import sqlite3

from .config import Settings
from .db import utcnow
from .schemas import PASSWORD_AUTH_WARNING
from .ssh import Credentials, HostKey, SSHConnector
from .vault import Vault, stored_kinds


def get_host(conn: sqlite3.Connection, host_id: int) -> sqlite3.Row | None:
    return conn.execute(
        "SELECT h.*, a.username AS authorised_by_name FROM hosts h "
        "JOIN admins a ON a.id = h.authorised_by WHERE h.id = ?",
        (host_id,),
    ).fetchone()


def host_warnings(host: sqlite3.Row) -> list[str]:
    return [PASSWORD_AUTH_WARNING] if host["auth_method"] == "password" else []


def pinned_host_key(host: sqlite3.Row) -> HostKey | None:
    if host["host_key_data"]:
        return HostKey(host["host_key_type"], host["host_key_data"])
    return None


def host_to_dict(conn: sqlite3.Connection, host: sqlite3.Row) -> dict:
    key = pinned_host_key(host)
    return {
        "id": host["id"],
        "name": host["name"],
        "address": host["address"],
        "port": host["port"],
        "username": host["username"],
        "tags": json.loads(host["tags"]),
        "auth_method": host["auth_method"],
        "sudo_mode": host["sudo_mode"],
        "authorised_by": host["authorised_by_name"],
        "authorised_at": host["authorised_at"],
        "authorisation_statement": host["authorisation_statement"],
        "host_key": None if key is None else {
            "key_type": key.key_type,
            "fingerprint": key.fingerprint,
            "first_seen": host["host_key_first_seen"],
        },
        "credentials_stored": stored_kinds(conn, host["id"]),
        "warnings": host_warnings(host),
        "created_at": host["created_at"],
        "updated_at": host["updated_at"],
    }


def build_connector(conn: sqlite3.Connection, vault: Vault, settings: Settings, host: sqlite3.Row) -> SSHConnector:
    secrets = vault.load_all(conn, host["id"])
    creds = Credentials(
        username=host["username"],
        auth_method=host["auth_method"],
        private_key=secrets.get("private_key"),
        key_passphrase=secrets.get("key_passphrase"),
        password=secrets.get("password"),
        sudo_password=secrets.get("sudo_password"),
    )
    return SSHConnector(
        host["address"], host["port"], creds,
        known_host_key=pinned_host_key(host),
        sudo_mode=host["sudo_mode"],
        connect_timeout=settings.ssh_connect_timeout,
        command_timeout=settings.ssh_command_timeout,
    )


def pin_host_key(conn: sqlite3.Connection, host_id: int, key: HostKey, *, only_if_unset: bool) -> bool:
    """Store a host key. Returns True if the row was updated."""
    sql = ("UPDATE hosts SET host_key_type = ?, host_key_data = ?, host_key_fingerprint = ?, "
           "host_key_first_seen = ?, updated_at = ? WHERE id = ?")
    if only_if_unset:
        sql += " AND host_key_data IS NULL"
    now = utcnow()
    cur = conn.execute(sql, (key.key_type, key.data, key.fingerprint, now, now, host_id))
    return cur.rowcount == 1

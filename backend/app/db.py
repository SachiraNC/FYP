"""SQLite storage: schema, connections, timestamps.

The audit_log table is append-only: triggers abort any UPDATE or DELETE.
"""
from __future__ import annotations

import sqlite3
from datetime import datetime, timedelta, timezone

SCHEMA = """
CREATE TABLE IF NOT EXISTS admins (
    id            INTEGER PRIMARY KEY,
    username      TEXT    NOT NULL UNIQUE COLLATE NOCASE,
    password_hash TEXT    NOT NULL,
    disabled      INTEGER NOT NULL DEFAULT 0,
    created_at    TEXT    NOT NULL
);

CREATE TABLE IF NOT EXISTS sessions (
    token_hash TEXT    PRIMARY KEY,               -- SHA-256 of the bearer token; the token itself is never stored
    admin_id   INTEGER NOT NULL REFERENCES admins(id) ON DELETE CASCADE,
    created_at TEXT    NOT NULL,
    expires_at TEXT    NOT NULL
);

CREATE TABLE IF NOT EXISTS hosts (
    id                      INTEGER PRIMARY KEY,
    name                    TEXT    NOT NULL UNIQUE,
    address                 TEXT    NOT NULL,
    port                    INTEGER NOT NULL CHECK (port BETWEEN 1 AND 65535),
    username                TEXT    NOT NULL,
    tags                    TEXT    NOT NULL DEFAULT '[]',    -- JSON array of strings
    auth_method             TEXT    NOT NULL CHECK (auth_method IN ('ssh_key', 'password')),
    sudo_mode               TEXT    NOT NULL CHECK (sudo_mode IN ('none', 'nopasswd', 'password')),
    authorised_by           INTEGER NOT NULL REFERENCES admins(id),
    authorised_at           TEXT    NOT NULL,
    authorisation_statement TEXT    NOT NULL,
    host_key_type           TEXT,
    host_key_data           TEXT,                              -- base64 public key blob
    host_key_fingerprint    TEXT,                              -- OpenSSH-style SHA256:...
    host_key_first_seen     TEXT,
    created_at              TEXT    NOT NULL,
    updated_at              TEXT    NOT NULL
);

CREATE TABLE IF NOT EXISTS credentials (
    host_id    INTEGER NOT NULL REFERENCES hosts(id) ON DELETE CASCADE,
    kind       TEXT    NOT NULL CHECK (kind IN ('private_key', 'key_passphrase', 'password', 'sudo_password')),
    ciphertext BLOB    NOT NULL,                               -- Fernet token
    updated_at TEXT    NOT NULL,
    PRIMARY KEY (host_id, kind)
);

CREATE TABLE IF NOT EXISTS audit_log (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    ts        TEXT NOT NULL,
    actor     TEXT NOT NULL,
    action    TEXT NOT NULL,
    target    TEXT,
    outcome   TEXT NOT NULL CHECK (outcome IN ('success', 'failure', 'denied')),
    client_ip TEXT,
    details   TEXT NOT NULL DEFAULT '{}'                       -- JSON object, never contains secrets
);

CREATE TRIGGER IF NOT EXISTS audit_log_no_update BEFORE UPDATE ON audit_log
BEGIN SELECT RAISE(ABORT, 'audit_log is append-only'); END;

CREATE TRIGGER IF NOT EXISTS audit_log_no_delete BEFORE DELETE ON audit_log
BEGIN SELECT RAISE(ABORT, 'audit_log is append-only'); END;
"""

_TS_FORMAT = "%Y-%m-%dT%H:%M:%S.%fZ"


def utcnow() -> str:
    """UTC timestamp, fixed width, so string comparison == time comparison."""
    return datetime.now(timezone.utc).strftime(_TS_FORMAT)


def utc_in(seconds: int) -> str:
    return (datetime.now(timezone.utc) + timedelta(seconds=seconds)).strftime(_TS_FORMAT)


def connect(path: str) -> sqlite3.Connection:
    # check_same_thread=False: FastAPI may resolve a dependency and run the endpoint on
    # different worker threads. Each request still gets its own connection.
    conn = sqlite3.connect(path, timeout=10, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA busy_timeout = 10000")
    return conn


def init_db(path: str) -> None:
    conn = connect(path)
    try:
        conn.execute("PRAGMA journal_mode = WAL")
        conn.executescript(SCHEMA)
        conn.commit()
    finally:
        conn.close()

"""Credential vault: host secrets encrypted at rest with Fernet.

The master key comes from the CISPLAT_MASTER_KEY environment variable and is never
written to disk, logs, the database or API responses. Decrypted secrets exist only
in memory, for the duration of an SSH operation.
"""
from __future__ import annotations

import os
import sqlite3

from cryptography.fernet import Fernet, InvalidToken

from .config import ENV_MASTER_KEY
from .db import utcnow

CREDENTIAL_KINDS = ("private_key", "key_passphrase", "password", "sudo_password")


class VaultError(Exception):
    pass


class Vault:
    def __init__(self, master_key: str | bytes):
        try:
            self._fernet = Fernet(master_key)
        except (ValueError, TypeError):
            # Do not echo the key back in the error.
            raise VaultError(
                f"{ENV_MASTER_KEY} is not a valid Fernet key (32 url-safe base64-encoded bytes). "
                "Generate one with: python -m app.cli generate-key"
            ) from None

    @classmethod
    def from_env(cls) -> "Vault":
        key = os.environ.get(ENV_MASTER_KEY)
        if not key:
            raise VaultError(f"{ENV_MASTER_KEY} is not set; the credential vault cannot start.")
        return cls(key)

    def __repr__(self) -> str:
        return "<Vault>"

    def encrypt(self, plaintext: str) -> bytes:
        return self._fernet.encrypt(plaintext.encode("utf-8"))

    def decrypt(self, token: bytes) -> str:
        try:
            return self._fernet.decrypt(token).decode("utf-8")
        except InvalidToken:
            raise VaultError(
                f"a stored credential could not be decrypted (wrong {ENV_MASTER_KEY} or corrupted data)"
            ) from None

    # --- storage helpers -------------------------------------------------------------

    def store(self, conn: sqlite3.Connection, host_id: int, kind: str, value: str) -> None:
        if kind not in CREDENTIAL_KINDS:
            raise ValueError(f"unknown credential kind {kind!r}")
        conn.execute(
            "INSERT INTO credentials (host_id, kind, ciphertext, updated_at) VALUES (?, ?, ?, ?) "
            "ON CONFLICT (host_id, kind) DO UPDATE SET ciphertext = excluded.ciphertext, "
            "updated_at = excluded.updated_at",
            (host_id, kind, self.encrypt(value), utcnow()),
        )

    def load_all(self, conn: sqlite3.Connection, host_id: int) -> dict[str, str]:
        rows = conn.execute("SELECT kind, ciphertext FROM credentials WHERE host_id = ?", (host_id,))
        return {r["kind"]: self.decrypt(r["ciphertext"]) for r in rows}


def stored_kinds(conn: sqlite3.Connection, host_id: int) -> list[str]:
    """Which secrets exist for a host (metadata only; nothing is decrypted)."""
    rows = conn.execute("SELECT kind FROM credentials WHERE host_id = ? ORDER BY kind", (host_id,))
    return [r["kind"] for r in rows]


def delete_secrets(conn: sqlite3.Connection, host_id: int, kinds: tuple[str, ...] | None = None) -> None:
    if kinds is None:
        conn.execute("DELETE FROM credentials WHERE host_id = ?", (host_id,))
    else:
        conn.executemany("DELETE FROM credentials WHERE host_id = ? AND kind = ?", [(host_id, k) for k in kinds])

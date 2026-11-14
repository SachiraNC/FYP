"""Runtime configuration, read from environment variables.

The vault master key is deliberately NOT part of Settings: it is read once by
``Vault.from_env()`` and never stored on an object that might be printed or logged.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

ENV_MASTER_KEY = "CISPLAT_MASTER_KEY"
ENV_DB_PATH = "CISPLAT_DB_PATH"
ENV_SESSION_TTL = "CISPLAT_SESSION_TTL_SECONDS"
ENV_SSH_CONNECT_TIMEOUT = "CISPLAT_SSH_CONNECT_TIMEOUT"
ENV_SSH_COMMAND_TIMEOUT = "CISPLAT_SSH_COMMAND_TIMEOUT"


@dataclass(frozen=True)
class Settings:
    db_path: str = "cisplat.db"
    session_ttl_seconds: int = 8 * 3600
    ssh_connect_timeout: float = 10.0
    ssh_command_timeout: float = 300.0

    @classmethod
    def from_env(cls) -> "Settings":
        env = os.environ
        return cls(
            db_path=env.get(ENV_DB_PATH, cls.db_path),
            session_ttl_seconds=int(env.get(ENV_SESSION_TTL, cls.session_ttl_seconds)),
            ssh_connect_timeout=float(env.get(ENV_SSH_CONNECT_TIMEOUT, cls.ssh_connect_timeout)),
            ssh_command_timeout=float(env.get(ENV_SSH_COMMAND_TIMEOUT, cls.ssh_command_timeout)),
        )

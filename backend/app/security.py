"""Admin password hashing (scrypt, stdlib) and session tokens."""
from __future__ import annotations

import base64
import hashlib
import hmac
import secrets

# scrypt cost N=2^17, r=8, p=1 (128 MiB) per the OWASP Password Storage Cheat Sheet.
# Parameters are stored inside each hash, so they can be raised later without breaking logins.
# (Tests lower _N for speed.)
_N, _R, _P = 2**17, 8, 1
_MAXMEM = 256 * 1024 * 1024
_DKLEN = 32

MIN_ADMIN_PASSWORD_LENGTH = 12


def _b64(b: bytes) -> str:
    return base64.b64encode(b).decode("ascii")


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    dk = hashlib.scrypt(password.encode("utf-8"), salt=salt, n=_N, r=_R, p=_P, maxmem=_MAXMEM, dklen=_DKLEN)
    return f"scrypt${_N}${_R}${_P}${_b64(salt)}${_b64(dk)}"


_DUMMY_HASH: str | None = None


def verify_password(password: str, stored: str | None) -> bool:
    """Constant-time verification. ``stored=None`` (unknown user) still costs one scrypt run."""
    global _DUMMY_HASH
    if stored is None:
        if _DUMMY_HASH is None:
            _DUMMY_HASH = hash_password(secrets.token_urlsafe(16))
        stored, known_user = _DUMMY_HASH, False
    else:
        known_user = True
    try:
        algo, n, r, p, salt_b64, dk_b64 = stored.split("$")
        if algo != "scrypt":
            return False
        expected = base64.b64decode(dk_b64)
        dk = hashlib.scrypt(password.encode("utf-8"), salt=base64.b64decode(salt_b64),
                            n=int(n), r=int(r), p=int(p), maxmem=_MAXMEM, dklen=len(expected))
    except (ValueError, TypeError):
        return False
    return hmac.compare_digest(dk, expected) and known_user


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("ascii")).hexdigest()


def new_session_token() -> tuple[str, str]:
    """Return (token for the client, SHA-256 hash to store)."""
    token = secrets.token_urlsafe(32)
    return token, hash_token(token)

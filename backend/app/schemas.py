"""API request/response models.

Secret inputs are ``SecretStr`` (masked in repr/logs). No response model has a secret field.
"""
from __future__ import annotations

import ipaddress
import re
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, SecretStr, StringConstraints, field_validator

AuthMethod = Literal["ssh_key", "password"]
SudoMode = Literal["none", "nopasswd", "password"]

AUTHORISED_USE_STATEMENT = (
    "I confirm that I am authorised by the owner of this host to connect to it over SSH "
    "and assess its configuration with this tool."
)
PASSWORD_AUTH_WARNING = (
    "This host uses password authentication. SSH key authentication is strongly preferred: "
    "a password is sent to the server on every connection and can be phished, reused or "
    "brute-forced."
)
HOST_KEY_CHANGED_WARNING = (
    "WARNING: the host key presented by this host does not match the stored key. This can mean "
    "the host was reinstalled, or that someone is intercepting the connection (man-in-the-middle). "
    "No credentials were sent. Verify the new fingerprint on the host itself "
    "(ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub) before trusting it."
)

_HOSTNAME = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$")

Name = Annotated[str, StringConstraints(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]*$")]
Username = Annotated[str, StringConstraints(min_length=1, max_length=32, pattern=r"^[A-Za-z_][A-Za-z0-9_.-]*$")]
Tag = Annotated[str, StringConstraints(min_length=1, max_length=32, pattern=r"^[A-Za-z0-9._:-]+$")]
Port = Annotated[int, Field(ge=1, le=65535)]
Secret = Annotated[SecretStr, Field(min_length=1, max_length=1024)]
PrivateKeyText = Annotated[SecretStr, Field(min_length=1, max_length=16384)]


def validate_address(v: str) -> str:
    v = v.strip()
    try:
        return str(ipaddress.ip_address(v))
    except ValueError:
        pass
    if not _HOSTNAME.match(v):
        raise ValueError("address must be an IPv4/IPv6 address or a DNS hostname")
    return v.rstrip(".").lower()


def _dedupe(tags: list[str]) -> list[str]:
    return list(dict.fromkeys(tags))


class _Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


# --- auth -------------------------------------------------------------------------------

class LoginRequest(_Strict):
    username: Annotated[str, StringConstraints(min_length=1, max_length=64)]
    password: Annotated[SecretStr, Field(min_length=1, max_length=1024)]


class LoginResponse(BaseModel):
    token: str
    token_type: str = "bearer"
    expires_at: str


class AdminOut(BaseModel):
    id: int
    username: str


# --- hosts ------------------------------------------------------------------------------

class CredentialInput(_Strict):
    auth_method: AuthMethod
    private_key: PrivateKeyText | None = None
    key_passphrase: Secret | None = None
    password: Secret | None = None
    sudo_password: Secret | None = None

    def check_against(self, sudo_mode: str) -> None:
        """Cross-field rules; raises ValueError with a safe (secret-free) message."""
        if self.auth_method == "ssh_key":
            if self.private_key is None:
                raise ValueError("auth_method 'ssh_key' requires private_key")
            if self.password is not None:
                raise ValueError("password must not be set when auth_method is 'ssh_key'")
        else:
            if self.password is None:
                raise ValueError("auth_method 'password' requires password")
            if self.private_key is not None or self.key_passphrase is not None:
                raise ValueError("private_key/key_passphrase must not be set when auth_method is 'password'")
        if self.sudo_password is not None and sudo_mode != "password":
            raise ValueError("sudo_password is only used when sudo_mode is 'password'")
        if sudo_mode == "password" and self.auth_method == "ssh_key" and self.sudo_password is None:
            raise ValueError("sudo_mode 'password' with key authentication requires sudo_password")

    def secrets(self) -> dict[str, str]:
        out = {}
        for kind in ("private_key", "key_passphrase", "password", "sudo_password"):
            v = getattr(self, kind)
            if v is not None:
                out[kind] = v.get_secret_value()
        return out


class HostCreate(CredentialInput):
    name: Name
    address: str
    port: Port = 22
    username: Username
    tags: Annotated[list[Tag], Field(max_length=20)] = []
    sudo_mode: SudoMode
    authorised_use_confirmed: bool = False

    @field_validator("address")
    @classmethod
    def _addr(cls, v):
        return validate_address(v)

    @field_validator("tags")
    @classmethod
    def _tags(cls, v):
        return _dedupe(v)


class HostUpdate(_Strict):
    name: Name | None = None
    address: str | None = None
    port: Port | None = None
    username: Username | None = None
    tags: Annotated[list[Tag], Field(max_length=20)] | None = None
    sudo_mode: SudoMode | None = None
    # Required again when the target (address/port) changes: it is effectively a new host.
    authorised_use_confirmed: bool = False

    @field_validator("address")
    @classmethod
    def _addr(cls, v):
        return None if v is None else validate_address(v)

    @field_validator("tags")
    @classmethod
    def _tags(cls, v):
        return None if v is None else _dedupe(v)


class HostKeyOut(BaseModel):
    key_type: str
    fingerprint: str
    first_seen: str | None = None


class HostOut(BaseModel):
    id: int
    name: str
    address: str
    port: int
    username: str
    tags: list[str]
    auth_method: AuthMethod
    sudo_mode: SudoMode
    authorised_by: str
    authorised_at: str
    authorisation_statement: str
    host_key: HostKeyOut | None
    credentials_stored: list[str]  # which secrets exist, never their values
    warnings: list[str]
    created_at: str
    updated_at: str


class HostKeyTrust(_Strict):
    fingerprint: Annotated[str, StringConstraints(pattern=r"^SHA256:[A-Za-z0-9+/]{43}$")]


class ConnectionTestResult(BaseModel):
    ok: bool
    error: str | None = None
    message: str | None = None
    remote_user: str | None = None
    sudo_ok: bool | None = None
    host_key: HostKeyOut | None = None
    host_key_status: Literal["trusted_on_first_use", "verified"] | None = None
    warnings: list[str] = []


class AuditEntry(BaseModel):
    id: int
    ts: str
    actor: str
    action: str
    target: str | None
    outcome: str
    client_ip: str | None
    details: dict

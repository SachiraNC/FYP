"""Host inventory, credentials, connection test and host-key trust."""
from __future__ import annotations

import json
import sqlite3

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response, status

from .. import audit, db
from ..config import Settings
from ..deps import Admin, client_ip, current_admin, get_db, get_settings, get_vault
from ..inventory import build_connector, get_host, host_to_dict, host_warnings, pin_host_key, pinned_host_key
from ..schemas import (
    AUTHORISED_USE_STATEMENT, HOST_KEY_CHANGED_WARNING, ConnectionTestResult, CredentialInput,
    HostCreate, HostKeyOut, HostKeyTrust, HostOut, HostUpdate,
)
from ..ssh import HostKeyMismatch, InvalidCredential, SSHError, fetch_host_key, load_private_key
from ..vault import Vault, delete_secrets

router = APIRouter(prefix="/api/hosts", tags=["hosts"])

_NOT_CONFIRMED = (
    "authorised use must be confirmed (authorised_use_confirmed: true). Statement: " + AUTHORISED_USE_STATEMENT
)


def _require_host(conn: sqlite3.Connection, host_id: int) -> sqlite3.Row:
    host = get_host(conn, host_id)
    if host is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "host not found")
    return host


def _validate_credentials(body: CredentialInput, sudo_mode: str) -> None:
    try:
        body.check_against(sudo_mode)
        if body.auth_method == "ssh_key":
            load_private_key(
                body.private_key.get_secret_value(),
                body.key_passphrase.get_secret_value() if body.key_passphrase else None,
            )
    except (ValueError, InvalidCredential) as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(e)) from None


def _store_credentials(conn: sqlite3.Connection, vault: Vault, host_id: int, body: CredentialInput) -> list[str]:
    secrets = body.secrets()
    for kind, value in secrets.items():
        vault.store(conn, host_id, kind, value)
    return sorted(secrets)


@router.get("", response_model=list[HostOut])
def list_hosts(
    tag: str | None = Query(None, max_length=32),
    _: Admin = Depends(current_admin),
    conn: sqlite3.Connection = Depends(get_db),
):
    ids = [r["id"] for r in conn.execute("SELECT id FROM hosts ORDER BY name")]
    hosts = [host_to_dict(conn, get_host(conn, i)) for i in ids]
    if tag is not None:
        hosts = [h for h in hosts if tag in h["tags"]]
    return hosts


@router.post("", response_model=HostOut, status_code=status.HTTP_201_CREATED)
def create_host(
    body: HostCreate,
    request: Request,
    admin: Admin = Depends(current_admin),
    conn: sqlite3.Connection = Depends(get_db),
    vault: Vault = Depends(get_vault),
):
    ip = client_ip(request)
    if not body.authorised_use_confirmed:
        audit.record(conn, actor=admin.username, action="host.create", outcome="denied", client_ip=ip,
                     details={"name": body.name, "address": body.address, "reason": "authorised use not confirmed"})
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, _NOT_CONFIRMED)
    _validate_credentials(body, body.sudo_mode)

    now = db.utcnow()
    try:
        cur = conn.execute(
            "INSERT INTO hosts (name, address, port, username, tags, auth_method, sudo_mode, authorised_by, "
            "authorised_at, authorisation_statement, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (body.name, body.address, body.port, body.username, json.dumps(body.tags), body.auth_method,
             body.sudo_mode, admin.id, now, AUTHORISED_USE_STATEMENT, now, now),
        )
    except sqlite3.IntegrityError:
        conn.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, f"a host named {body.name!r} already exists") from None
    host_id = cur.lastrowid
    kinds = _store_credentials(conn, vault, host_id, body)
    host = get_host(conn, host_id)
    audit.record(conn, actor=admin.username, action="host.create", target=f"host:{host_id}", client_ip=ip, details={
        "name": body.name, "address": body.address, "port": body.port, "username": body.username,
        "tags": body.tags, "auth_method": body.auth_method, "sudo_mode": body.sudo_mode,
        "credentials_stored": kinds, "authorised_use_confirmed": True,
        "authorisation_statement": AUTHORISED_USE_STATEMENT, "warnings": host_warnings(host),
    })
    return host_to_dict(conn, host)


@router.get("/{host_id}", response_model=HostOut)
def read_host(host_id: int, _: Admin = Depends(current_admin), conn: sqlite3.Connection = Depends(get_db)):
    return host_to_dict(conn, _require_host(conn, host_id))


@router.patch("/{host_id}", response_model=HostOut)
def update_host(
    host_id: int,
    body: HostUpdate,
    request: Request,
    admin: Admin = Depends(current_admin),
    conn: sqlite3.Connection = Depends(get_db),
):
    host = _require_host(conn, host_id)
    ip = client_ip(request)
    changes = {k: v for k, v in body.model_dump(exclude_unset=True).items()
               if k != "authorised_use_confirmed" and v is not None}
    changes = {k: v for k, v in changes.items()
               if (json.loads(host["tags"]) if k == "tags" else host[k]) != v}
    if not changes:
        return host_to_dict(conn, host)

    retarget = "address" in changes or "port" in changes
    if retarget and not body.authorised_use_confirmed:
        audit.record(conn, actor=admin.username, action="host.update", target=f"host:{host_id}", outcome="denied",
                     client_ip=ip, details={"changes": changes, "reason": "authorised use not re-confirmed for new target"})
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, "changing address/port requires " + _NOT_CONFIRMED)

    new_sudo = changes.get("sudo_mode")
    if new_sudo == "password" and host["auth_method"] == "ssh_key":
        if "sudo_password" not in {r["kind"] for r in conn.execute(
                "SELECT kind FROM credentials WHERE host_id = ?", (host_id,))}:
            raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT,
                                "sudo_mode 'password' with key authentication requires a sudo_password: "
                                "set it with PUT /api/hosts/{id}/credentials first")

    now = db.utcnow()
    cols = dict(changes)
    if "tags" in cols:
        cols["tags"] = json.dumps(cols["tags"])
    if retarget:
        cols.update(authorised_by=admin.id, authorised_at=now, authorisation_statement=AUTHORISED_USE_STATEMENT)
    cols["updated_at"] = now
    try:
        conn.execute(f"UPDATE hosts SET {', '.join(f'{c} = ?' for c in cols)} WHERE id = ?",
                     (*cols.values(), host_id))
    except sqlite3.IntegrityError:
        conn.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, f"a host named {changes.get('name')!r} already exists") from None
    if new_sudo is not None and new_sudo != "password":
        delete_secrets(conn, host_id, ("sudo_password",))  # do not keep secrets that are no longer used
    details = {"changes": changes}
    if retarget:
        details.update(authorised_use_confirmed=True, authorisation_statement=AUTHORISED_USE_STATEMENT)
    audit.record(conn, actor=admin.username, action="host.update", target=f"host:{host_id}", client_ip=ip,
                 details=details)
    return host_to_dict(conn, get_host(conn, host_id))


@router.delete("/{host_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_host(
    host_id: int,
    request: Request,
    admin: Admin = Depends(current_admin),
    conn: sqlite3.Connection = Depends(get_db),
):
    host = _require_host(conn, host_id)
    conn.execute("DELETE FROM hosts WHERE id = ?", (host_id,))  # credentials cascade
    audit.record(conn, actor=admin.username, action="host.delete", target=f"host:{host_id}",
                 client_ip=client_ip(request), details={"name": host["name"], "address": host["address"]})
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.put("/{host_id}/credentials", response_model=HostOut)
def replace_credentials(
    host_id: int,
    body: CredentialInput,
    request: Request,
    admin: Admin = Depends(current_admin),
    conn: sqlite3.Connection = Depends(get_db),
    vault: Vault = Depends(get_vault),
):
    host = _require_host(conn, host_id)
    _validate_credentials(body, host["sudo_mode"])
    delete_secrets(conn, host_id)
    kinds = _store_credentials(conn, vault, host_id, body)
    conn.execute("UPDATE hosts SET auth_method = ?, updated_at = ? WHERE id = ?",
                 (body.auth_method, db.utcnow(), host_id))
    host = get_host(conn, host_id)
    audit.record(conn, actor=admin.username, action="host.credentials.replace", target=f"host:{host_id}",
                 client_ip=client_ip(request), details={
                     "auth_method": body.auth_method, "credentials_stored": kinds, "warnings": host_warnings(host)})
    return host_to_dict(conn, host)


@router.post("/{host_id}/test", response_model=ConnectionTestResult)
def test_connection(
    host_id: int,
    request: Request,
    admin: Admin = Depends(current_admin),
    conn: sqlite3.Connection = Depends(get_db),
    vault: Vault = Depends(get_vault),
    settings: Settings = Depends(get_settings),
):
    """Connect, verify (or pin, on first use) the host key, authenticate, run `id -un`,
    and check sudo if the host uses it. Read-only on the target."""
    host = _require_host(conn, host_id)
    ip = client_ip(request)
    target = f"host:{host_id}"
    warnings = host_warnings(host)
    connector = build_connector(conn, vault, settings, host)
    remote_user = sudo_ok = None
    error = None
    try:
        with connector:
            r = connector.run("id -un", timeout=settings.ssh_connect_timeout)
            remote_user = r.stdout.strip() or None
            if host["sudo_mode"] != "none":
                sudo_ok = connector.run("true", sudo=True, timeout=settings.ssh_connect_timeout).ok
    except HostKeyMismatch as e:
        audit.record(conn, actor=admin.username, action="ssh.host_key.mismatch", target=target, outcome="denied",
                     client_ip=ip, details={
                         "expected_key_type": e.expected.key_type, "expected_fingerprint": e.expected.fingerprint,
                         "presented_key_type": e.presented.key_type, "presented_fingerprint": e.presented.fingerprint})
        raise HTTPException(status.HTTP_409_CONFLICT, detail={
            "error": e.code, "warning": HOST_KEY_CHANGED_WARNING,
            "expected_fingerprint": e.expected.fingerprint, "presented_fingerprint": e.presented.fingerprint,
        }) from None
    except SSHError as e:
        error = e

    key = connector.presented_host_key
    status_ = None
    if key is not None:
        if connector.host_key_is_new:
            # Trust on first use: pin even if authentication failed - the key was still presented.
            if pin_host_key(conn, host_id, key, only_if_unset=True):
                audit.record(conn, actor=admin.username, action="ssh.host_key.first_use", target=target,
                             client_ip=ip, details={"key_type": key.key_type, "fingerprint": key.fingerprint})
            status_ = "trusted_on_first_use"
            warnings.append(f"Host key {key.key_type} {key.fingerprint} was trusted on first use. Verify it on the "
                            "host (ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub) and re-pin it if it differs.")
        else:
            status_ = "verified"
    if sudo_ok is False:
        warnings.append(f"sudo check failed for sudo_mode '{host['sudo_mode']}'.")

    ok = error is None and (sudo_ok is not False)
    audit.record(conn, actor=admin.username, action="host.connection_test", target=target,
                 outcome="success" if ok else "failure", client_ip=ip, details={
                     "remote_user": remote_user, "sudo_ok": sudo_ok, "host_key_status": status_,
                     "error": error.code if error else None, "message": str(error) if error else None})
    return ConnectionTestResult(
        ok=ok,
        error=error.code if error else (None if ok else "sudo_failed"),
        message=str(error) if error else None,
        remote_user=remote_user,
        sudo_ok=sudo_ok,
        host_key=None if key is None else HostKeyOut(
            key_type=key.key_type, fingerprint=key.fingerprint,
            first_seen=get_host(conn, host_id)["host_key_first_seen"]),
        host_key_status=status_,
        warnings=warnings,
    )


@router.post("/{host_id}/host-key/trust", response_model=HostOut)
def trust_host_key(
    host_id: int,
    body: HostKeyTrust,
    request: Request,
    admin: Admin = Depends(current_admin),
    conn: sqlite3.Connection = Depends(get_db),
    settings: Settings = Depends(get_settings),
):
    """Pin the key the host presents now, but only if it matches the fingerprint the admin
    verified out of band. Used after a host-key change, or to pre-pin before first use."""
    host = _require_host(conn, host_id)
    ip = client_ip(request)
    old = pinned_host_key(host)
    try:
        presented = fetch_host_key(host["address"], host["port"], timeout=settings.ssh_connect_timeout,
                                   preferred_type=old.key_type if old else None)
    except SSHError as e:
        audit.record(conn, actor=admin.username, action="ssh.host_key.trust", target=f"host:{host_id}",
                     outcome="failure", client_ip=ip, details={"error": e.code, "message": str(e)})
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, str(e)) from None
    if presented.fingerprint != body.fingerprint:
        audit.record(conn, actor=admin.username, action="ssh.host_key.trust", target=f"host:{host_id}",
                     outcome="denied", client_ip=ip, details={
                         "confirmed_fingerprint": body.fingerprint, "presented_fingerprint": presented.fingerprint})
        raise HTTPException(status.HTTP_409_CONFLICT, detail={
            "error": "fingerprint_mismatch",
            "message": "the host presented a different key from the fingerprint you confirmed; nothing was changed",
            "presented_fingerprint": presented.fingerprint,
        })
    pin_host_key(conn, host_id, presented, only_if_unset=False)
    audit.record(conn, actor=admin.username, action="ssh.host_key.trust", target=f"host:{host_id}", client_ip=ip,
                 details={"previous_fingerprint": old.fingerprint if old else None,
                          "key_type": presented.key_type, "fingerprint": presented.fingerprint})
    return host_to_dict(conn, get_host(conn, host_id))

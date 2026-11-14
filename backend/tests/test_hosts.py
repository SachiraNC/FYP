import logging

import paramiko
import pytest

from app import db
from app.schemas import AUTHORISED_USE_STATEMENT, PASSWORD_AUTH_WARNING
from app.ssh import HostKey

from .conftest import KEY_PASSPHRASE, LOGIN_PASSWORD, SUDO_PASSWORD


def create(client, auth, payload, expect=201):
    r = client.post("/api/hosts", json=payload, headers=auth)
    assert r.status_code == expect, r.text
    return r.json()


def audit(client, auth):
    return client.get("/api/audit-log", headers=auth).json()


def all_responses_text(client, auth, host_id):
    return "".join([
        client.get("/api/hosts", headers=auth).text,
        client.get(f"/api/hosts/{host_id}", headers=auth).text,
        client.get("/api/audit-log?limit=1000", headers=auth).text,
    ])


# --- authorised-use confirmation -------------------------------------------------------------

@pytest.mark.parametrize("confirm", [False, None])
def test_create_requires_authorised_use_confirmation(client, auth, host_payload, confirm):
    if confirm is None:
        host_payload.pop("authorised_use_confirmed")
    else:
        host_payload["authorised_use_confirmed"] = confirm
    r = client.post("/api/hosts", json=host_payload, headers=auth)
    assert r.status_code == 422
    assert AUTHORISED_USE_STATEMENT in r.json()["detail"]
    assert client.get("/api/hosts", headers=auth).json() == []
    entry = audit(client, auth)[0]
    assert (entry["action"], entry["outcome"]) == ("host.create", "denied")


def test_create_records_authorisation(client, auth, host_payload):
    h = create(client, auth, host_payload)
    assert h["authorised_by"] == "admin" and h["authorised_at"]
    assert h["authorisation_statement"] == AUTHORISED_USE_STATEMENT
    entry = audit(client, auth)[0]
    assert entry["action"] == "host.create" and entry["details"]["authorised_use_confirmed"] is True
    assert entry["details"]["authorisation_statement"] == AUTHORISED_USE_STATEMENT


# --- inventory CRUD ---------------------------------------------------------------------------

def test_create_and_read_key_host(client, auth, host_payload):
    h = create(client, auth, host_payload)
    assert {k: h[k] for k in ("name", "address", "username", "auth_method", "sudo_mode")} == {
        "name": "web-01", "address": "127.0.0.1", "username": "tester", "auth_method": "ssh_key", "sudo_mode": "nopasswd"}
    assert h["tags"] == ["prod", "web"]
    assert h["credentials_stored"] == ["private_key"]
    assert h["warnings"] == [] and h["host_key"] is None
    assert client.get(f"/api/hosts/{h['id']}", headers=auth).json() == h


def test_password_host_shows_warning(client, auth, host_payload):
    host_payload.update(auth_method="password", password=LOGIN_PASSWORD)
    del host_payload["private_key"]
    h = create(client, auth, host_payload)
    assert h["warnings"] == [PASSWORD_AUTH_WARNING]
    assert audit(client, auth)[0]["details"]["warnings"] == [PASSWORD_AUTH_WARNING]


def test_list_filter_by_tag(client, auth, host_payload):
    create(client, auth, host_payload)
    host_payload.update(name="db-01", tags=["prod", "db"])
    create(client, auth, host_payload)
    names = lambda tag: [h["name"] for h in client.get(f"/api/hosts?tag={tag}", headers=auth).json()]
    assert names("prod") == ["db-01", "web-01"]
    assert names("web") == ["web-01"]
    assert names("none") == []


def test_duplicate_name_conflict(client, auth, host_payload):
    create(client, auth, host_payload)
    create(client, auth, host_payload, expect=409)


@pytest.mark.parametrize("field,value", [
    ("address", "-oProxyCommand=evil"), ("address", "bad host"), ("address", "a" * 300),
    ("port", 0), ("port", 70000), ("username", "root;id"), ("name", "../x"),
    ("tags", ["ok", "bad tag"]), ("auth_method", "kerberos"), ("sudo_mode", "su"),
])
def test_input_validation(client, auth, host_payload, field, value):
    host_payload[field] = value
    create(client, auth, host_payload, expect=422)


def test_address_normalisation(client, auth, host_payload):
    host_payload["address"] = "Server.Example.COM."
    assert create(client, auth, host_payload)["address"] == "server.example.com"
    host_payload.update(name="v6", address="2001:DB8::1")
    assert create(client, auth, host_payload)["address"] == "2001:db8::1"


def test_unknown_fields_rejected(client, auth, host_payload):
    host_payload["is_admin"] = True
    create(client, auth, host_payload, expect=422)


def test_update_host(client, auth, host_payload):
    h = create(client, auth, host_payload)
    r = client.patch(f"/api/hosts/{h['id']}", json={"tags": ["staging"], "username": "ops"}, headers=auth)
    assert r.status_code == 200
    assert r.json()["tags"] == ["staging"] and r.json()["username"] == "ops"
    entry = audit(client, auth)[0]
    assert entry["action"] == "host.update" and entry["details"]["changes"] == {"tags": ["staging"], "username": "ops"}


def test_update_target_requires_reconfirmation(client, auth, host_payload):
    h = create(client, auth, host_payload)
    r = client.patch(f"/api/hosts/{h['id']}", json={"address": "10.0.0.9"}, headers=auth)
    assert r.status_code == 422 and AUTHORISED_USE_STATEMENT in r.json()["detail"]
    assert audit(client, auth)[0]["outcome"] == "denied"
    r = client.patch(f"/api/hosts/{h['id']}", json={"address": "10.0.0.9", "authorised_use_confirmed": True},
                     headers=auth)
    assert r.status_code == 200 and r.json()["address"] == "10.0.0.9"


def test_update_sudo_password_mode_needs_secret(client, auth, host_payload):
    h = create(client, auth, host_payload)
    r = client.patch(f"/api/hosts/{h['id']}", json={"sudo_mode": "password"}, headers=auth)
    assert r.status_code == 422


def test_delete_host_removes_credentials(client, auth, host_payload, settings):
    h = create(client, auth, host_payload)
    assert client.delete(f"/api/hosts/{h['id']}", headers=auth).status_code == 204
    assert client.get(f"/api/hosts/{h['id']}", headers=auth).status_code == 404
    conn = db.connect(settings.db_path)
    assert conn.execute("SELECT COUNT(*) FROM credentials").fetchone()[0] == 0
    conn.close()
    assert audit(client, auth)[0]["action"] == "host.delete"


def test_unknown_host_404(client, auth):
    assert client.get("/api/hosts/999", headers=auth).status_code == 404
    assert client.post("/api/hosts/999/test", headers=auth).status_code == 404


# --- credentials ----------------------------------------------------------------------------

@pytest.mark.parametrize("change,msg", [
    ({"private_key": None}, "requires private_key"),
    ({"password": "x"}, "must not be set"),
    ({"private_key": "not a key"}, "could not be loaded"),
    ({"sudo_password": "x"}, "only used when sudo_mode"),
    ({"sudo_mode": "password"}, "requires sudo_password"),
])
def test_credential_rules(client, auth, host_payload, change, msg):
    host_payload.update(change)
    host_payload = {k: v for k, v in host_payload.items() if v is not None}
    r = client.post("/api/hosts", json=host_payload, headers=auth)
    assert r.status_code == 422 and msg in r.text


def test_encrypted_key_needs_passphrase(client, auth, host_payload, client_key_pem_encrypted):
    host_payload["private_key"] = client_key_pem_encrypted
    r = client.post("/api/hosts", json=host_payload, headers=auth)
    assert r.status_code == 422 and "passphrase" in r.text
    host_payload["key_passphrase"] = KEY_PASSPHRASE
    assert create(client, auth, host_payload)["credentials_stored"] == ["key_passphrase", "private_key"]


def test_replace_credentials(client, auth, host_payload):
    h = create(client, auth, host_payload)
    r = client.put(f"/api/hosts/{h['id']}/credentials", headers=auth,
                   json={"auth_method": "password", "password": LOGIN_PASSWORD})
    assert r.status_code == 200
    assert r.json()["auth_method"] == "password" and r.json()["credentials_stored"] == ["password"]
    assert r.json()["warnings"] == [PASSWORD_AUTH_WARNING]
    assert audit(client, auth)[0]["action"] == "host.credentials.replace"


def test_secrets_encrypted_at_rest(client, auth, host_payload, settings, client_key_pem):
    host_payload.update(sudo_mode="password", sudo_password=SUDO_PASSWORD)
    create(client, auth, host_payload)
    conn = db.connect(settings.db_path)
    dump = "\n".join(conn.iterdump())
    rows = conn.execute("SELECT kind, ciphertext FROM credentials ORDER BY kind").fetchall()
    conn.close()
    assert [r["kind"] for r in rows] == ["private_key", "sudo_password"]
    assert all(r["ciphertext"].startswith(b"gAAAAA") for r in rows)  # Fernet tokens
    key_body = client_key_pem.splitlines()[1]
    assert SUDO_PASSWORD not in dump and key_body not in dump


def test_secrets_never_returned_or_logged(client, auth, host_payload, client_key_pem, caplog):
    caplog.set_level(logging.DEBUG)
    host_payload.update(sudo_mode="password", sudo_password=SUDO_PASSWORD)
    h = create(client, auth, host_payload)
    client.post(f"/api/hosts/{h['id']}/test", headers=auth)
    client.put(f"/api/hosts/{h['id']}/credentials", headers=auth,
               json={"auth_method": "password", "password": LOGIN_PASSWORD, "sudo_password": SUDO_PASSWORD})
    text = all_responses_text(client, auth, h["id"])
    key_body = client_key_pem.splitlines()[1]
    for secret in (SUDO_PASSWORD, LOGIN_PASSWORD, key_body):
        assert secret not in text
        assert secret not in caplog.text


def test_validation_errors_do_not_echo_secrets(client, auth, host_payload):
    host_payload.update(auth_method="password", password=LOGIN_PASSWORD, port="not-a-port")
    r = client.post("/api/hosts", json=host_payload, headers=auth)
    assert r.status_code == 422
    assert LOGIN_PASSWORD not in r.text and "BEGIN" not in r.text
    assert all(set(e) == {"loc", "msg", "type"} for e in r.json()["detail"])


# --- connection test & host keys --------------------------------------------------------------

def test_connection_test_pins_key_on_first_use(client, auth, host_payload, ssh_server):
    h = create(client, auth, host_payload)
    r = client.post(f"/api/hosts/{h['id']}/test", headers=auth).json()
    fp = HostKey.from_pkey(ssh_server.host_key).fingerprint
    assert r["ok"] and r["remote_user"] == "tester" and r["sudo_ok"] is True, r
    assert r["host_key_status"] == "trusted_on_first_use" and r["host_key"]["fingerprint"] == fp
    assert any(fp in w for w in r["warnings"])
    assert client.get(f"/api/hosts/{h['id']}", headers=auth).json()["host_key"]["fingerprint"] == fp
    actions = [e["action"] for e in audit(client, auth)[:2]]
    assert actions == ["host.connection_test", "ssh.host_key.first_use"]

    r2 = client.post(f"/api/hosts/{h['id']}/test", headers=auth).json()
    assert r2["ok"] and r2["host_key_status"] == "verified"


def test_connection_test_auth_failure(client, auth, host_payload, ssh_server):
    host_payload.update(auth_method="password", password="Wrong-pass-123")
    del host_payload["private_key"]
    h = create(client, auth, host_payload)
    r = client.post(f"/api/hosts/{h['id']}/test", headers=auth).json()
    assert not r["ok"] and r["error"] == "authentication_failed"
    assert r["host_key_status"] == "trusted_on_first_use"   # key was still presented and pinned
    assert PASSWORD_AUTH_WARNING in r["warnings"]
    assert audit(client, auth)[0]["outcome"] == "failure"


def test_connection_test_sudo_failure(client, auth, host_payload, ssh_server):
    ssh_server.sudo_nopasswd = False
    h = create(client, auth, host_payload)
    r = client.post(f"/api/hosts/{h['id']}/test", headers=auth).json()
    assert not r["ok"] and r["sudo_ok"] is False and r["error"] == "sudo_failed"


def test_connection_test_unreachable(client, auth, host_payload, ssh_server):
    ssh_server.close()
    h = create(client, auth, host_payload)
    r = client.post(f"/api/hosts/{h['id']}/test", headers=auth).json()
    assert not r["ok"] and r["error"] == "connection_failed" and r["host_key"] is None


def test_host_key_change_warns_and_blocks(client, auth, host_payload, ssh_server):
    h = create(client, auth, host_payload)
    client.post(f"/api/hosts/{h['id']}/test", headers=auth)
    old_fp = HostKey.from_pkey(ssh_server.host_key).fingerprint
    ssh_server.host_key = paramiko.ECDSAKey.generate()
    new_fp = HostKey.from_pkey(ssh_server.host_key).fingerprint
    attempts = ssh_server.auth_attempts

    r = client.post(f"/api/hosts/{h['id']}/test", headers=auth)
    assert r.status_code == 409
    d = r.json()["detail"]
    assert d["error"] == "host_key_mismatch" and "man-in-the-middle" in d["warning"]
    assert (d["expected_fingerprint"], d["presented_fingerprint"]) == (old_fp, new_fp)
    assert ssh_server.auth_attempts == attempts          # no credentials sent
    entry = audit(client, auth)[0]
    assert entry["action"] == "ssh.host_key.mismatch" and entry["outcome"] == "denied"
    # stored key unchanged
    assert client.get(f"/api/hosts/{h['id']}", headers=auth).json()["host_key"]["fingerprint"] == old_fp


def test_trust_new_host_key_requires_matching_fingerprint(client, auth, host_payload, ssh_server):
    h = create(client, auth, host_payload)
    client.post(f"/api/hosts/{h['id']}/test", headers=auth)
    ssh_server.host_key = paramiko.ECDSAKey.generate()
    new_fp = HostKey.from_pkey(ssh_server.host_key).fingerprint
    wrong_fp = HostKey.from_pkey(paramiko.ECDSAKey.generate()).fingerprint

    r = client.post(f"/api/hosts/{h['id']}/host-key/trust", json={"fingerprint": wrong_fp}, headers=auth)
    assert r.status_code == 409 and r.json()["detail"]["presented_fingerprint"] == new_fp
    assert audit(client, auth)[0]["outcome"] == "denied"

    r = client.post(f"/api/hosts/{h['id']}/host-key/trust", json={"fingerprint": new_fp}, headers=auth)
    assert r.status_code == 200 and r.json()["host_key"]["fingerprint"] == new_fp
    assert audit(client, auth)[0]["action"] == "ssh.host_key.trust"
    assert client.post(f"/api/hosts/{h['id']}/test", headers=auth).json()["host_key_status"] == "verified"


def test_pre_pin_host_key_before_first_use(client, auth, host_payload, ssh_server):
    h = create(client, auth, host_payload)
    fp = HostKey.from_pkey(ssh_server.host_key).fingerprint
    assert client.post(f"/api/hosts/{h['id']}/host-key/trust", json={"fingerprint": fp},
                       headers=auth).status_code == 200
    assert client.post(f"/api/hosts/{h['id']}/test", headers=auth).json()["host_key_status"] == "verified"


def test_trust_rejects_malformed_fingerprint(client, auth, host_payload):
    h = create(client, auth, host_payload)
    r = client.post(f"/api/hosts/{h['id']}/host-key/trust", json={"fingerprint": "MD5:aa:bb"}, headers=auth)
    assert r.status_code == 422

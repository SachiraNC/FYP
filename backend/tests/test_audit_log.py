import sqlite3

import pytest

from app import audit, db


@pytest.fixture
def conn(tmp_path):
    path = str(tmp_path / "a.db")
    db.init_db(path)
    c = db.connect(path)
    yield c
    c.close()


def test_append_and_list(conn):
    audit.record(conn, actor="alice", action="x.one", details={"n": 1})
    audit.record(conn, actor="bob", action="x.two", outcome="failure", target="host:1", client_ip="10.0.0.1")
    entries = audit.list_entries(conn)
    assert [e["action"] for e in entries] == ["x.two", "x.one"]
    assert entries[1]["details"] == {"n": 1}
    assert entries[0]["target"] == "host:1" and entries[0]["client_ip"] == "10.0.0.1"
    assert [e["action"] for e in audit.list_entries(conn, before_id=entries[0]["id"])] == ["x.one"]


def test_update_is_blocked(conn):
    audit.record(conn, actor="alice", action="x")
    with pytest.raises(sqlite3.DatabaseError, match="append-only"):
        conn.execute("UPDATE audit_log SET actor = 'mallory'")
    assert audit.list_entries(conn)[0]["actor"] == "alice"


def test_delete_is_blocked(conn):
    audit.record(conn, actor="alice", action="x")
    with pytest.raises(sqlite3.DatabaseError, match="append-only"):
        conn.execute("DELETE FROM audit_log")
    assert len(audit.list_entries(conn)) == 1


def test_triggers_survive_reinit(conn, tmp_path):
    db.init_db(str(tmp_path / "a.db"))  # idempotent; must not drop protections
    audit.record(conn, actor="a", action="x")
    with pytest.raises(sqlite3.DatabaseError):
        conn.execute("DELETE FROM audit_log")


@pytest.mark.parametrize("details", [
    {"password": "x"}, {"nested": {"Private_Key": "x"}}, {"list": [{"sudo_password": "x"}]}, {"token": "x"},
])
def test_secret_fields_refused(conn, details):
    with pytest.raises(ValueError, match="secret"):
        audit.record(conn, actor="a", action="x", details=details)
    assert audit.list_entries(conn) == []


def test_invalid_outcome_rejected(conn):
    with pytest.raises(sqlite3.IntegrityError):
        audit.record(conn, actor="a", action="x", outcome="maybe")


def test_api_actions_are_audited(client, auth, host_payload):
    r = client.post("/api/hosts", json=host_payload, headers=auth)
    hid = r.json()["id"]
    client.patch(f"/api/hosts/{hid}", json={"tags": ["x"]}, headers=auth)
    client.post(f"/api/hosts/{hid}/test", headers=auth)
    client.delete(f"/api/hosts/{hid}", headers=auth)
    client.post("/api/auth/logout", headers=auth)
    from .conftest import ADMIN_PASSWORD, ADMIN_USER
    tok = client.post("/api/auth/login", json={"username": ADMIN_USER, "password": ADMIN_PASSWORD}).json()["token"]
    entries = client.get("/api/audit-log?limit=50", headers={"Authorization": f"Bearer {tok}"}).json()
    actions = [e["action"] for e in reversed(entries)]
    assert actions == [
        "admin.create", "auth.login", "host.create", "host.update", "ssh.host_key.first_use",
        "host.connection_test", "host.delete", "auth.logout", "auth.login",
    ]
    assert all(e["client_ip"] for e in entries if e["actor"] != "cli")


def test_audit_log_api_pagination(client, auth):
    first = client.get("/api/audit-log?limit=1", headers=auth).json()
    assert len(first) == 1
    older = client.get(f"/api/audit-log?before_id={first[0]['id']}", headers=auth).json()
    assert all(e["id"] < first[0]["id"] for e in older)
    assert client.get("/api/audit-log?limit=0", headers=auth).status_code == 422

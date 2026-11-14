import pytest

from app import db
from app.cli import CLIError, create_admin

from .conftest import ADMIN_PASSWORD, ADMIN_USER


def _audit(client, auth):
    return client.get("/api/audit-log", headers=auth).json()


def test_login_success_returns_token(client):
    r = client.post("/api/auth/login", json={"username": ADMIN_USER, "password": ADMIN_PASSWORD})
    assert r.status_code == 200
    body = r.json()
    assert body["token_type"] == "bearer" and body["token"] and body["expires_at"]


@pytest.mark.parametrize("user,pw", [(ADMIN_USER, "wrong-password"), ("nobody", ADMIN_PASSWORD)])
def test_login_failure_is_generic_and_audited(client, auth, user, pw):
    r = client.post("/api/auth/login", json={"username": user, "password": pw})
    assert r.status_code == 401
    assert r.json()["detail"] == "invalid username or password"
    entry = _audit(client, auth)[0]
    assert entry["action"] == "auth.login" and entry["outcome"] == "failure" and entry["actor"] == user
    assert pw not in str(entry)


def test_endpoints_require_token(client):
    for method, path in [("get", "/api/hosts"), ("post", "/api/hosts"), ("get", "/api/audit-log"),
                         ("get", "/api/auth/me"), ("post", "/api/hosts/1/test")]:
        assert getattr(client, method)(path).status_code == 401, path
    assert client.get("/api/hosts", headers={"Authorization": "Bearer bogus"}).status_code == 401


def test_me(client, auth):
    assert client.get("/api/auth/me", headers=auth).json()["username"] == ADMIN_USER


def test_logout_invalidates_token(client, auth):
    assert client.post("/api/auth/logout", headers=auth).status_code == 204
    assert client.get("/api/auth/me", headers=auth).status_code == 401


def test_expired_session_rejected(client, auth, settings):
    conn = db.connect(settings.db_path)
    conn.execute("UPDATE sessions SET expires_at = '2000-01-01T00:00:00.000000Z'")
    conn.commit()
    conn.close()
    assert client.get("/api/auth/me", headers=auth).status_code == 401


def test_disabled_admin_cannot_login_or_use_session(client, auth, settings):
    conn = db.connect(settings.db_path)
    conn.execute("UPDATE admins SET disabled = 1")
    conn.commit()
    conn.close()
    assert client.get("/api/auth/me", headers=auth).status_code == 401
    r = client.post("/api/auth/login", json={"username": ADMIN_USER, "password": ADMIN_PASSWORD})
    assert r.status_code == 401


def test_password_and_token_not_stored_in_plaintext(client, settings):
    token = client.post("/api/auth/login", json={"username": ADMIN_USER, "password": ADMIN_PASSWORD}).json()["token"]
    raw = open(settings.db_path, "rb").read()
    conn = db.connect(settings.db_path)
    dump = "\n".join(conn.iterdump())
    conn.close()
    for secret in (ADMIN_PASSWORD, token):
        assert secret not in dump
        assert secret.encode() not in raw


def test_create_admin_validation(settings):
    with pytest.raises(CLIError, match="at least"):
        create_admin(settings.db_path, "other", "short")
    with pytest.raises(CLIError, match="username"):
        create_admin(settings.db_path, "bad name!", "long-enough-password")
    create_admin(settings.db_path, "second", "long-enough-password")
    with pytest.raises(CLIError, match="already exists"):
        create_admin(settings.db_path, "SECOND", "long-enough-password")

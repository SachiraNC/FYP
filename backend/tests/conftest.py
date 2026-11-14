from __future__ import annotations

import io

import paramiko
import pytest
from cryptography.fernet import Fernet
from fastapi.testclient import TestClient

from app import security
from app.cli import create_admin
from app.config import ENV_MASTER_KEY, Settings
from app.main import create_app

from .fake_ssh import FakeSSHServer

ADMIN_USER = "admin"
ADMIN_PASSWORD = "correct-horse-battery-staple"
LOGIN_PASSWORD = "S3cret-login-pw!"       # distinctive values so leak checks are meaningful
SUDO_PASSWORD = "S3cret-sudo-pw!"
KEY_PASSPHRASE = "S3cret-key-passphrase!"


@pytest.fixture(autouse=True)
def fast_scrypt(monkeypatch):
    monkeypatch.setattr(security, "_N", 2**12)
    monkeypatch.setattr(security, "_DUMMY_HASH", None)


@pytest.fixture
def master_key(monkeypatch):
    key = Fernet.generate_key().decode()
    monkeypatch.setenv(ENV_MASTER_KEY, key)
    return key


@pytest.fixture
def settings(tmp_path):
    return Settings(db_path=str(tmp_path / "test.db"), session_ttl_seconds=3600,
                    ssh_connect_timeout=5.0, ssh_command_timeout=10.0)


@pytest.fixture
def app(settings, master_key):
    app = create_app(settings)
    create_admin(settings.db_path, ADMIN_USER, ADMIN_PASSWORD)
    return app


@pytest.fixture
def client(app):
    with TestClient(app) as c:
        yield c


@pytest.fixture
def auth(client):
    r = client.post("/api/auth/login", json={"username": ADMIN_USER, "password": ADMIN_PASSWORD})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


def _pem(key: paramiko.PKey, passphrase: str | None = None) -> str:
    buf = io.StringIO()
    key.write_private_key(buf, password=passphrase)
    return buf.getvalue()


@pytest.fixture(scope="session")
def client_key():
    return paramiko.ECDSAKey.generate()


@pytest.fixture
def client_key_pem(client_key):
    return _pem(client_key)


@pytest.fixture
def client_key_pem_encrypted(client_key):
    return _pem(client_key, KEY_PASSPHRASE)


@pytest.fixture
def ssh_server(tmp_path, client_key):
    root = tmp_path / "sftp"
    root.mkdir()
    server = FakeSSHServer(str(root), client_key=client_key, password=LOGIN_PASSWORD)
    yield server
    server.close()


@pytest.fixture
def host_payload(ssh_server, client_key_pem):
    return {
        "name": "web-01",
        "address": "127.0.0.1",
        "port": ssh_server.port,
        "username": "tester",
        "tags": ["prod", "web"],
        "auth_method": "ssh_key",
        "private_key": client_key_pem,
        "sudo_mode": "nopasswd",
        "authorised_use_confirmed": True,
    }

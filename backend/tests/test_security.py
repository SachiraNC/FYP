import pytest
from cryptography.fernet import Fernet

from app import db
from app.config import ENV_MASTER_KEY, Settings
from app.main import create_app
from app.security import hash_password, hash_token, new_session_token, verify_password
from app.vault import Vault, VaultError


# --- password hashing -------------------------------------------------------------------

def test_password_hash_roundtrip():
    h = hash_password("a long admin password")
    assert h.startswith("scrypt$")
    assert "a long admin password" not in h
    assert verify_password("a long admin password", h)
    assert not verify_password("wrong password", h)


def test_password_hash_is_salted():
    assert hash_password("same") != hash_password("same")


def test_verify_unknown_user_and_garbage_hash_fail():
    assert not verify_password("anything", None)
    assert not verify_password("anything", "not-a-hash")
    assert not verify_password("anything", "bcrypt$1$2$3$x$y")


def test_session_token_only_hash_is_stored():
    token, token_hash = new_session_token()
    assert len(token) >= 40
    assert token_hash == hash_token(token) and token not in token_hash


# --- vault ------------------------------------------------------------------------------

def test_vault_roundtrip_and_ciphertext_hides_plaintext():
    v = Vault(Fernet.generate_key())
    ct = v.encrypt("hunter2-secret")
    assert b"hunter2-secret" not in ct
    assert v.decrypt(ct) == "hunter2-secret"


def test_vault_wrong_key_cannot_decrypt():
    ct = Vault(Fernet.generate_key()).encrypt("x")
    with pytest.raises(VaultError, match="could not be decrypted"):
        Vault(Fernet.generate_key()).decrypt(ct)


def test_vault_rejects_invalid_key_without_echoing_it():
    with pytest.raises(VaultError) as e:
        Vault("this-is-not-a-fernet-key")
    assert "this-is-not-a-fernet-key" not in str(e.value)


def test_vault_repr_hides_key():
    key = Fernet.generate_key()
    assert key.decode() not in repr(Vault(key))


def test_vault_from_env_requires_key(monkeypatch):
    monkeypatch.delenv(ENV_MASTER_KEY, raising=False)
    with pytest.raises(VaultError, match="not set"):
        Vault.from_env()


def test_app_refuses_to_start_without_master_key(monkeypatch, tmp_path):
    monkeypatch.delenv(ENV_MASTER_KEY, raising=False)
    with pytest.raises(VaultError):
        create_app(Settings(db_path=str(tmp_path / "x.db")))


def test_vault_store_and_load(tmp_path):
    path = str(tmp_path / "v.db")
    db.init_db(path)
    conn = db.connect(path)
    conn.execute("INSERT INTO admins (username, password_hash, created_at) VALUES ('a', 'x', 'now')")
    conn.execute("INSERT INTO hosts (name, address, port, username, auth_method, sudo_mode, authorised_by, "
                 "authorised_at, authorisation_statement, created_at, updated_at) "
                 "VALUES ('h', '10.0.0.1', 22, 'u', 'password', 'none', 1, 'now', 's', 'now', 'now')")
    v = Vault(Fernet.generate_key())
    v.store(conn, 1, "password", "pw-1")
    v.store(conn, 1, "password", "pw-2")  # upsert
    assert v.load_all(conn, 1) == {"password": "pw-2"}
    raw = conn.execute("SELECT ciphertext FROM credentials").fetchone()[0]
    assert b"pw-2" not in raw
    with pytest.raises(ValueError):
        v.store(conn, 1, "api_token", "x")

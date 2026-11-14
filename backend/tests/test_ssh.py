import io
import logging
import shlex
import time

import paramiko
import pytest

from app.ssh import (
    AuthenticationFailed, CommandFailed, ConnectionFailed, Credentials, HostKey, HostKeyMismatch, InvalidCredential,
    SSHConnector, fetch_host_key, load_private_key,
)

from .conftest import KEY_PASSPHRASE, LOGIN_PASSWORD, SUDO_PASSWORD
from .fake_ssh import USER, SilentServer


def key_creds(pem, passphrase=None):
    return Credentials(USER, "ssh_key", private_key=pem, key_passphrase=passphrase)


def pw_creds(pw=LOGIN_PASSWORD, sudo_password=None):
    return Credentials(USER, "password", password=pw, sudo_password=sudo_password)


def connector(server, creds, **kw):
    kw.setdefault("connect_timeout", 5)
    kw.setdefault("command_timeout", 10)
    return SSHConnector("127.0.0.1", server.port, creds, **kw)


# --- keys ---------------------------------------------------------------------------------

def test_load_private_key_types():
    for cls in (paramiko.ECDSAKey, paramiko.RSAKey):
        buf = io.StringIO()
        k = cls.generate(bits=2048) if cls is paramiko.RSAKey else cls.generate()
        k.write_private_key(buf)
        assert load_private_key(buf.getvalue()).asbytes() == k.asbytes()


def test_load_encrypted_key(client_key_pem_encrypted, client_key):
    with pytest.raises(InvalidCredential, match="passphrase is required"):
        load_private_key(client_key_pem_encrypted)
    with pytest.raises(InvalidCredential, match="could not be loaded"):
        load_private_key(client_key_pem_encrypted, "wrong")
    assert load_private_key(client_key_pem_encrypted, KEY_PASSPHRASE).asbytes() == client_key.asbytes()


def test_load_garbage_key():
    with pytest.raises(InvalidCredential):
        load_private_key("-----BEGIN OPENSSH PRIVATE KEY-----\nnope\n-----END OPENSSH PRIVATE KEY-----\n")


def test_credentials_repr_hides_secrets():
    r = repr(Credentials(USER, "password", private_key="PK", key_passphrase="KP", password="PW", sudo_password="SP"))
    for s in ("PK", "KP", "PW", "SP"):
        assert f"'{s}'" not in r


def test_fingerprint_matches_openssh_format(ssh_server):
    key = HostKey.from_pkey(ssh_server.host_key)
    assert key.fingerprint.startswith("SHA256:") and len(key.fingerprint) == 50
    assert HostKey(key.key_type, key.data).to_pkey().asbytes() == ssh_server.host_key.asbytes()


# --- connect / auth / host key -------------------------------------------------------------

def test_key_auth_and_trust_on_first_use(ssh_server, client_key_pem):
    with connector(ssh_server, key_creds(client_key_pem)) as c:
        assert c.host_key_is_new
        assert c.presented_host_key == HostKey.from_pkey(ssh_server.host_key)
        assert c.run("id -un").stdout.strip() == USER


def test_encrypted_key_auth(ssh_server, client_key_pem_encrypted):
    with connector(ssh_server, key_creds(client_key_pem_encrypted, KEY_PASSPHRASE)) as c:
        assert c.run("true").ok


def test_password_auth(ssh_server):
    with connector(ssh_server, pw_creds()) as c:
        assert c.run("echo hello").stdout == "hello\n"


def test_wrong_password(ssh_server):
    with pytest.raises(AuthenticationFailed):
        connector(ssh_server, pw_creds("nope")).connect()


def test_wrong_key(ssh_server):
    buf = io.StringIO()
    paramiko.ECDSAKey.generate().write_private_key(buf)
    with pytest.raises(AuthenticationFailed):
        connector(ssh_server, key_creds(buf.getvalue())).connect()


def test_pinned_key_verified(ssh_server, client_key_pem):
    pinned = HostKey.from_pkey(ssh_server.host_key)
    with connector(ssh_server, key_creds(client_key_pem), known_host_key=pinned) as c:
        assert not c.host_key_is_new
        assert c.presented_host_key == pinned


def test_changed_host_key_same_type_is_refused(ssh_server, client_key_pem):
    pinned = HostKey.from_pkey(ssh_server.host_key)
    ssh_server.host_key = paramiko.ECDSAKey.generate()
    with pytest.raises(HostKeyMismatch) as e:
        connector(ssh_server, key_creds(client_key_pem), known_host_key=pinned).connect()
    assert e.value.expected == pinned
    assert e.value.presented == HostKey.from_pkey(ssh_server.host_key)


def test_changed_host_key_different_type_is_refused_not_tofu(ssh_server, client_key_pem):
    pinned = HostKey.from_pkey(ssh_server.host_key)            # ECDSA pinned
    ssh_server.host_key = paramiko.RSAKey.generate(2048)       # server now only has RSA
    with pytest.raises(HostKeyMismatch):
        connector(ssh_server, key_creds(client_key_pem), known_host_key=pinned).connect()


def test_no_credentials_sent_on_host_key_mismatch(ssh_server):
    pinned = HostKey.from_pkey(ssh_server.host_key)
    ssh_server.host_key = paramiko.ECDSAKey.generate()
    with pytest.raises(HostKeyMismatch):
        connector(ssh_server, pw_creds(), known_host_key=pinned).connect()
    assert ssh_server.auth_attempts == 0


def test_fetch_host_key(ssh_server):
    assert fetch_host_key("127.0.0.1", ssh_server.port, timeout=5) == HostKey.from_pkey(ssh_server.host_key)


def test_connect_refused():
    import socket
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    with pytest.raises(ConnectionFailed):
        SSHConnector("127.0.0.1", port, pw_creds(), connect_timeout=2).connect()


def test_connect_timeout_when_server_silent():
    srv = SilentServer()
    try:
        start = time.monotonic()
        with pytest.raises(ConnectionFailed):
            SSHConnector("127.0.0.1", srv.port, pw_creds(), connect_timeout=0.5).connect()
        assert time.monotonic() - start < 5
        with pytest.raises(ConnectionFailed):
            fetch_host_key("127.0.0.1", srv.port, timeout=0.5)
    finally:
        srv.close()


# --- commands ------------------------------------------------------------------------------

def test_run_exit_status_and_stderr(ssh_server, client_key_pem):
    with connector(ssh_server, key_creds(client_key_pem)) as c:
        r = c.run("fail 3")
        assert r.exit_status == 3 and not r.ok and r.stderr == "boom\n"


def test_run_timeout(ssh_server, client_key_pem):
    with connector(ssh_server, key_creds(client_key_pem)) as c:
        start = time.monotonic()
        r = c.run("sleep 5", timeout=0.5)
        assert r.timed_out and r.exit_status is None and not r.ok
        assert time.monotonic() - start < 3


def test_run_stdin(ssh_server, client_key_pem):
    with connector(ssh_server, key_creds(client_key_pem)) as c:
        assert c.run("cat", stdin_data="abc").stdout == "abc"


def test_run_output_cap(ssh_server, client_key_pem):
    with connector(ssh_server, key_creds(client_key_pem), max_output_bytes=1000) as c:
        r = c.run("big 5000")
        assert r.truncated and len(r.stdout) == 1000 and r.ok


def test_sudo_nopasswd(ssh_server, client_key_pem):
    with connector(ssh_server, key_creds(client_key_pem), sudo_mode="nopasswd") as c:
        assert c.run("echo \"a  b\" 'c'", sudo=True).stdout == "a  b c\n"
    # the whole command reaches sh -c as a single, correctly quoted argument
    assert ssh_server.commands[-1] == "sudo -n -- sh -c " + shlex.quote("echo \"a  b\" 'c'")
    ssh_server.sudo_nopasswd = False
    with connector(ssh_server, key_creds(client_key_pem), sudo_mode="nopasswd") as c:
        assert not c.run("true", sudo=True).ok


def test_sudo_password_not_leaked_to_command_stdin(ssh_server, client_key_pem):
    ssh_server.sudo_password = SUDO_PASSWORD
    creds = Credentials(USER, "ssh_key", private_key=client_key_pem, sudo_password=SUDO_PASSWORD)
    with connector(ssh_server, creds, sudo_mode="password") as c:
        r = c.run("cat", sudo=True, stdin_data="payload")
    assert r.ok and r.stdout == "payload"
    assert SUDO_PASSWORD not in ssh_server.commands[-1]          # not on the command line
    assert ssh_server.stdin_seen[-1] == b"payload"               # not passed to the command


def test_sudo_password_falls_back_to_login_password(ssh_server):
    ssh_server.sudo_password = LOGIN_PASSWORD
    with connector(ssh_server, pw_creds(), sudo_mode="password") as c:
        assert c.run("true", sudo=True).ok


def test_sudo_mode_none_runs_directly(ssh_server, client_key_pem):
    with connector(ssh_server, key_creds(client_key_pem), sudo_mode="none") as c:
        c.run("true", sudo=True)
    assert ssh_server.commands[-1] == "true"


# --- file transfer -------------------------------------------------------------------------

def test_upload_download_roundtrip(ssh_server, client_key_pem, tmp_path):
    src = tmp_path / "audit.sh"
    src.write_bytes(b"#!/bin/bash\necho hi\n" * 1000)
    dst = tmp_path / "back.sh"
    with connector(ssh_server, key_creds(client_key_pem)) as c:
        c.upload(src, "/audit.sh", mode=0o700)
        c.download("/audit.sh", dst)
    assert dst.read_bytes() == src.read_bytes()
    assert ("/audit.sh", 0o700) in [(p, m & 0o777) for p, m in ssh_server.chmods]


def test_download_missing_file(ssh_server, client_key_pem, tmp_path):
    with connector(ssh_server, key_creds(client_key_pem)) as c:
        with pytest.raises(CommandFailed):
            c.download("/does-not-exist", tmp_path / "x")


def test_connector_never_logs_secrets(ssh_server, caplog):
    ssh_server.sudo_password = LOGIN_PASSWORD
    caplog.set_level(logging.DEBUG)
    with connector(ssh_server, pw_creds(), sudo_mode="password") as c:
        c.run("true", sudo=True)
    with pytest.raises(AuthenticationFailed):
        connector(ssh_server, pw_creds("Wr0ng-S3cret!")).connect()
    assert LOGIN_PASSWORD not in caplog.text and "Wr0ng-S3cret!" not in caplog.text

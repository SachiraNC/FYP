"""SSH connector (paramiko): connection, command execution, file transfer, host-key pinning.

Host-key policy (trust on first use, then pin):
* No stored key  -> the presented key is accepted and exposed as ``presented_host_key`` with
  ``host_key_is_new = True``; the caller persists it and tells the admin to verify the
  fingerprint out of band.
* Stored key     -> the server must present exactly that key. Any other key, including a key of
  a different type, raises ``HostKeyMismatch``. It is never silently re-trusted; an admin must
  confirm the new fingerprint explicitly.

Secrets are passed in ``Credentials`` (fields excluded from repr) and never logged. The SSH
agent and ~/.ssh keys of the server running this backend are never used.
"""
from __future__ import annotations

import base64
import hashlib
import io
import logging
import shlex
import socket
import time
from dataclasses import dataclass, field
from pathlib import Path

import paramiko

log = logging.getLogger(__name__)
# paramiko's DEBUG output is noisy and not needed; secrets are never passed to it as log args.
logging.getLogger("paramiko").setLevel(logging.WARNING)

_KEY_CLASSES = (paramiko.Ed25519Key, paramiko.ECDSAKey, paramiko.RSAKey)


class SSHError(Exception):
    code = "ssh_error"


class ConnectionFailed(SSHError):
    code = "connection_failed"


class AuthenticationFailed(SSHError):
    code = "authentication_failed"


class InvalidCredential(SSHError):
    code = "invalid_credential"


class CommandFailed(SSHError):
    code = "command_failed"


@dataclass(frozen=True)
class HostKey:
    key_type: str  # e.g. ssh-ed25519, ecdsa-sha2-nistp256, ssh-rsa
    data: str      # base64 public key blob, as in known_hosts

    @property
    def fingerprint(self) -> str:
        """OpenSSH format, comparable with `ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub`."""
        digest = hashlib.sha256(base64.b64decode(self.data)).digest()
        return "SHA256:" + base64.b64encode(digest).decode("ascii").rstrip("=")

    @classmethod
    def from_pkey(cls, key: paramiko.PKey) -> "HostKey":
        return cls(key.get_name(), key.get_base64())

    def to_pkey(self) -> paramiko.PKey:
        return paramiko.PKey.from_type_string(self.key_type, base64.b64decode(self.data))


class HostKeyMismatch(SSHError):
    code = "host_key_mismatch"

    def __init__(self, expected: HostKey, presented: HostKey):
        super().__init__(
            f"host key changed: expected {expected.key_type} {expected.fingerprint}, "
            f"presented {presented.key_type} {presented.fingerprint}"
        )
        self.expected = expected
        self.presented = presented


@dataclass(frozen=True)
class Credentials:
    username: str
    auth_method: str  # "ssh_key" | "password"
    private_key: str | None = field(default=None, repr=False)
    key_passphrase: str | None = field(default=None, repr=False)
    password: str | None = field(default=None, repr=False)
    sudo_password: str | None = field(default=None, repr=False)


@dataclass(frozen=True)
class CommandResult:
    exit_status: int | None  # None when timed out
    stdout: str
    stderr: str
    timed_out: bool = False
    truncated: bool = False

    @property
    def ok(self) -> bool:
        return self.exit_status == 0 and not self.timed_out


def load_private_key(text: str, passphrase: str | None = None) -> paramiko.PKey:
    """Parse an OpenSSH/PEM private key (Ed25519, ECDSA or RSA) held in memory."""
    needs_passphrase = False
    for cls in _KEY_CLASSES:
        try:
            return cls.from_private_key(io.StringIO(text), password=passphrase)
        except paramiko.PasswordRequiredException:
            needs_passphrase = True
        except (paramiko.SSHException, ValueError, TypeError, IndexError):
            continue
    if needs_passphrase and not passphrase:
        raise InvalidCredential("private key is encrypted: a key passphrase is required")
    raise InvalidCredential("private key could not be loaded (unsupported format or wrong passphrase)")


def _host_key_name(address: str, port: int) -> str:
    return address if port == 22 else f"[{address}]:{port}"


class _TrustOnFirstUse(paramiko.MissingHostKeyPolicy):
    def __init__(self, connector: "SSHConnector"):
        self._c = connector

    def missing_host_key(self, client, hostname, key):
        presented = HostKey.from_pkey(key)
        if self._c.known_host_key is not None:
            # A pinned key exists but the server negotiated a key we do not know
            # (e.g. a different type). Treat as a change, never as first use.
            raise HostKeyMismatch(self._c.known_host_key, presented)
        self._c.presented_host_key = presented
        self._c.host_key_is_new = True
        log.info("first connection to %s: host key %s %s accepted (trust on first use)",
                 hostname, presented.key_type, presented.fingerprint)


class SSHConnector:
    def __init__(
        self,
        address: str,
        port: int,
        credentials: Credentials,
        *,
        known_host_key: HostKey | None = None,
        sudo_mode: str = "none",
        connect_timeout: float = 10.0,
        command_timeout: float = 300.0,
        max_output_bytes: int = 16 * 1024 * 1024,
    ):
        if sudo_mode not in ("none", "nopasswd", "password"):
            raise ValueError(f"unknown sudo_mode {sudo_mode!r}")
        self.address = address
        self.port = port
        self.credentials = credentials
        self.known_host_key = known_host_key
        self.sudo_mode = sudo_mode
        self.connect_timeout = connect_timeout
        self.command_timeout = command_timeout
        self.max_output_bytes = max_output_bytes
        self.presented_host_key: HostKey | None = None
        self.host_key_is_new = False
        self._client: paramiko.SSHClient | None = None

    def __repr__(self) -> str:
        return f"<SSHConnector {self.credentials.username}@{self.address}:{self.port}>"

    # --- connection ------------------------------------------------------------------

    def __enter__(self) -> "SSHConnector":
        self.connect()
        return self

    def __exit__(self, *exc) -> None:
        self.close()

    def connect(self) -> None:
        if self._client is not None:
            return
        creds = self.credentials
        pkey = password = None
        if creds.auth_method == "ssh_key":
            pkey = load_private_key(creds.private_key or "", creds.key_passphrase)
        elif creds.auth_method == "password":
            if not creds.password:
                raise InvalidCredential("password authentication selected but no password is stored")
            password = creds.password
        else:
            raise InvalidCredential(f"unknown auth method {creds.auth_method!r}")

        client = paramiko.SSHClient()
        if self.known_host_key is not None:
            client.get_host_keys().add(
                _host_key_name(self.address, self.port), self.known_host_key.key_type, self.known_host_key.to_pkey()
            )
        client.set_missing_host_key_policy(_TrustOnFirstUse(self))
        t = self.connect_timeout
        target = f"{self.address}:{self.port}"
        try:
            client.connect(
                hostname=self.address, port=self.port, username=creds.username,
                pkey=pkey, password=password,
                timeout=t, banner_timeout=t, auth_timeout=t, channel_timeout=t,
                allow_agent=False, look_for_keys=False,
            )
        except HostKeyMismatch:
            client.close()
            raise
        except paramiko.BadHostKeyException as e:
            client.close()
            raise HostKeyMismatch(self.known_host_key, HostKey.from_pkey(e.key)) from None
        except paramiko.AuthenticationException:
            client.close()
            raise AuthenticationFailed(f"authentication failed for user {creds.username!r} on {target}") from None
        except (socket.timeout, TimeoutError):
            client.close()
            raise ConnectionFailed(f"timed out connecting to {target}") from None
        except (paramiko.SSHException, OSError, EOFError) as e:
            client.close()
            raise ConnectionFailed(f"could not connect to {target}: {e or type(e).__name__}") from None

        self.presented_host_key = HostKey.from_pkey(client.get_transport().get_remote_server_key())
        self._client = client

    def close(self) -> None:
        if self._client is not None:
            self._client.close()
            self._client = None

    def _transport(self) -> paramiko.Transport:
        if self._client is None:
            raise SSHError("not connected")
        transport = self._client.get_transport()
        if transport is None or not transport.is_active():
            raise ConnectionFailed("SSH connection is no longer active")
        return transport

    # --- commands --------------------------------------------------------------------

    def _wrap(self, command: str, sudo: bool) -> tuple[str, bytes]:
        """Return (command line, bytes to send on stdin before any caller data)."""
        if not sudo or self.sudo_mode == "none":  # 'none' = the login user is root
            return command, b""
        inner = shlex.quote(command)
        if self.sudo_mode == "nopasswd":
            return f"sudo -n -- sh -c {inner}", b""
        pw = self.credentials.sudo_password or self.credentials.password
        if not pw:
            raise InvalidCredential("sudo mode 'password' requires a sudo password")
        # -k ignores cached sudo credentials so the password line is always consumed by
        # sudo itself and can never leak into the command's stdin.
        return f"sudo -k -S -p '' -- sh -c {inner}", (pw + "\n").encode("utf-8")

    def run(
        self,
        command: str,
        *,
        sudo: bool = False,
        timeout: float | None = None,
        stdin_data: str | bytes | None = None,
    ) -> CommandResult:
        transport = self._transport()
        line, preamble = self._wrap(command, sudo)
        timeout = self.command_timeout if timeout is None else timeout
        try:
            chan = transport.open_session(timeout=self.connect_timeout)
        except (paramiko.SSHException, OSError, EOFError) as e:
            raise CommandFailed(f"could not open an SSH channel: {e or type(e).__name__}") from None
        out, err = bytearray(), bytearray()
        timed_out = truncated = False
        try:
            chan.settimeout(self.connect_timeout)
            chan.exec_command(line)
            try:
                if preamble:
                    chan.sendall(preamble)
                if stdin_data is not None:
                    chan.sendall(stdin_data.encode("utf-8") if isinstance(stdin_data, str) else stdin_data)
                chan.shutdown_write()
            except OSError:
                # The command may legitimately exit without reading its stdin.
                if not (chan.closed or chan.exit_status_ready()):
                    raise
            deadline = time.monotonic() + timeout
            while True:
                progressed = False
                while chan.recv_ready():
                    truncated |= self._append(out, chan.recv(65536))
                    progressed = True
                while chan.recv_stderr_ready():
                    truncated |= self._append(err, chan.recv_stderr(65536))
                    progressed = True
                if chan.exit_status_ready() and not chan.recv_ready() and not chan.recv_stderr_ready():
                    break
                if time.monotonic() >= deadline:
                    timed_out = True
                    break
                if not progressed:
                    time.sleep(0.01)
            exit_status = None if timed_out else chan.recv_exit_status()
        except (paramiko.SSHException, OSError, EOFError) as e:
            raise CommandFailed(f"command execution failed: {e or type(e).__name__}") from None
        finally:
            chan.close()
        return CommandResult(
            exit_status=exit_status,
            stdout=out.decode("utf-8", "replace"),
            stderr=err.decode("utf-8", "replace"),
            timed_out=timed_out,
            truncated=truncated,
        )

    def _append(self, buf: bytearray, data: bytes) -> bool:
        room = self.max_output_bytes - len(buf)
        if room <= 0:
            return bool(data)
        buf += data[:room]
        return len(data) > room

    # --- file transfer ---------------------------------------------------------------

    def _sftp(self) -> paramiko.SFTPClient:
        try:
            sftp = paramiko.SFTPClient.from_transport(self._transport())
        except (paramiko.SSHException, OSError, EOFError) as e:
            raise CommandFailed(f"could not start SFTP: {e or type(e).__name__}") from None
        sftp.get_channel().settimeout(self.command_timeout)
        return sftp

    def upload(self, local_path: str | Path, remote_path: str, *, mode: int = 0o600) -> None:
        """Upload a file. Permissions are set before any content is written."""
        sftp = self._sftp()
        try:
            with sftp.open(remote_path, "wb") as remote, open(local_path, "rb") as local:
                sftp.chmod(remote_path, mode)
                while chunk := local.read(32768):
                    remote.write(chunk)
            size = sftp.stat(remote_path).st_size
            expected = Path(local_path).stat().st_size
            if size != expected:
                raise CommandFailed(f"upload to {remote_path} incomplete ({size} of {expected} bytes)")
        except (paramiko.SSHException, OSError, EOFError) as e:
            raise CommandFailed(f"upload to {remote_path} failed: {e or type(e).__name__}") from None
        finally:
            sftp.close()

    def download(self, remote_path: str, local_path: str | Path) -> None:
        sftp = self._sftp()
        try:
            sftp.get(remote_path, str(local_path))
        except (paramiko.SSHException, OSError, EOFError) as e:
            raise CommandFailed(f"download of {remote_path} failed: {e or type(e).__name__}") from None
        finally:
            sftp.close()


def fetch_host_key(address: str, port: int, *, timeout: float = 10.0, preferred_type: str | None = None) -> HostKey:
    """Read the host key a server presents, without authenticating.

    ``preferred_type`` makes the negotiation prefer the same key type as a pinned key, matching
    what ``SSHConnector`` negotiates, so an admin confirms the key that will actually be checked.
    """
    try:
        sock = socket.create_connection((address, port), timeout=timeout)
    except OSError as e:
        raise ConnectionFailed(f"could not connect to {address}:{port}: {e}") from None
    transport = paramiko.Transport(sock)
    try:
        transport.banner_timeout = timeout
        if preferred_type:
            opts = transport.get_security_options()
            types = list(opts.key_types)
            candidates = ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"] if preferred_type == "ssh-rsa" else [preferred_type]
            want = next((c for c in candidates if c in types), None)
            if want:
                opts.key_types = [want] + [t for t in types if t != want]
        transport.start_client(timeout=timeout)
        return HostKey.from_pkey(transport.get_remote_server_key())
    except (paramiko.SSHException, OSError, EOFError) as e:
        raise ConnectionFailed(f"could not read host key from {address}:{port}: {e or type(e).__name__}") from None
    finally:
        transport.close()

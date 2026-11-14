"""In-process SSH/SFTP server (paramiko) for tests.

Understands a handful of commands, sudo wrapping as produced by SSHConnector, and SFTP
against a temporary directory. Host key can be swapped to simulate a changed key.
"""
from __future__ import annotations

import os
import shlex
import socket
import threading
import time

import paramiko

USER = "tester"


class _SFTPHandle(paramiko.SFTPHandle):
    def stat(self):
        return paramiko.SFTPAttributes.from_stat(os.fstat(self.readfile.fileno()))

    def chattr(self, attr):
        return paramiko.SFTP_OK


class _SFTPServer(paramiko.SFTPServerInterface):
    def __init__(self, server, root, *args, **kwargs):
        super().__init__(server, *args, **kwargs)
        self.root = root

    def _real(self, path):
        return os.path.join(self.root, path.lstrip("/"))

    def open(self, path, flags, attr):
        real = self._real(path)
        try:
            fd = os.open(real, flags | getattr(os, "O_BINARY", 0), 0o666)
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)
        mode = "wb" if flags & (os.O_WRONLY | os.O_RDWR) else "rb"
        if flags & os.O_RDWR:
            mode = "r+b"
        f = os.fdopen(fd, mode)
        h = _SFTPHandle(flags)
        h.filename, h.readfile, h.writefile = real, f, f
        return h

    def stat(self, path):
        try:
            return paramiko.SFTPAttributes.from_stat(os.stat(self._real(path)))
        except OSError as e:
            return paramiko.SFTPServer.convert_errno(e.errno)

    lstat = stat

    def chattr(self, path, attr):
        self.server_owner.chmods.append((path, attr.st_mode))
        return paramiko.SFTP_OK


class _Iface(paramiko.ServerInterface):
    def __init__(self, owner):
        self.owner = owner

    def get_allowed_auths(self, username):
        return "password,publickey"

    def check_auth_password(self, username, password):
        self.owner.auth_attempts += 1
        ok = username == USER and self.owner.password is not None and password == self.owner.password
        return paramiko.AUTH_SUCCESSFUL if ok else paramiko.AUTH_FAILED

    def check_auth_publickey(self, username, key):
        self.owner.auth_attempts += 1
        ok = username == USER and self.owner.client_key is not None and \
            key.asbytes() == self.owner.client_key.asbytes()
        return paramiko.AUTH_SUCCESSFUL if ok else paramiko.AUTH_FAILED

    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == "session" else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

    def check_channel_exec_request(self, channel, command):
        threading.Thread(target=self.owner._exec, args=(channel, command.decode()), daemon=True).start()
        return True


class FakeSSHServer:
    def __init__(self, sftp_root, *, host_key=None, client_key=None, password=None):
        self.host_key = host_key or paramiko.ECDSAKey.generate()
        self.client_key = client_key
        self.password = password
        self.sudo_nopasswd = True
        self.sudo_password = None
        self.sftp_root = sftp_root
        self.auth_attempts = 0
        self.commands: list[str] = []
        self.stdin_seen: list[bytes] = []
        self.chmods: list = []
        self._sock = socket.socket()
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(20)
        self.port = self._sock.getsockname()[1]
        self._transports = []
        self._stop = False
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while not self._stop:
            try:
                s, _ = self._sock.accept()
            except OSError:
                return
            t = paramiko.Transport(s)
            t.add_server_key(self.host_key)
            server_owner = self

            class _Bound(_SFTPServer):
                def __init__(self, server, *a, **k):
                    super().__init__(server, server_owner.sftp_root, *a, **k)
                    self.server_owner = server_owner

            t.set_subsystem_handler("sftp", paramiko.SFTPServer, _Bound)
            self._transports.append(t)
            try:
                t.start_server(server=_Iface(self))
            except (paramiko.SSHException, EOFError, OSError):
                continue
            threading.Thread(target=self._channels, args=(t,), daemon=True).start()

    def _channels(self, t):
        # Keep references: paramiko closes a Channel when it is garbage-collected.
        held = []
        while t.is_active():
            chan = t.accept(0.5)
            if chan is not None:
                held.append(chan)

    def _exec(self, chan, command):
        # paramiko sends the exec "success" reply only after check_channel_exec_request returns;
        # a real sshd never closes the channel before that reply, so wait briefly.
        time.sleep(0.02)
        self.commands.append(command)
        stdin = chan.makefile("rb")
        try:
            argv = shlex.split(command)
            if argv[:2] == ["sudo", "-n"]:
                if not self.sudo_nopasswd:
                    chan.sendall_stderr(b"sudo: a password is required\n")
                    return self._exit(chan, 1)
                argv = shlex.split(argv[argv.index("-c") + 1])
            elif argv[:3] == ["sudo", "-k", "-S"]:
                line = stdin.readline().rstrip(b"\n").decode()
                if self.sudo_password is None or line != self.sudo_password:
                    chan.sendall_stderr(b"sudo: incorrect password\n")
                    return self._exit(chan, 1)
                argv = shlex.split(argv[argv.index("-c") + 1])
            self._run(chan, argv, stdin)
        except Exception as e:  # pragma: no cover - surfaces server bugs in tests
            chan.sendall_stderr(f"fake server error: {e}\n".encode())
            self._exit(chan, 255)

    def _run(self, chan, argv, stdin):
        cmd = argv[0] if argv else ""
        if cmd == "id" and argv[1:] == ["-un"]:
            chan.sendall(f"{USER}\n".encode())
            return self._exit(chan, 0)
        if cmd == "true":
            return self._exit(chan, 0)
        if cmd == "echo":
            chan.sendall((" ".join(argv[1:]) + "\n").encode())
            return self._exit(chan, 0)
        if cmd == "fail":
            chan.sendall_stderr(b"boom\n")
            return self._exit(chan, int(argv[1]))
        if cmd == "sleep":
            time.sleep(float(argv[1]))
            return self._exit(chan, 0)
        if cmd == "cat":
            data = stdin.read()
            self.stdin_seen.append(data)
            chan.sendall(data)
            return self._exit(chan, 0)
        if cmd == "big":
            chan.sendall(b"x" * int(argv[1]))
            return self._exit(chan, 0)
        chan.sendall_stderr(f"{cmd}: command not found\n".encode())
        return self._exit(chan, 127)

    @staticmethod
    def _exit(chan, code):
        chan.send_exit_status(code)
        chan.shutdown_write()
        chan.close()

    def close(self):
        self._stop = True
        self._sock.close()
        for t in self._transports:
            t.close()


class SilentServer:
    """Accepts TCP connections but never speaks SSH (for timeout tests)."""

    def __init__(self):
        self._sock = socket.socket()
        self._sock.bind(("127.0.0.1", 0))
        self._sock.listen(5)
        self.port = self._sock.getsockname()[1]
        self._conns = []
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while True:
            try:
                c, _ = self._sock.accept()
            except OSError:
                return
            self._conns.append(c)

    def close(self):
        self._sock.close()
        for c in self._conns:
            c.close()

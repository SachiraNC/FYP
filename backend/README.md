# Backend — CIS compliance platform API

FastAPI + SQLite. Current scope: host inventory, credential vault, SSH connector,
local admin login, append-only audit log. (Scanning, dashboard and remediation come later.)

## Setup

```bash
python -m venv .venv
.venv/Scripts/python -m pip install -r requirements-dev.txt      # Linux/macOS: .venv/bin/python

export CISPLAT_MASTER_KEY="$(.venv/Scripts/python -m app.cli generate-key)"   # keep this safe: losing it
export CISPLAT_DB_PATH=cisplat.db                                              # makes stored credentials unreadable
.venv/Scripts/python -m app.cli create-admin admin                             # prompts for a password (min 12 chars)
.venv/Scripts/python -m uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000
```

API docs: http://127.0.0.1:8000/docs. Serve behind TLS (reverse proxy) for anything other than localhost:
bearer tokens and host credentials travel in request bodies/headers.

| Variable | Default | Meaning |
|---|---|---|
| `CISPLAT_MASTER_KEY` | — (required) | Fernet key encrypting host secrets. The API refuses to start without it. |
| `CISPLAT_DB_PATH` | `cisplat.db` | SQLite database file. |
| `CISPLAT_SESSION_TTL_SECONDS` | `28800` | Session token lifetime. |
| `CISPLAT_SSH_CONNECT_TIMEOUT` | `10` | TCP/banner/auth/channel timeout (s). |
| `CISPLAT_SSH_COMMAND_TIMEOUT` | `300` | Per-command / SFTP timeout (s). |

## Tests

```bash
.venv/Scripts/python -m pytest
```

SSH tests run against an in-process paramiko SSH/SFTP server (`tests/fake_ssh.py`); no real host
or network access is needed.

## API

All endpoints except `POST /api/auth/login` need `Authorization: Bearer <token>`.

| Method & path | Purpose |
|---|---|
| `POST /api/auth/login` · `POST /api/auth/logout` · `GET /api/auth/me` | Local admin session |
| `GET /api/hosts[?tag=]` · `POST /api/hosts` | List / add hosts (`authorised_use_confirmed: true` required) |
| `GET/PATCH/DELETE /api/hosts/{id}` | Read / update (address or port change needs re-confirmation) / delete |
| `PUT /api/hosts/{id}/credentials` | Replace a host's secrets |
| `POST /api/hosts/{id}/test` | Connection test: host key, auth, `id -un`, sudo check |
| `POST /api/hosts/{id}/host-key/trust` | Pin the presented host key if it matches a fingerprint the admin verified |
| `GET /api/audit-log?limit=&before_id=` | Read the audit log (newest first) |

### Host fields

`name`, `address` (IP or DNS name), `port`, `username`, `tags[]`, `auth_method` (`ssh_key` | `password`),
`sudo_mode`:

- `none`: the login user is root, so no sudo is used.
- `nopasswd`: `sudo -n`.
- `password`: `sudo -k -S`. The sudo password comes from `sudo_password`, or the login password when
  `auth_method` is `password`.

Secrets (`private_key`, `key_passphrase`, `password`, `sudo_password`) are write-only. Responses show
only which kinds are stored (`credentials_stored`). Password authentication is accepted, but the
response carries a warning.

### Host keys

- **First connection:** the key is pinned (trust on first use). The response tells the admin to check
  the fingerprint against `ssh-keygen -lf /etc/ssh/ssh_host_*_key.pub` on the host.
- **Changed key:** the connection is refused before any credentials are sent. The API returns `409`
  with both fingerprints and writes an audit entry.
- **Re-pinning:** the admin calls `host-key/trust` with the new fingerprint after verifying it out of
  band. You can also pre-pin a fingerprint this way before the first connection.

## Security notes

- **Admin passwords:** scrypt (N=2^17, r=8, p=1). Session tokens are random 256-bit values; only
  their SHA-256 is stored.
- **Host secrets:** Fernet (AES-128-CBC + HMAC-SHA256). The master key comes from the environment
  only.
- **Secrets never appear in:** API responses, validation errors (422 bodies don't echo input), logs,
  or the audit log (`audit.record` rejects secret-named fields).
- **Audit log:** append-only. SQLite triggers block `UPDATE` and `DELETE`. Anyone with write access to
  the database file can still drop the table, so tamper-evidence (hash chaining) is planned
  separately.
- **SSH keys:** the backend never uses its own SSH agent or `~/.ssh` keys.

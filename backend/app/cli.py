"""Administration commands.

    python -m app.cli generate-key            print a new Fernet master key
    python -m app.cli create-admin USERNAME   create a local admin (password prompted, not echoed)
"""
from __future__ import annotations

import argparse
import getpass
import re
import sqlite3
import sys

from cryptography.fernet import Fernet

from . import audit, db
from .config import Settings
from .security import MIN_ADMIN_PASSWORD_LENGTH, hash_password

_USERNAME = re.compile(r"^[A-Za-z0-9_.-]{3,64}$")


class CLIError(Exception):
    pass


def create_admin(db_path: str, username: str, password: str) -> int:
    if not _USERNAME.match(username):
        raise CLIError("username must be 3-64 characters: letters, digits, '_', '.', '-'")
    if len(password) < MIN_ADMIN_PASSWORD_LENGTH:
        raise CLIError(f"password must be at least {MIN_ADMIN_PASSWORD_LENGTH} characters")
    db.init_db(db_path)
    conn = db.connect(db_path)
    try:
        try:
            cur = conn.execute("INSERT INTO admins (username, password_hash, created_at) VALUES (?, ?, ?)",
                               (username, hash_password(password), db.utcnow()))
        except sqlite3.IntegrityError:
            raise CLIError(f"admin {username!r} already exists") from None
        audit.record(conn, actor="cli", action="admin.create", target=f"admin:{cur.lastrowid}",
                     details={"username": username})
        return cur.lastrowid
    finally:
        conn.close()


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="python -m app.cli")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("generate-key", help="print a new master key for CISPLAT_MASTER_KEY")
    ca = sub.add_parser("create-admin", help="create a local admin account")
    ca.add_argument("username")
    args = p.parse_args(argv)

    if args.cmd == "generate-key":
        print(Fernet.generate_key().decode())
        return 0
    password = getpass.getpass("New admin password: ")
    if password != getpass.getpass("Repeat password: "):
        print("passwords do not match", file=sys.stderr)
        return 1
    try:
        admin_id = create_admin(Settings.from_env().db_path, args.username, password)
    except CLIError as e:
        print(e, file=sys.stderr)
        return 1
    print(f"created admin {args.username!r} (id {admin_id})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

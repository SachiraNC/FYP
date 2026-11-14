# CLAUDE.md — Multi-host CIS Compliance Platform for Ubuntu 24.04

Final Year Project, BSc (Hons) Cyber Security — APIIT / Staffordshire University.

## Project aim

Build a **multi-host CIS Benchmark compliance platform for Ubuntu 24.04 LTS**.

- **Core features:**
  - Scan many hosts over SSH.
  - Show results on a dashboard.
  - Apply **selective, safe remediation**.
- **Requirements behind every result:**
  - Each control result carries verifiable evidence.
  - Results persist as machine-readable data, and changes between runs are tracked.
  - Accepted risks are handled as formal exceptions.
  - Output is auditor-ready.

**Novelty (what the project claims beyond existing scanners):**

1. **Safe, verified remediation.** Fixes are opt-in and applied per control. Each fix is checked
   before it runs, and the control is re-audited afterwards to prove the change worked.
2. **Confidence-graded governance mapping.** Each CIS control is mapped to governance frameworks
   (CIS Controls v8, ISO/IEC 27001:2022, NIST CSF 2.0, …), and every mapping carries an explicit
   confidence grade rather than a flat "maps to".
3. **Tamper-evident compliance history.** Stored results and history can be shown to be unaltered.

**No AI features.** No LLMs, ML models, or "AI-assisted" anything, in any component.

## Architecture

```
┌──────────────────────── backend/ (FastAPI + SQLite) ─────────────────────────┐
│ admin login + sessions · append-only audit log · host inventory              │
│ credential vault (Fernet) · SSH connector (paramiko, host-key pinning)       │
│        │ push audit script over SSH, run as root (sudo), fetch results.json  │
│        ▼                                                                     │
│ [planned] scan orchestration → results store (tamper-evident history)        │
│           → delta engine → governance mapper (confidence-graded)            │
│           → exception handler → safe remediation → governance report        │
└──────────────────────────────────────────────────────────────────────────────┘
        │ SSH (scp/sftp + exec)
        ▼
target hosts (Ubuntu 24.04): cis_ubuntu_24.04_lts_v2.0.0_audit.sh
        writes <name>.html (human report, unchanged format) and <name>.json (results.json)
```

**What exists now:**

- the audit script;
- the `backend/` foundation: inventory, vault, SSH connector, auth, and audit log.

Scan orchestration, dashboard, delta engine, governance mapping, exceptions and remediation are
**not built yet**. Downstream components consume `results.json`; they must never parse the HTML.

## Backend (`backend/`)

- **Stack:** FastAPI, SQLite (stdlib `sqlite3`, no ORM), `cryptography` (Fernet) and `paramiko`.
  Tests use `pytest` and `httpx`. These are the approved dependencies, pinned in
  `backend/requirements*.txt`; adding anything else needs explicit approval.
- **Run and test:** see `backend/README.md`. Run `python -m pytest` from `backend/` after every
  change. The SSH tests use an in-process fake server (`tests/fake_ssh.py`).
- **Layout:**
  - `app/config.py`: env settings.
  - `app/db.py`: schema and triggers.
  - `app/security.py`: scrypt and session tokens.
  - `app/vault.py`: the credential vault.
  - `app/ssh.py`: the connector.
  - `app/audit.py`: the audit log.
  - `app/inventory.py`: host helpers.
  - `app/routers/`: the HTTP API.
  - `app/cli.py`: `generate-key` and `create-admin`.
- **Security invariants (tests enforce these, so keep them):**
  - **Secrets:**
    - Stored only Fernet-encrypted. The master key comes from `CISPLAT_MASTER_KEY` and nowhere
      else; the app refuses to start without it.
    - Never returned by the API or logged, never written to the audit log (`audit.record` rejects
      secret-named fields), and never echoed in 422 responses (custom validation handler).
    - Secret inputs are `SecretStr`, and `Credentials` fields are `repr=False`.
  - **SSH keys:** prefer key authentication. Password auth is allowed but always carries a
    warning.
  - **Host keys:** trusted on first use, then pinned.
    - A changed key, or a key of a different type, is refused before authentication. The API
      returns 409 and the event is audited.
    - Re-pinning only happens when the admin supplies the verified fingerprint.
  - **Authorised use:** adding a host requires `authorised_use_confirmed: true`, recorded with who,
    when and the statement text. Changing a host's address or port requires confirming it again.
  - **Audit log:** every state-changing action, login, and SSH connection or host-key event is
    written to `audit_log`. The table is append-only (UPDATE and DELETE are blocked by triggers).
  - **Admin passwords:** scrypt hashes. Only the SHA-256 of each session token is stored.
  - **SSH defaults:** never use the backend machine's SSH agent or `~/.ssh` keys.
  - **sudo password mode:** uses `sudo -k -S`, so the password can never reach the command's stdin.
- **Scope discipline:** only build what is asked. Do not add endpoints for arbitrary remote
  command execution. The connector's `run`, `upload` and `download` are for internal use by future
  scan and remediation code.

### results.json contract (produced by the audit script, `--json FILE`)

```json
{
  "metadata": { "schema_version", "run_id", "timestamp", "hostname", "os", "kernel",
                "architecture", "benchmark", "benchmark_version", "benchmark_date",
                "scan_start", "scan_end", "script_sha256", "duration_seconds" },
  "summary":  { "total", "by_status": {"Pass","Fail","Manual Review","Not Applicable"},
                "by_assessment": {"Automated","Manual"}, "by_section": {...},
                "scored", "pass_rate_percent" },
  "controls": [ { "id", "title", "assessment", "section", "status", "evidence" } ]
}
```

- `id` is the CIS recommendation number exactly as in the benchmark (e.g. `5.1.24`). It is the
  join key for the governance mapper, delta engine and exception handler — never renumber.
- `status` ∈ `Pass | Fail | Manual Review | Not Applicable`.
- `assessment` ∈ `Automated | Manual`, and must match the benchmark PDF.

## Hard rules

1. **The audit script stays zero-dependency.** It may use Bash, coreutils and standard Ubuntu
   tools, plus the **Python 3 standard library only**: no `pip install`, no third-party modules,
   no network calls.
   - The backend pushes the script to targets over SSH, so nothing may need installing on a
     target host.
   - The backend may use only its approved dependencies (see Backend); any new dependency needs
     explicit approval.
2. **Target is Ubuntu 24.04 LTS only** (CIS Ubuntu Linux 24.04 LTS Benchmark v2.0.0,
   dated 05-28-2026). Do not add logic for other distributions to the audit script
   (cross-distro is a documented gap, G6, not a feature of this script).
3. **The CIS PDF is the source of truth** for control IDs, titles, assessment type and audit
   logic. Do not change a control's logic unless the PDF clearly disagrees, and show a diff
   summary before applying logic changes. See `VERIFICATION.md` for the current status.
4. **Do not change the HTML report format** without being asked — it is a delivered artefact.
5. The script runs as root on production-like hosts, so its audit checks must be **read-only**.
   It never remediates and never writes outside the chosen output paths.
   - Remediation is a separate, opt-in platform feature that has not been built yet.
   - It must never be bolted onto the audit script.
6. Keep `bash -n` clean. After editing the script, run
   `sudo bash cis_ubuntu_24.04_lts_v2.0.0_audit.sh --dry-run-safe`. That self-test runs `bash -n`,
   shellcheck if installed, and a compile check of the embedded Python.
7. **No AI features** anywhere in the platform.
8. Only connect to hosts whose authorised use has been confirmed (see the Backend invariants).

## Research gaps addressed (G1–G8)

| Gap | Name | Meaning in this project |
|-----|------|-------------------------|
| G1 | Per-control evidence | Every control records the exact command output that justifies its status. |
| G2 | Remediation guidance | Each failed control links to actionable, benchmark-aligned remediation steps. |
| G3 | Delta tracking | Compare runs over time (fixed / regressed / new) using persisted `results.json`. |
| G4 | Governance mapping | Map CIS controls to governance frameworks (CIS Controls v8, ISO/IEC 27001:2022, NIST CSF 2.0, etc.). |
| G5 | OSCAL output | Emit NIST OSCAL assessment-results so output is interoperable with GRC tooling. |
| G6 | Cross-distro | Acknowledged limitation: tool targets Ubuntu 24.04 only; design keeps the data model distro-neutral. |
| G7 | Exception handling | Formal risk acceptance: owner, justification, expiry, re-review; excepted findings reported separately. |
| G8 | Auditor-ready output | Reports an auditor can rely on: metadata, integrity (script SHA-256, run ID), evidence, sign-off. |

## Files

- `cis_ubuntu_24.04_lts_v2.0.0_audit.sh` — the audit script.
- `backend/` — FastAPI platform backend (see `backend/README.md`).
- `VERIFICATION.md` — script vs. CIS PDF verification (IDs, assessment types, logic differences).
- `COUNTS.md` — authoritative control counts (total, Automated/Manual, per section).
- CIS PDF: `CIS_Ubuntu_Linux_24.04_LTS_Benchmark_v2.0.0.pdf` (currently in the user's
  `Downloads` folder, not in this project folder; CIS terms forbid redistributing it, so do not
  commit it to a public repository).

## Known benchmark quirk

The v2.0.0 PDF lists **1.5.10 "Ensure core file size is configured"** in its Summary Table and
Change History, but the recommendation body (and its audit procedure) is absent. The script
therefore has no 1.5.10; the benchmark contains **332** auditable recommendations.

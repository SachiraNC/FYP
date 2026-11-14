# CLAUDE.md — CIS Benchmark Compliance Tool with Governance Mapping

Final Year Project, BSc (Hons) Cyber Security — APIIT / Staffordshire University.

## Project aim

Build an automated CIS Benchmark compliance tool for **Ubuntu 24.04 LTS** that goes beyond
pass/fail scanning: every control result carries verifiable evidence, results persist as
machine-readable data, changes between runs are tracked, findings are mapped to governance
frameworks, accepted risks are handled as formal exceptions, and the final output is
auditor-ready.

## Architecture (pipeline)

```
cis_ubuntu_24.04_lts_v2.0.0_audit.sh   (Bash + embedded Python 3 stdlib, runs as root on target)
        │  writes  <name>.html  (human report, unchanged format)
        │  writes  <name>.json  (results.json — the canonical data contract)
        ▼
governance mapper      results.json  →  control ↔ framework mappings (CIS Controls v8, ISO 27001, NIST CSF …)
        ▼
delta engine           two or more results.json  →  new / fixed / regressed / unchanged controls
        ▼
exception handler      approved risk acceptances (owner, justification, expiry) applied to findings
        ▼
governance report      auditor-ready output (HTML/PDF, OSCAL JSON)
```

Only the audit script exists so far. Downstream components consume `results.json`; they must
never parse the HTML.

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

1. **The audit script stays zero-dependency.** Bash + coreutils/standard Ubuntu tools +
   **Python 3 standard library only**. No `pip install`, no third-party modules, no network
   calls. Downstream components should also prefer stdlib; any new dependency needs explicit
   approval.
2. **Target is Ubuntu 24.04 LTS only** (CIS Ubuntu Linux 24.04 LTS Benchmark v2.0.0,
   dated 05-28-2026). Do not add logic for other distributions to the audit script
   (cross-distro is a documented gap, G6, not a feature of this script).
3. **The CIS PDF is the source of truth** for control IDs, titles, assessment type and audit
   logic. Do not change a control's logic unless the PDF clearly disagrees, and show a diff
   summary before applying logic changes. See `VERIFICATION.md` for the current status.
4. **Do not change the HTML report format** without being asked — it is a delivered artefact.
5. The script runs as root on production-like hosts: audit checks must be **read-only**.
   Never remediate, never write outside the chosen output paths.
6. Keep `bash -n` clean; run `sudo bash cis_ubuntu_24.04_lts_v2.0.0_audit.sh --dry-run-safe`
   (self-test: bash -n, shellcheck if installed, embedded-Python compile check) after edits.

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
- `VERIFICATION.md` — script vs. CIS PDF verification (IDs, assessment types, logic differences).
- `COUNTS.md` — authoritative control counts (total, Automated/Manual, per section).
- CIS PDF: `CIS_Ubuntu_Linux_24.04_LTS_Benchmark_v2.0.0.pdf` (currently in the user's
  `Downloads` folder, not in this project folder; CIS terms forbid redistributing it, so do not
  commit it to a public repository).

## Known benchmark quirk

The v2.0.0 PDF lists **1.5.10 "Ensure core file size is configured"** in its Summary Table and
Change History, but the recommendation body (and its audit procedure) is absent. The script
therefore has no 1.5.10; the benchmark contains **332** auditable recommendations.

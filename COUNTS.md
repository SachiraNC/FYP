# COUNTS.md — CIS Ubuntu Linux 24.04 LTS Benchmark v2.0.0 control counts

Derived from the benchmark PDF (table of contents cross-checked against recommendation bodies) and
from a static parse of every `record` / `check_*` call in `cis_ubuntu_24.04_lts_v2.0.0_audit.sh`.
PDF and script agree exactly on every ID and assessment type. Generated 2026-11-14.

## Totals

| | PDF | Script |
|---|---|---|
| **Total recommendations** | **332** | **332** |
| Automated | 317 | 317 |
| Manual | 15 | 15 |
| Automated share | 95.5% | 95.5% |

Notes:

- 1.5.10 "Ensure core file size is configured" appears in the PDF's Summary Table and Change History but has **no recommendation body or audit procedure**, so it is not counted (if it were: 333 total, 318 Automated). See `VERIFICATION.md` §4.
- All 317 Automated controls now produce an automated Pass/Fail/N/A (1.7.7, 5.4.2.5, 7.2.9 and 7.2.10 previously always returned `Manual Review`; fixed 2026-11-14). Counts above are by *assessment type*, not by runtime status.
- Runtime status counts (Pass / Fail / Manual Review / N/A) depend on the host; they are written to `summary` in the JSON output.

## Per chapter

| Chapter | Total | Automated | Manual |
|---|---:|---:|---:|
| 1 Initial Setup | 81 | 78 | 3 |
| 2 Services | 45 | 44 | 1 |
| 3 Network | 35 | 34 | 1 |
| 4 Host Based Firewall | 5 | 5 | 0 |
| 5 Access Control | 74 | 72 | 2 |
| 6 Logging and Auditing | 69 | 62 | 7 |
| 7 System Maintenance | 23 | 22 | 1 |
| **Total** | **332** | **317** | **15** |

## Per section

| Section | Total | Automated | Manual |
|---|---:|---:|---:|
| 1.1 Filesystem | 37 | 36 | 1 |
| 1.2 Package Management | 10 | 8 | 2 |
| 1.3 Mandatory Access Control | 4 | 4 | 0 |
| 1.4 Configure Bootloader | 2 | 2 | 0 |
| 1.5 Configure Additional Process Hardening | 11 | 11 | 0 |
| 1.6 Configure Command Line Warning Banners | 10 | 10 | 0 |
| 1.7 Configure GNOME Display Manager | 7 | 7 | 0 |
| 2.1 Configure Server Services | 23 | 22 | 1 |
| 2.2 Configure Client Services | 6 | 6 | 0 |
| 2.3 Configure Time Synchronization | 6 | 6 | 0 |
| 2.4 Job Schedulers | 10 | 10 | 0 |
| 3.1 Configure Network Devices | 3 | 2 | 1 |
| 3.2 Configure Network Kernel Modules | 6 | 6 | 0 |
| 3.3 Configure Network Kernel Parameters | 26 | 26 | 0 |
| 4.1 Configure Uncomplicated Firewall | 5 | 5 | 0 |
| 5.1 Configure SSH Server | 24 | 24 | 0 |
| 5.2 Configure privilege escalation | 7 | 7 | 0 |
| 5.3 Pluggable Authentication Modules | 26 | 25 | 1 |
| 5.4 User Accounts and Environment | 17 | 16 | 1 |
| 6.1 System Logging | 18 | 12 | 6 |
| 6.2 System Auditing | 48 | 47 | 1 |
| 6.3 Configure Integrity Checking | 3 | 3 | 0 |
| 7.1 Configure system file and directory access | 13 | 12 | 1 |
| 7.2 Local User and Group Settings | 10 | 10 | 0 |
| **Total** | **332** | **317** | **15** |

## The 15 Manual recommendations

| ID | Title |
|---|---|
| 1.1.1.11 | Ensure unused filesystems kernel modules are not available |
| 1.2.1.1 | Ensure the source.list and .source files use the Signed-By option |
| 1.2.2.1 | Ensure updates, patches, and additional security software are installed |
| 2.1.4 | Ensure only approved services are listening on a network interface |
| 3.1.1 | Ensure IPv6 status is identified |
| 5.3.3.2.3 | Ensure password complexity is configured |
| 5.4.1.2 | Ensure minimum password days is configured |
| 6.1.1.1.4 | Ensure journald log file access is configured |
| 6.1.1.1.5 | Ensure journald log file rotation is configured |
| 6.1.2.4 | Ensure rsyslog logging is configured |
| 6.1.2.5 | Ensure rsyslog is configured to send logs to a remote log host |
| 6.1.2.7 | Ensure logrotate is configured |
| 6.1.2.10 | Ensure rsyslog CA certificates are configured |
| 6.2.3.30 | Ensure the running and on disk configuration is the same |
| 7.1.13 | Ensure SUID and SGID files are reviewed |

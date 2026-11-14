# VERIFICATION.md — Audit script vs. CIS Ubuntu Linux 24.04 LTS Benchmark v2.0.0

- **Script:** `cis_ubuntu_24.04_lts_v2.0.0_audit.sh` (line numbers refer to the current file)
- **Benchmark:** CIS Ubuntu Linux 24.04 LTS Benchmark v2.0.0, dated 05-28-2026 (PDF)
- **Verified:** 2026-11-14. Logic changes A+B (approved) were applied on the same date.
- **Method:**
  1. The recommendation list was taken from the PDF table of contents (`pdftotext`) and cross-checked against
     the recommendation bodies, the *Appendix: Summary Table* and the *Appendix: Change History*.
  2. Control IDs, titles and assessment types were extracted from every `record` / `check_*` / `pkg*` call in the script.
  3. Each control's logic was compared by hand against the PDF **Audit:** section for that recommendation.

## 1. Headline results

| Check | Result |
|-------|--------|
| Recommendations in PDF (with a body/audit procedure) | **332** (317 Automated, 15 Manual) |
| Controls in script | **332** unique IDs |
| In PDF but missing from script | **none** |
| In script but not in PDF | **none** |
| Assessment type (Automated/Manual) mismatches | **none** |
| Title mismatches | **none** |
| Logic verdicts **before** fixes | 124 OK · 138 PARTIAL · 55 DIFFERS · 15 BUG |
| Logic verdicts **after** A+B fixes | **171 OK · 136 PARTIAL · 25 DIFFERS · 0 BUG** |

Verdict meanings:

- **OK:** equivalent to the PDF audit (the implementation may be simpler).
- **PARTIAL:** checks only part of what the PDF requires, so it can pass where the PDF would fail.
- **DIFFERS:** the pass/fail criteria differ from the PDF.
- **BUG:** gives the wrong result on common systems.

The 25 remaining DIFFERS controls are all in category C (not approved yet; see §8):

- 19 mount-option controls that report Fail instead of N/A when the partition is absent.
- 1.5.11 and 1.5.12, which report Fail instead of Pass when systemd-coredump is not installed.
- 5.3.3.2.1, 5.3.3.2.2, 5.3.3.2.4 and 5.3.3.2.5, which don't read `pwquality.conf.d`.

## 2. Controls in the PDF but missing from the script

None. All 332 recommendations that have a body in the PDF have a matching control ID.

## 3. Controls in the script but not in the PDF

None.

## 4. ID numbering gaps

The only gap in the whole benchmark is **1.5.10**: section 1.5 goes 1.5.1 … 1.5.9, 1.5.11, 1.5.12.

**This gap comes from the benchmark itself, not the script.** The PDF is internally inconsistent:

- The *Appendix: Summary Table* lists **1.5.10 "Ensure core file size is configured (Automated)"**.
- The *Appendix: Change History* says `2.0.0 ADDED RECOMMENDATION: 1.5.10 - Ensure core file size is configured`.
- However, the table of contents and the recommendation pages skip from 1.5.9 (p. 197) to 1.5.11 (p. 201).
  There is **no Description, Audit or Remediation for 1.5.10**.

Decision: the script omits 1.5.10 because there is no benchmark-authoritative audit logic to implement. Re-check if CIS
publishes an errata. The likely intent is `* hard core 0` in `/etc/security/limits.conf` / `limits.d`, as in other
CIS Linux benchmarks, but that is inference, not PDF text.

Note: the Markdown conversion of the benchmark (`Downloads/…v2.0.0.md`) shows only 314 headings because 18 wrap
across two lines. Use the PDF for counting.

## 5. "Automated" controls that did not produce an automated result

| ID | Title | Before | After |
|----|-------|--------|-------|
| 1.7.7 | Ensure Xwayland is configured | Always `Manual Review` | Pass/Fail on `WaylandEnable=false` in `[daemon]` |
| 5.4.2.5 | Ensure root path integrity | Always `Manual Review` | PDF script implemented |
| 7.2.9 | Ensure local interactive user home directories are configured | Always `Manual Review` | PDF script implemented |
| 7.2.10 | Ensure local interactive user dot files access is configured | Always `Manual Review` | PDF script implemented |
| 1.6.9 | Ensure access to pam_motd file is configured | Hard-coded `Pass` | Checks every `motd=` file in `/etc/pam.d` |
| 5.2.6 | Ensure sudo timestamp_timeout is configured | Hard-coded `Pass` | Configured value or `sudo -V` default, 0–15 |
| 5.4.2.4 | Ensure root account access is controlled | Always `Pass` | `passwd -S root` status P or L |

Every Automated control now produces Pass/Fail/N/A from collected evidence. 7.1.10 returns Pass when
`/etc/security/opasswd` is absent, which the PDF accepts ("Nothing is returned").

Some Manual controls suggest a Pass/Fail, which still needs human sign-off: 1.2.1.1, 1.2.2.1, 5.4.1.2.

## 6. Change log

### 6a. Non-logic fixes

| Change | Why |
|--------|-----|
| 1.7.1–1.7.7 Not-Applicable branch: titles changed from `"GDM control 1.7.x"` to the real PDF titles | Titles must be identical in every branch; downstream tools display them |
| 5.1.5: removed a dead `if … :` block | No-op code |

### 6b. Logic changes: A (outright bugs, 15 controls)

1.3.1.3, 1.3.1.4, 1.6.9, 1.7.7, 4.1.4, 5.1.24, 5.2.6, 5.2.7, 5.4.2.4, 5.4.2.5, 5.4.2.7, 6.1.2.6, 6.3.2, 7.2.9, 7.2.10.
The per-control notes in §9 (prefixed "FIXED (A)") describe the new logic.

### 6c. Logic changes: B (single-control rule differences, 33 controls)

1.2.1.2, 1.2.1.6, 1.3.1.2, 1.4.1, 1.4.2, 1.6.1, 1.6.4, 2.1.5, 2.1.19, 2.1.23, 2.2.4, 2.2.6, 2.4.1.9, 2.4.2.1,
4.1.2, 4.1.3, 4.1.5, 5.1.5, 5.1.7, 5.1.14, 5.1.17, 5.3.3.1.2, 5.3.3.2.6, 5.3.3.2.7, 5.4.2.6, 6.2.1.3, 6.2.1.4,
6.2.2.3, 6.2.2.4, 7.1.5, 7.1.6, 7.1.7, 7.1.8. The per-control notes in §9 are prefixed "FIXED (B)".

### 6d. Behaviour changes worth knowing (status will change on many hosts)

- **Stricter (more Fails), as the PDF requires:**
  - 1.4.1 now needs both superusers and a password.
  - 4.1.2 now needs enabled + active + status.
  - 4.1.4 now fails ufw's default `allow (outgoing)`.
  - 2.1.23 fails whenever `xserver-common` is installed.
  - 6.2.1.3 and 6.2.1.4 check the persisted `grub.cfg`, not the running cmdline.
  - 6.3.2 no longer accepts a cron job instead of `dailyaidecheck.timer`.
  - 1.6.1 flags stock `/etc/update-motd.d` scripts that mention "ubuntu".
- **Looser (fewer false Fails), as the PDF allows:**
  - 1.4.2 accepts 0600; 1.2.1.6 accepts 0640.
  - 2.4.1.9 and 2.4.2.1 accept 0640 and a compliant deny file.
  - 4.1.3, 4.1.5 and 5.1.14 accept reject / disabled / INFO.
  - 5.1.5 accepts any banner path; 5.1.7 accepts any value > 0; 5.1.17 accepts "or more restrictive".
  - 5.3.3.1.2 accepts 0; 5.3.3.2.6 and 5.3.3.2.7 accept the defaults.
  - 5.4.2.6 accepts no umask line; 5.4.2.7 excludes sync/shutdown/halt; 6.1.2.6 ignores comments.
  - 7.1.5–7.1.8 accept group root.
- **Evidence hygiene:** 1.4.1 now redacts GRUB PBKDF2 password hashes from the report evidence.

### 6e. Testing performed (no Ubuntu host available)

- `bash -n` and `--dry-run-safe` (bash syntax plus compilation of all 11 quoted Python blocks): pass.
- 49 fixture-based unit tests of the new parsing logic (aa-status counts, sshd `listenaddress`/`MaxStartups`,
  sudo timeout, pam_wheel, faillock, root-umask regex, rsyslog stock vs. active `imtcp`, GDM `custom.conf`,
  grub kernel lines, `apt-config` output, ufw defaults, banner leak detection, hash redaction): all pass.
- The new Python blocks (5.4.2.7, 7.2.9, 7.2.10) were run against fixture passwd/shells/home trees with stubbed `pwd`/`grp`: pass.
- **Not yet done:** a full run as root on Ubuntu 24.04, and shellcheck (not installed on the dev machine).

## 7. Former BUG list (all fixed)

| ID | Was |
|----|-----|
| 1.3.1.3 | Regex never matched aa-status output, so it always failed |
| 1.3.1.4 | Checked `/proc/cmdline`; the PDF defines a sysctl. It always failed |
| 1.6.9 | Hard-coded Pass |
| 1.7.7 | Automated control that always returned Manual Review |
| 4.1.4 | Inverted: passed on `allow (outgoing)` |
| 5.1.24 | `0.0.0.0:22` was never matched, giving a false Pass |
| 5.2.6 | Hard-coded Pass |
| 5.2.7 | Matched commented-out `pam_wheel` lines, giving a false Pass |
| 5.4.2.4 | Always Pass |
| 5.4.2.5 | Automated control that always returned Manual Review |
| 5.4.2.7 | `sync`'s `/bin/sync` shell made it always fail |
| 6.1.2.6 | Matched commented-out `#module(load="imtcp")`, so it always failed |
| 6.3.2 | Wrong timer name (`aidecheck.timer`) |
| 7.2.9 | Automated control that always returned Manual Review |
| 7.2.10 | Automated control that always returned Manual Review |

## 8. Outstanding systemic differences (category C, not applied)

| Pattern | Controls | Difference |
|---------|----------|-----------|
| Kernel modules | 1.1.1.1–1.1.1.10, 3.2.1–3.2.6 | The PDF needs `blacklist X` **and** `install X /bin/false`; the script accepts either |
| sysctl persistence | 1.3.1.4, 1.5.1–1.5.5, 1.5.8, 1.5.9, 3.3.1.1–3.3.2.8 | Only the running value is gated. The PDF also requires it to be persisted in a `systemd-sysctl` file |
| auditd rules | 6.2.3.1–6.2.3.28 | The PDF requires each rule both loaded **and** on disk; the script accepts either |
| Mount options when there is no partition | 19 controls in 1.1.2.x.2–4 | The PDF says "IF a separate partition exists"; the script reports Fail instead of N/A |
| Conditional controls | 2.4.1.x (cron), 2.4.2.1 (at), 3.3.2.x (IPv6), 1.5.11/1.5.12 (systemd-coredump) | The PDF treats these as N/A or Pass when the component is absent |
| pwquality drop-ins | 5.3.3.2.1, 5.3.3.2.2, 5.3.3.2.4, 5.3.3.2.5, 5.3.3.2.8 | `pwquality.conf.d/*.conf` is ignored (and maxrepeat/maxsequence 0 passes) |
| Per-user shadow fields | 5.4.1.1, 5.4.1.2, 5.4.1.3, 5.4.1.5 | The PDF also checks every user's `/etc/shadow` fields |
| GNOME settings locks | 1.7.1–1.7.5 | The PDF requires settings to be *locked* (`gsettings writable … = false`) |

Other PARTIAL items are listed individually in §9.

## 9. Full per-control table

| ID | Title (PDF) | Assessment | Script line | Verdict | Notes |
|----|-------------|------------|-------------|---------|-------|
| 1.1.1.1 | Ensure cramfs kernel module is not available | Automated | 469 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 1.1.1.2 | Ensure freevxfs kernel module is not available | Automated | 471 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 1.1.1.3 | Ensure hfs kernel module is not available | Automated | 472 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 1.1.1.4 | Ensure hfsplus kernel module is not available | Automated | 473 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 1.1.1.5 | Ensure jffs2 kernel module is not available | Automated | 474 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 1.1.1.6 | Ensure overlay kernel module is not available | Automated | 475 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 1.1.1.7 | Ensure squashfs kernel module is not available | Automated | 476 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 1.1.1.8 | Ensure udf kernel module is not available | Automated | 477 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 1.1.1.9 | Ensure firewire-core kernel module is not available | Automated | 478 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 1.1.1.10 | Ensure usb-storage kernel module is not available | Automated | 479 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 1.1.1.11 | Ensure unused filesystems kernel modules are not available | Manual | 482 | OK | Manual; evidence lists fs modules. PDF also lists mounted fs types (`findmnt -Dkerno fstype`). |
| 1.1.2.1.1 | Ensure /tmp is tmpfs or a separate partition | Automated | 484 | OK | findmnt plus tmp.mount state in evidence. |
| 1.1.2.1.2 | Ensure nodev option set on /tmp partition | Automated | 486 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.1.3 | Ensure nosuid option set on /tmp partition | Automated | 487 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.1.4 | Ensure noexec option set on /tmp partition | Automated | 488 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.2.1 | Ensure /dev/shm is tmpfs or a separate partition | Automated | 489 | OK | findmnt /dev/shm. |
| 1.1.2.2.2 | Ensure nodev option set on /dev/shm partition | Automated | 490 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.2.3 | Ensure nosuid option set on /dev/shm partition | Automated | 491 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.2.4 | Ensure noexec option set on /dev/shm partition | Automated | 492 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.3.1 | Ensure separate partition exists for /home | Automated | 493 | OK | findmnt for separate partition. |
| 1.1.2.3.2 | Ensure nodev option set on /home partition | Automated | 494 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.3.3 | Ensure nosuid option set on /home partition | Automated | 495 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.4.1 | Ensure separate partition exists for /var | Automated | 496 | OK | findmnt for separate partition. |
| 1.1.2.4.2 | Ensure nodev option set on /var partition | Automated | 497 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.4.3 | Ensure nosuid option set on /var partition | Automated | 498 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.5.1 | Ensure separate partition exists for /var/tmp | Automated | 499 | OK | findmnt for separate partition. |
| 1.1.2.5.2 | Ensure nodev option set on /var/tmp partition | Automated | 500 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.5.3 | Ensure nosuid option set on /var/tmp partition | Automated | 501 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.5.4 | Ensure noexec option set on /var/tmp partition | Automated | 502 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.6.1 | Ensure separate partition exists for /var/log | Automated | 503 | OK | findmnt for separate partition. |
| 1.1.2.6.2 | Ensure nodev option set on /var/log partition | Automated | 504 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.6.3 | Ensure nosuid option set on /var/log partition | Automated | 505 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.6.4 | Ensure noexec option set on /var/log partition | Automated | 506 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.7.1 | Ensure separate partition exists for /var/log/audit | Automated | 507 | OK | findmnt for separate partition. |
| 1.1.2.7.2 | Ensure nodev option set on /var/log/audit partition | Automated | 508 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.7.3 | Ensure nosuid option set on /var/log/audit partition | Automated | 509 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.1.2.7.4 | Ensure noexec option set on /var/log/audit partition | Automated | 510 | DIFFERS | PDF: '- IF - a separate partition exists'. Script reports Fail when the mount is absent (double-penalises the missing partition already failed by the x.1 control) instead of Not Applicable. |
| 1.2.1.1 | Ensure the source.list and .source files use the Signed-By option | Manual | 523 | PARTIAL | Manual. Ignores /etc/apt/sources.list itself; returns Manual Review if no Signed-By anywhere. |
| 1.2.1.2 | Ensure weak dependencies are configured | Automated | 532 | OK | FIXED (B): `apt-config dump` must show Install-Recommends AND Install-Suggests "0" ("false" accepted as apt's equivalent). |
| 1.2.1.3 | Ensure access to gpg key files are configured | Automated | 540 | PARTIAL | Mode checked; PDF also requires owner root and group root (and sources files with Signed-By). |
| 1.2.1.4 | Ensure access to /etc/apt/trusted.gpg.d directory is configured | Automated | 541 | OK |  |
| 1.2.1.5 | Ensure access to /etc/apt/auth.conf.d directory is configured | Automated | 543 | OK |  |
| 1.2.1.6 | Ensure access to files in the /etc/apt/auth.conf.d/ directory is configured | Automated | 551 | OK | FIXED (B): files 0640 or stricter, owner root, group root. |
| 1.2.1.7 | Ensure access to /usr/share/keyrings directory is configured | Automated | 552 | OK |  |
| 1.2.1.8 | Ensure access to /etc/apt/sources.list.d directory is configured | Automated | 553 | OK |  |
| 1.2.1.9 | Ensure access to files in /etc/apt/sources.list.d are configured | Automated | 559 | PARTIAL | Mode checked; owner/group root:root not checked. |
| 1.2.2.1 | Ensure updates, patches, and additional security software are installed | Manual | 563 | PARTIAL | Manual. Does not check /var/run/reboot-required. |
| 1.3.1.1 | Ensure apparmor packages are installed | Automated | 566 | OK |  |
| 1.3.1.2 | Ensure AppArmor is enabled | Automated | 574 | OK | FIXED (B): no grub.cfg linux line may contain apparmor=0 (Fail if no grub.cfg found). |
| 1.3.1.3 | Ensure all AppArmor Profiles are enforcing | Automated | 583 | OK | FIXED (A): parses aa-status counts; Pass when profiles loaded > 0, 0 in complain mode, 0 unconfined processes with a profile. |
| 1.3.1.4 | Ensure apparmor_restrict_unprivileged_unconfined is enabled | Automated | 585 | PARTIAL | FIXED (A): now a sysctl check (kernel.apparmor_restrict_unprivileged_unconfined = 1). Remaining gap: Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 1.4.1 | Ensure bootloader password is set | Automated | 592 | OK | FIXED (B): grub.cfg must contain both `set superusers` and `password_pbkdf2`. Password hashes are now redacted in evidence. |
| 1.4.2 | Ensure access to bootloader config is configured | Automated | 594 | OK | FIXED (B): 0600 or more restrictive, root:root. |
| 1.5.1 | Ensure fs.protected_hardlinks is configured | Automated | 600 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 1.5.2 | Ensure fs.protected_symlinks is configured | Automated | 601 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 1.5.3 | Ensure kernel.yama.ptrace_scope is configured | Automated | 605 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 1.5.4 | Ensure fs.suid_dumpable is configured | Automated | 606 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 1.5.5 | Ensure kernel.dmesg_restrict is configured | Automated | 607 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 1.5.6 | Ensure prelink is not installed | Automated | 608 | OK |  |
| 1.5.7 | Ensure Automatic Error Reporting is configured | Automated | 611 | PARTIAL | PDF also requires apport.service not active. |
| 1.5.8 | Ensure kernel.kptr_restrict is configured | Automated | 612 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 1.5.9 | Ensure kernel.randomize_va_space is configured | Automated | 613 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 1.5.11 | Ensure systemd-coredump ProcessSizeMax is configured | Automated | 617 | DIFFERS | PDF: Pass if systemd-coredump not installed; uses systemd-analyze cat-config precedence. Script Fails when unset/not installed. |
| 1.5.12 | Ensure systemd-coredump Storage is configured | Automated | 619 | DIFFERS | As 1.5.11 (Storage=none). |
| 1.6.1 | Ensure /etc/motd is configured | Automated | 633 | OK | FIXED (B): OS-info leak check (case-insensitive OS ID, \v \r \m \s) across /etc/motd, /run/motd, /usr/lib/motd, motd.d dirs and /etc/update-motd.d; missing /etc/motd is compliant. |
| 1.6.2 | Ensure /etc/issue is configured | Automated |  | PARTIAL | Only /etc/issue; PDF also /etc/issue.d, /run/issue.d, /usr/lib/issue.d; OS-ID match is case-sensitive. |
| 1.6.3 | Ensure /etc/issue.net is configured | Automated |  | PARTIAL | OS-ID match is case-sensitive. |
| 1.6.4 | Ensure pam_motd is configured | Automated | 666 | OK | FIXED (B): PDF script implemented: motd= files on pam_motd session lines (sshd/login/su/gdm-password) must not disclose OS information. |
| 1.6.5 | Ensure sshd warning Banner is configured | Automated | 670 | PARTIAL | Checks Banner is set; PDF also requires the banner file to contain no OS info. |
| 1.6.6 | Ensure access to /etc/motd is configured | Automated | 671 | PARTIAL | Only /etc/motd; PDF covers motd.d / update-motd.d files too. Missing file → N/A (PDF: Pass). |
| 1.6.7 | Ensure access to /etc/issue is configured | Automated | 672 | OK |  |
| 1.6.8 | Ensure access to /etc/issue.net is configured | Automated | 673 | OK |  |
| 1.6.9 | Ensure access to pam_motd file is configured | Automated | 682 | OK | FIXED (A): every motd= file referenced in /etc/pam.d must be 0644 or stricter, root:root. |
| 1.6.10 | Ensure access to sshd warning banner is configured | Automated | 685 | OK |  |
| 1.7.1 | Ensure GDM login banner is configured | Automated | 694 | PARTIAL | Greps /etc/dconf/db for the value; PDF requires the setting to be LOCKED (`gsettings writable` = false) and checks values via gsettings. |
| 1.7.2 | Ensure GDM disable-user-list is configured | Automated | 696 | PARTIAL | Greps /etc/dconf/db for the value; PDF requires the setting to be LOCKED (`gsettings writable` = false) and checks values via gsettings. |
| 1.7.3 | Ensure GDM screen lock is configured | Automated | 698 | PARTIAL | Checks idle-delay exists + lock-enabled; PDF requires idle-delay 1..900, lock-delay ≤ 5, both locked. |
| 1.7.4 | Ensure GDM automount is configured | Automated | 700 | PARTIAL | Greps /etc/dconf/db for the value; PDF requires the setting to be LOCKED (`gsettings writable` = false) and checks values via gsettings. |
| 1.7.5 | Ensure GDM autorun-never is configured | Automated | 702 | PARTIAL | Greps /etc/dconf/db for the value; PDF requires the setting to be LOCKED (`gsettings writable` = false) and checks values via gsettings. |
| 1.7.6 | Ensure XDMCP is not enabled | Automated | 705 | PARTIAL | Greps Enable=true anywhere in custom.conf; PDF restricts to the [xdmcp] block and also checks daemon.conf. |
| 1.7.7 | Ensure Xwayland is configured | Automated | 713 | OK | FIXED (A): WaylandEnable=false in [daemon] of /etc/gdm3/custom.conf (or /etc/gdm/custom.conf as in the PDF). |
| 2.1.1 | Ensure autofs services are not in use | Automated | 732 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.2 | Ensure mail transfer agents are configured for local-only mode | Automated | 737 | PARTIAL | PDF checks no MTA listens on non-loopback ports 25/465/587; script uses postconf or a loose `:25` match (also matches :2525 etc.). |
| 2.1.3 | Ensure avahi daemon services are not in use | Automated | 738 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.4 | Ensure only approved services are listening on a network interface | Manual | 740 | OK | Manual; evidence only. |
| 2.1.5 | Ensure dhcp server services are not in use | Automated | 743 | OK | FIXED (B): any installed *kea* package; units kea-dhcp4-server, kea-dhcp6-server, kea-dhcp-ddns-server (isc-dhcp-server kept, stricter). |
| 2.1.6 | Ensure web server services are not in use | Automated | 744 | PARTIAL | Missing apache2.socket. (lighttpd is extra, stricter.) |
| 2.1.7 | Ensure dns server services are not in use | Automated | 745 | OK | Checks package installed / unit enabled\|active as in the PDF. (unbound extra, stricter) |
| 2.1.8 | Ensure ftp server services are not in use | Automated | 746 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.9 | Ensure dnsmasq services are not in use | Automated | 747 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.10 | Ensure ldap server services are not in use | Automated | 748 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.11 | Ensure message access server services are not in use | Automated | 749 | PARTIAL | Missing dovecot.socket. |
| 2.1.12 | Ensure network file system services are not in use | Automated | 750 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.13 | Ensure nis server services are not in use | Automated | 751 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.14 | Ensure print server services are not in use | Automated | 752 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.15 | Ensure rpcbind services are not in use | Automated | 753 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.16 | Ensure rsync services are not in use | Automated | 754 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.17 | Ensure samba file server services are not in use | Automated | 755 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.18 | Ensure snmp services are not in use | Automated | 756 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.19 | Ensure telnet server services are not in use | Automated | 757 | OK | FIXED (B): packages telnetd, telnetd-ssl (inetutils-telnetd kept); unit inetutils-inetd.service added. |
| 2.1.20 | Ensure tftp server services are not in use | Automated | 758 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.21 | Ensure web proxy server services are not in use | Automated | 759 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.22 | Ensure xinetd services are not in use | Automated | 760 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 2.1.23 | Ensure X window server services are not in use | Automated | 762 | OK | FIXED (B): Fail if xserver-common is installed (PDF scope: GUI not required by site policy). |
| 2.2.1 | Ensure nis client is not installed | Automated | 765 | OK |  |
| 2.2.2 | Ensure rsh client is not installed | Automated | 766 | OK |  |
| 2.2.3 | Ensure talk client is not installed | Automated | 767 | OK |  |
| 2.2.4 | Ensure telnet client is not installed | Automated | 768 | OK | FIXED (B): telnet and inetutils-telnet. |
| 2.2.5 | Ensure ldap client is not installed | Automated | 769 | OK |  |
| 2.2.6 | Ensure ftp client is not installed | Automated | 770 | OK | FIXED (B): ftp and tnftp. |
| 2.3.1.1 | Ensure a single time synchronization daemon is in use | Automated | 778 | OK | Exactly one of timesyncd/chrony active. |
| 2.3.2.1 | Ensure systemd-timesyncd configured with authorized timeserver | Automated | 782 | PARTIAL | PDF accepts NTP and/or FallbackNTP; script only NTP=. |
| 2.3.2.2 | Ensure systemd-timesyncd is enabled and running | Automated | 784 | OK |  |
| 2.3.3.1 | Ensure chrony is configured | Automated | 787 | OK |  |
| 2.3.3.2 | Ensure chrony is running as user _chrony | Automated | 788 | OK |  |
| 2.3.3.3 | Ensure chrony is enabled and running | Automated | 789 | OK |  |
| 2.4.1.1 | Ensure cron daemon is enabled and active | Automated | 803 | OK |  |
| 2.4.1.2 | Ensure access to /etc/crontab is configured | Automated | 804 | OK | PDF: '- IF - cron is installed' (script does not return N/A when cron absent). |
| 2.4.1.3 | Ensure access to /etc/cron.hourly is configured | Automated | 805 | OK | PDF: '- IF - cron is installed' (script does not return N/A when cron absent). |
| 2.4.1.4 | Ensure access to /etc/cron.daily is configured | Automated | 806 | OK | PDF: '- IF - cron is installed' (script does not return N/A when cron absent). |
| 2.4.1.5 | Ensure access to /etc/cron.weekly is configured | Automated | 807 | OK | PDF: '- IF - cron is installed' (script does not return N/A when cron absent). |
| 2.4.1.6 | Ensure access to /etc/cron.monthly is configured | Automated | 808 | OK | PDF: '- IF - cron is installed' (script does not return N/A when cron absent). |
| 2.4.1.7 | Ensure access to /etc/cron.yearly is configured | Automated | 810 | OK | PDF: '- IF - cron is installed' (script does not return N/A when cron absent). |
| 2.4.1.8 | Ensure access to /etc/cron.d is configured | Automated | 814 | OK | PDF: '- IF - cron is installed' (script does not return N/A when cron absent). |
| 2.4.1.9 | Ensure access to crontab is configured | Automated | 820 | OK | FIXED (B): cron.allow 0640, root, group root\|crontab; cron.deny absent or the same. (Still Fail rather than N/A when cron is absent — category C.) |
| 2.4.2.1 | Ensure access to at is configured | Automated | 826 | OK | FIXED (B): at.allow 0640, root, group daemon\|root; at.deny absent or the same. (Still Fail rather than N/A when at is absent — category C.) |
| 3.1.1 | Ensure IPv6 status is identified | Manual | 833 | OK | Manual; evidence only. |
| 3.1.2 | Ensure wireless interfaces are not available | Automated | 836 | PARTIAL | PDF checks wireless driver modules are not loadable; script greps `ip link` for wlan/wifi names. |
| 3.1.3 | Ensure bluetooth services are not in use | Automated | 837 | OK | Checks package installed / unit enabled\|active as in the PDF. |
| 3.2.1 | Ensure atm kernel module is not available | Automated | 840 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 3.2.2 | Ensure can kernel module is not available | Automated | 841 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 3.2.3 | Ensure dccp kernel module is not available | Automated | 842 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 3.2.4 | Ensure rds kernel module is not available | Automated | 843 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 3.2.5 | Ensure sctp kernel module is not available | Automated | 844 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 3.2.6 | Ensure tipc kernel module is not available | Automated | 845 | PARTIAL | PDF requires `blacklist <mod>` AND `install <mod> /bin/false\|/bin/true`; script passes on either one. |
| 3.3.1.1 | Ensure net.ipv4.ip_forward is configured | Automated | 848 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.2 | Ensure net.ipv4.conf.all.forwarding is configured | Automated | 849 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.3 | Ensure net.ipv4.conf.default.forwarding is configured | Automated | 850 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.4 | Ensure net.ipv4.conf.all.send_redirects is configured | Automated | 851 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.5 | Ensure net.ipv4.conf.default.send_redirects is configured | Automated | 852 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.6 | Ensure net.ipv4.icmp_ignore_bogus_error_responses is configured | Automated | 853 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.7 | Ensure net.ipv4.icmp_echo_ignore_broadcasts is configured | Automated | 854 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.8 | Ensure net.ipv4.conf.all.accept_redirects is configured | Automated | 855 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.9 | Ensure net.ipv4.conf.default.accept_redirects is configured | Automated | 856 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.10 | Ensure net.ipv4.conf.all.secure_redirects is configured | Automated | 857 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.11 | Ensure net.ipv4.conf.default.secure_redirects is configured | Automated | 858 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.12 | Ensure net.ipv4.conf.all.rp_filter is configured | Automated | 859 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.13 | Ensure net.ipv4.conf.default.rp_filter is configured | Automated | 860 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.14 | Ensure net.ipv4.conf.all.accept_source_route is configured | Automated | 861 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.15 | Ensure net.ipv4.conf.default.accept_source_route is configured | Automated | 862 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.16 | Ensure net.ipv4.conf.all.log_martians is configured | Automated | 863 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.17 | Ensure net.ipv4.conf.default.log_martians is configured | Automated | 864 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.1.18 | Ensure net.ipv4.tcp_syncookies is configured | Automated | 865 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). |
| 3.3.2.1 | Ensure net.ipv6.conf.all.forwarding is configured | Automated | 866 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). PDF: '- IF - IPv6 is enabled' (script Fails instead of N/A when IPv6 is disabled). |
| 3.3.2.2 | Ensure net.ipv6.conf.default.forwarding is configured | Automated | 867 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). PDF: '- IF - IPv6 is enabled' (script Fails instead of N/A when IPv6 is disabled). |
| 3.3.2.3 | Ensure net.ipv6.conf.all.accept_redirects is configured | Automated | 868 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). PDF: '- IF - IPv6 is enabled' (script Fails instead of N/A when IPv6 is disabled). |
| 3.3.2.4 | Ensure net.ipv6.conf.default.accept_redirects is configured | Automated | 869 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). PDF: '- IF - IPv6 is enabled' (script Fails instead of N/A when IPv6 is disabled). |
| 3.3.2.5 | Ensure net.ipv6.conf.all.accept_source_route is configured | Automated | 870 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). PDF: '- IF - IPv6 is enabled' (script Fails instead of N/A when IPv6 is disabled). |
| 3.3.2.6 | Ensure net.ipv6.conf.default.accept_source_route is configured | Automated | 871 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). PDF: '- IF - IPv6 is enabled' (script Fails instead of N/A when IPv6 is disabled). |
| 3.3.2.7 | Ensure net.ipv6.conf.all.accept_ra is configured | Automated | 872 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). PDF: '- IF - IPv6 is enabled' (script Fails instead of N/A when IPv6 is disabled). |
| 3.3.2.8 | Ensure net.ipv6.conf.default.accept_ra is configured | Automated | 873 | PARTIAL | Checks running value only; PDF also requires the value to be persisted in a file loaded by systemd-sysctl (running value is shown, config lines are evidence only). PDF: '- IF - IPv6 is enabled' (script Fails instead of N/A when IPv6 is disabled). |
| 4.1.1 | Ensure ufw is installed | Automated | 879 | OK |  |
| 4.1.2 | Ensure ufw service is configured | Automated | 885 | OK | FIXED (B): ufw.service enabled AND active AND `ufw status` active. |
| 4.1.3 | Ensure ufw incoming default is configured | Automated | 889 | OK | FIXED (B): incoming deny or reject. |
| 4.1.4 | Ensure ufw outgoing default is configured | Automated | 891 | OK | FIXED (A): outgoing default must be deny or reject. |
| 4.1.5 | Ensure ufw routed default is configured | Automated | 893 | OK | FIXED (B): routed disabled or deny. |
| 5.1.1 | Ensure access to /etc/ssh/sshd_config is configured | Automated | 899 | PARTIAL | PDF also checks /etc/ssh/sshd_config.d/*.conf (0600, root:root). |
| 5.1.2 | Ensure access to SSH private host key files is configured | Automated | 907 | PARTIAL | Uses ssh_host_*_key glob; PDF uses sshd -T hostkey list. Owner/group checked. |
| 5.1.3 | Ensure access to SSH public host key files is configured | Automated | 913 | PARTIAL | Owner/group root:root not checked. |
| 5.1.4 | Ensure sshd access is configured | Automated | 916 | OK |  |
| 5.1.5 | Ensure sshd Banner is configured | Automated | 928 | OK | FIXED (B): Banner is any absolute path whose file does not disclose OS information. |
| 5.1.6 | Ensure sshd Ciphers are configured | Automated | 931 | PARTIAL | Weak-cipher list missing rijndael-cbc@lysator.liu.se. |
| 5.1.7 | Ensure sshd ClientAliveInterval and ClientAliveCountMax are configured | Automated | 936 | OK | FIXED (B): both values > 0. |
| 5.1.8 | Ensure sshd DisableForwarding is enabled | Automated | 937 | OK |  |
| 5.1.9 | Ensure sshd GSSAPIAuthentication is disabled | Automated | 938 | OK |  |
| 5.1.10 | Ensure sshd HostbasedAuthentication is disabled | Automated | 939 | OK |  |
| 5.1.11 | Ensure sshd IgnoreRhosts is enabled | Automated | 940 | OK |  |
| 5.1.12 | Ensure sshd KexAlgorithms is configured | Automated | 943 | OK |  |
| 5.1.13 | Ensure sshd LoginGraceTime is configured | Automated | 947 | OK |  |
| 5.1.14 | Ensure sshd LogLevel is configured | Automated | 952 | OK | FIXED (B): VERBOSE or INFO. |
| 5.1.15 | Ensure sshd MACs are configured | Automated | 955 | PARTIAL | Weak-MAC list incomplete: missing hmac-ripemd160*, umac-64-etm@openssh.com, umac-128-etm@openssh.com. |
| 5.1.16 | Ensure sshd MaxAuthTries is configured | Automated | 959 | OK |  |
| 5.1.17 | Ensure sshd MaxStartups is configured | Automated | 964 | OK | FIXED (B): 10:30:60 or more restrictive. |
| 5.1.18 | Ensure sshd MaxSessions is configured | Automated | 968 | OK |  |
| 5.1.19 | Ensure sshd PermitEmptyPasswords is disabled | Automated | 969 | OK |  |
| 5.1.20 | Ensure sshd PermitRootLogin is disabled | Automated | 970 | OK |  |
| 5.1.21 | Ensure sshd PermitUserEnvironment is disabled | Automated | 971 | OK |  |
| 5.1.22 | Ensure sshd UsePAM is enabled | Automated | 972 | OK |  |
| 5.1.23 | Ensure sshd post-quantum cryptography key exchange algorithms are configured | Automated | 975 | PARTIAL | PDF also requires mlkem768x25519-sha256 when OpenSSH ≥ 9.9 (Ubuntu 24.04 ships 9.6). |
| 5.1.24 | Ensure sshd ListenAddress is configured | Automated | 987 | OK | FIXED (A): port stripped from every listenaddress; Fail if unset or any wildcard (0.0.0.0, [::], ::, *). |
| 5.2.1 | Ensure sudo is installed | Automated | 990 | OK |  |
| 5.2.2 | Ensure sudo commands use pty | Automated | 993 | PARTIAL | Does not check that `Defaults !use_pty` is absent. |
| 5.2.3 | Ensure sudo log file exists | Automated | 996 | OK |  |
| 5.2.4 | Ensure users must provide password for escalation | Automated | 999 | OK |  |
| 5.2.5 | Ensure re-authentication for privilege escalation is not disabled globally | Automated | 1001 | OK |  |
| 5.2.6 | Ensure sudo timestamp_timeout is configured | Automated | 1014 | OK | FIXED (A): configured timestamp_timeout values (or sudo -V default) must be 0-15; negative fails. |
| 5.2.7 | Ensure access to the su command is restricted | Automated | 1026 | OK | FIXED (A): requires active `auth required\|requisite pam_wheel.so use_uid group=<g>`; <g> must exist with no members; comments ignored. |
| 5.3.1.1 | Ensure latest version of pam is installed | Automated | 1029 | PARTIAL | Checks installed; PDF also requires the package to be the latest version (apt list --upgradable). |
| 5.3.1.2 | Ensure latest version of libpam-modules is installed | Automated | 1030 | PARTIAL | Checks installed; PDF also requires the package to be the latest version (apt list --upgradable). |
| 5.3.1.3 | Ensure latest version of libpam-pwquality is installed | Automated | 1031 | PARTIAL | Checks installed; PDF also requires the package to be the latest version (apt list --upgradable). |
| 5.3.1.4 | Ensure latest version of cracklib-runtime is installed | Automated | 1032 | PARTIAL | Checks installed; PDF also requires the package to be the latest version (apt list --upgradable). |
| 5.3.2.1 | Ensure pam_unix module is enabled | Automated | 1035 | PARTIAL | Checks common-password only; PDF expects pam_unix in common-account/auth/password/session. |
| 5.3.2.2 | Ensure pam_faillock module is enabled | Automated | 1038 | PARTIAL | Any pam_faillock mention in common-auth; PDF expects preauth + authfail in common-auth and an account line. |
| 5.3.2.3 | Ensure pam_pwquality module is enabled | Automated | 1041 | OK |  |
| 5.3.2.4 | Ensure pam_pwhistory module is enabled | Automated | 1044 | OK |  |
| 5.3.3.1.1 | Ensure password failed attempts lockout is configured | Automated | 1050 | PARTIAL | deny=0 passes (PDF 1-5); `deny=5` without spaces breaks the parse; pam_faillock deny= override in common-auth not checked. |
| 5.3.3.1.2 | Ensure password unlock time is configured | Automated | 1056 | OK | FIXED (B): unlock_time 0 or >= 900 in faillock.conf and no 1-899 override on pam_faillock in common-auth. |
| 5.3.3.1.3 | Ensure password failed attempts lockout includes root account | Automated | 1058 | PARTIAL | PDF also requires root_unlock_time ≥ 60 if set. |
| 5.3.3.2.1 | Ensure password number of changed characters is configured | Automated | 1063 | DIFFERS | Reads only pwquality.conf; PDF reads pwquality.conf.d/*.conf (its own examples use conf.d) and checks module-argument overrides. |
| 5.3.3.2.2 | Ensure password length is configured | Automated | 1066 | DIFFERS | As 5.3.3.2.1 (minlen). |
| 5.3.3.2.3 | Ensure password complexity is configured | Manual | 1067 | OK | Manual; evidence only. |
| 5.3.3.2.4 | Ensure password same consecutive characters is configured | Automated | 1070 | DIFFERS | conf.d not read; maxrepeat=0 passes (PDF: 1-3, not 0). |
| 5.3.3.2.5 | Ensure password maximum sequential characters is configured | Automated | 1073 | DIFFERS | conf.d not read; maxsequence=0 passes (PDF: 1-3, not 0). |
| 5.3.3.2.6 | Ensure password dictionary check is enabled | Automated | 1079 | OK | FIXED (B): Fail only if dictcheck=0 in pwquality.conf, pwquality.conf.d/*.conf or common-password. |
| 5.3.3.2.7 | Ensure password quality checking is enforced | Automated | 1084 | OK | FIXED (B): Fail only if enforcing=0 in pwquality.conf, pwquality.conf.d/*.conf or common-password. |
| 5.3.3.2.8 | Ensure password quality is enforced for the root user | Automated | 1086 | PARTIAL | conf.d not read. |
| 5.3.3.3.1 | Ensure password history remember is configured | Automated | 1091 | OK |  |
| 5.3.3.3.2 | Ensure password history is enforced for the root user | Automated | 1093 | OK |  |
| 5.3.3.3.3 | Ensure pam_pwhistory includes use_authtok | Automated | 1095 | OK |  |
| 5.3.3.4.1 | Ensure pam_unix does not include nullok | Automated | 1098 | PARTIAL | Commented lines not excluded; PDF also checks common-account/session files. |
| 5.3.3.4.2 | Ensure pam_unix does not include remember | Automated | 1100 | PARTIAL | As 5.3.3.4.1. |
| 5.3.3.4.3 | Ensure pam_unix includes a strong password hashing algorithm | Automated | 1102 | PARTIAL | Matches yescrypt/sha512 anywhere in pam_unix lines of common-auth too; PDF: password lines in common-password. |
| 5.3.3.4.4 | Ensure pam_unix includes use_authtok | Automated | 1104 | OK |  |
| 5.4.1.1 | Ensure password expiration is configured | Automated | 1111 | PARTIAL | login.defs only; PDF also checks every user's /etc/shadow max-days field (1..365). |
| 5.4.1.2 | Ensure minimum password days is configured | Manual | 1113 | PARTIAL | Manual. login.defs only; PDF also checks every user's min-days. |
| 5.4.1.3 | Ensure password expiration warning days is configured | Automated | 1116 | PARTIAL | login.defs only; PDF also checks every user's warn-days. |
| 5.4.1.4 | Ensure strong password hashing algorithm is configured | Automated | 1119 | OK |  |
| 5.4.1.5 | Ensure inactive password lock is configured | Automated | 1122 | PARTIAL | useradd default only; PDF also checks every user's inactive field. |
| 5.4.1.6 | Ensure all users last password change date is in the past | Automated | 1137 | OK |  |
| 5.4.2.1 | Ensure root is the only UID 0 account | Automated | 1141 | OK |  |
| 5.4.2.2 | Ensure root is the only GID 0 account | Automated | 1144 | PARTIAL | Does not exclude sync/shutdown/halt/operator as the PDF does. |
| 5.4.2.3 | Ensure group root is the only GID 0 group | Automated | 1147 | OK |  |
| 5.4.2.4 | Ensure root account access is controlled | Automated | 1152 | OK | FIXED (A): `passwd -S root` status must be P or L. |
| 5.4.2.5 | Ensure root path integrity | Automated | 1174 | OK | FIXED (A): PDF script implemented (root PATH from `su - root -c env`): no ::, trailing :, '.', non-directories, non-root owners, or group/other-writable entries. |
| 5.4.2.6 | Ensure root user umask is configured | Automated | 1180 | OK | FIXED (B): PDF regex: /root/.profile and /root/.bashrc must not set a umask looser than 027; no umask line is compliant. |
| 5.4.2.7 | Ensure system accounts do not have a valid login shell | Automated | 1214 | OK | FIXED (A): PDF logic: UID < UID_MIN or 65534, excluding root/halt/sync/shutdown/nfsnobody, with a shell from /etc/shells (not nologin). |
| 5.4.2.8 | Ensure accounts without a valid login shell are locked | Automated | 1221 | OK |  |
| 5.4.3.1 | Ensure nologin is not listed in /etc/shells | Automated | 1224 | OK |  |
| 5.4.3.2 | Ensure default user shell timeout is configured | Automated | 1227 | PARTIAL | Checks TMOUT ≤ 900 exists; PDF also requires readonly + export and no conflicting longer value. |
| 5.4.3.3 | Ensure default user umask is configured | Automated | 1230 | OK |  |
| 6.1.1.1.1 | Ensure journald service is active | Automated | 1238 | OK |  |
| 6.1.1.1.2 | Ensure systemd-journal-remote service is not in use | Automated | 1242 | PARTIAL | is-enabled `static`/`indirect` → Fail; PDF checks not enabled AND not active. |
| 6.1.1.1.3 | Ensure journald is configured to send logs to rsyslog | Automated | 1245 | PARTIAL | Greps files; PDF uses systemd-analyze cat-config precedence and is conditional on rsyslog being preferred. |
| 6.1.1.1.4 | Ensure journald log file access is configured | Manual | 1247 | OK | Manual; evidence only. |
| 6.1.1.1.5 | Ensure journald log file rotation is configured | Manual | 1249 | OK | Manual; evidence only. |
| 6.1.1.1.6 | Ensure journald Storage is configured | Automated | 1252 | PARTIAL | File grep instead of systemd-analyze cat-config precedence. |
| 6.1.1.1.7 | Ensure journald Compress is configured | Automated | 1255 | PARTIAL | As 6.1.1.1.6. |
| 6.1.2.1 | Ensure rsyslog is installed | Automated | 1256 | OK |  |
| 6.1.2.2 | Ensure rsyslog service is enabled and active | Automated | 1259 | PARTIAL | Checks active only; PDF requires enabled AND active. |
| 6.1.2.3 | Ensure rsyslog log file creation mode is configured | Automated | 1262 | OK |  |
| 6.1.2.4 | Ensure rsyslog logging is configured | Manual | 1264 | OK | Manual; evidence only. |
| 6.1.2.5 | Ensure rsyslog is configured to send logs to a remote log host | Manual | 1266 | OK | Manual; evidence only. |
| 6.1.2.6 | Ensure rsyslog is not configured to receive logs from a remote client | Automated | 1273 | OK | FIXED (A): PDF patterns anchored at line start (comments ignored), imtcp advanced + legacy formats. imudp is shown as informational evidence. |
| 6.1.2.7 | Ensure logrotate is configured | Manual | 1275 | OK | Manual; evidence only. |
| 6.1.2.8 | Ensure rsyslog-gnutls is installed | Automated | 1276 | OK |  |
| 6.1.2.9 | Ensure rsyslog forwarding uses gtls | Automated | 1279 | OK |  |
| 6.1.2.10 | Ensure rsyslog CA certificates are configured | Manual | 1281 | OK | Manual; evidence only. |
| 6.1.3.1 | Ensure access to all logfiles has been configured | Automated | 1294 | PARTIAL | Only checks world-writable on the first 200 files; PDF applies per-file masks (0137/0133/0113) and owner/group rules. |
| 6.2.1.1 | Ensure auditd packages are installed | Automated | 1297 | OK |  |
| 6.2.1.2 | Ensure auditd service is enabled and active | Automated | 1300 | PARTIAL | Checks active only; PDF requires enabled AND active. |
| 6.2.1.3 | Ensure auditing for processes that start prior to auditd is enabled | Automated | 1306 | OK | FIXED (B): every grub.cfg linux line must contain audit=1 (/proc/cmdline kept as evidence). |
| 6.2.1.4 | Ensure audit_backlog_limit is configured | Automated | 1308 | OK | FIXED (B): every grub.cfg linux line must contain audit_backlog_limit=<n>. |
| 6.2.2.1 | Ensure audit log storage size is configured | Automated | 1311 | OK |  |
| 6.2.2.2 | Ensure audit logs are not automatically deleted | Automated | 1313 | OK |  |
| 6.2.2.3 | Ensure system is disabled when audit logs are full | Automated | 1318 | OK | FIXED (B): disk_full_action halt\|single AND disk_error_action syslog\|single\|halt. |
| 6.2.2.4 | Ensure system warns when audit logs are low on space | Automated | 1322 | OK | FIXED (B): space_left_action email\|exec\|single\|halt AND admin_space_left_action single\|halt. |
| 6.2.3.1 | Ensure changes to system administration scope (sudoers) is collected | Automated | 1323 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.2 | Ensure actions as another user are always logged | Automated | 1325 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.3 | Ensure events that modify the sudo log file are collected | Automated | 1326 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.4 | Ensure events that modify date and time information are collected | Automated | 1327 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.5 | Ensure events that modify sethostname and setdomainname are collected | Automated | 1328 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.6 | Ensure events that modify /etc/issue and /etc/issue.net are collected | Automated | 1329 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.7 | Ensure events that modify /etc/hosts and /etc/hostname are collected | Automated | 1330 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.8 | Ensure events that modify /etc/network and /etc/networks are collected | Automated | 1331 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.9 | Ensure events that modify /etc/netplan are collected | Automated | 1332 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.10 | Ensure use of privileged commands are collected | Automated | 1333 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. PDF checks every SUID/SGID binary on each mounted partition has a rule. |
| 6.2.3.11 | Ensure events that modify /etc/group information are collected | Automated | 1334 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.12 | Ensure events that modify /etc/passwd information are collected | Automated | 1335 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.13 | Ensure events that modify /etc/shadow and /etc/gshadow are collected | Automated | 1336 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.14 | Ensure events that modify /etc/security/opasswd are collected | Automated | 1337 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.15 | Ensure events that modify /etc/nsswitch.conf file are collected | Automated | 1338 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.16 | Ensure events that modify /etc/pam.conf and /etc/pam.d/ information are collected | Automated | 1339 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.17 | Ensure unsuccessful file access attempts are collected | Automated | 1340 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.18 | Ensure discretionary access control permission modification events are collected | Automated | 1341 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.19 | Ensure successful file system mounts are collected | Automated | 1342 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.20 | Ensure session initiation information is collected | Automated | 1343 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.21 | Ensure login and logout events are collected | Automated | 1344 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.22 | Ensure file deletion events by users are collected | Automated | 1345 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.23 | Ensure events that modify the system's Mandatory Access Controls are collected | Automated | 1346 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.24 | Ensure successful and unsuccessful attempts to use the chcon command are collected | Automated | 1347 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.25 | Ensure successful and unsuccessful attempts to use the setfacl command are collected | Automated | 1348 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.26 | Ensure successful and unsuccessful attempts to use the chacl command are collected | Automated | 1349 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.27 | Ensure successful and unsuccessful attempts to use the usermod command are collected | Automated | 1350 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.28 | Ensure kernel module loading unloading and modification is collected | Automated | 1351 | PARTIAL | PDF requires the rule in BOTH the running config (`auditctl -l`) AND an on-disk rules file; script passes if EITHER matches, using a loose substring pattern. |
| 6.2.3.29 | Ensure the audit configuration is immutable | Automated | 1354 | OK |  |
| 6.2.3.30 | Ensure the running and on disk configuration is the same | Manual | 1356 | OK | Manual; evidence only. |
| 6.2.4.1 | Ensure the audit log file directory mode is configured | Automated | 1361 | OK |  |
| 6.2.4.2 | Ensure audit log files mode is configured | Automated | 1367 | OK |  |
| 6.2.4.3 | Ensure audit log files owner is configured | Automated | 1373 | OK |  |
| 6.2.4.4 | Ensure audit log files group owner is configured | Automated | 1380 | PARTIAL | PDF also checks log_group in auditd.conf is adm or root. |
| 6.2.4.5 | Ensure audit configuration files mode is configured | Automated | 1386 | OK | Scans all files under /etc/audit (PDF: *.conf and *.rules). |
| 6.2.4.6 | Ensure audit configuration files owner is configured | Automated | 1392 | OK |  |
| 6.2.4.7 | Ensure audit configuration files group owner is configured | Automated | 1399 | OK |  |
| 6.2.4.8 | Ensure audit tools mode is configured | Automated | 1406 | OK |  |
| 6.2.4.9 | Ensure audit tools owner is configured | Automated | 1413 | OK |  |
| 6.2.4.10 | Ensure audit tools group owner is configured | Automated | 1420 | OK |  |
| 6.3.1 | Ensure AIDE is installed | Automated | 1423 | PARTIAL | PDF also requires aide-common. |
| 6.3.2 | Ensure filesystem integrity is regularly checked | Automated | 1431 | OK | FIXED (A): dailyaidecheck.timer enabled AND active, dailyaidecheck.service static\|enabled. (Cron entries no longer count — PDF does not accept them; shown as evidence.) |
| 6.3.3 | Ensure cryptographic mechanisms are used to protect the integrity of audit tools | Automated | 1433 | PARTIAL | Only checks auditctl is mentioned in aide.conf; PDF requires options p,i,n,u,g,s,b,acl,xattrs,sha512 for all six audit tools. |
| 7.1.1 | Ensure access to /etc/passwd is configured | Automated | 1439 | OK |  |
| 7.1.2 | Ensure access to /etc/passwd- is configured | Automated | 1440 | OK |  |
| 7.1.3 | Ensure access to /etc/group is configured | Automated | 1441 | OK |  |
| 7.1.4 | Ensure access to /etc/group- is configured | Automated | 1442 | OK |  |
| 7.1.5 | Ensure access to /etc/shadow is configured | Automated | 1443 | OK | FIXED (B): group root or shadow accepted. |
| 7.1.6 | Ensure access to /etc/shadow- is configured | Automated | 1444 | OK | FIXED (B): group root or shadow accepted. |
| 7.1.7 | Ensure access to /etc/gshadow is configured | Automated | 1445 | OK | FIXED (B): group root or shadow accepted. |
| 7.1.8 | Ensure access to /etc/gshadow- is configured | Automated | 1446 | OK | FIXED (B): group root or shadow accepted. |
| 7.1.9 | Ensure access to /etc/shells is configured | Automated | 1447 | OK |  |
| 7.1.10 | Ensure access to /etc/security/opasswd is configured | Automated | 1449 | PARTIAL | PDF also checks /etc/security/opasswd.old. |
| 7.1.11 | Ensure world writable files and directories are secured | Automated | 1455 | PARTIAL | Files only; PDF also fails world-writable directories without the sticky bit; PDF excludes /proc, /sys, /snap, etc. |
| 7.1.12 | Ensure no files or directories without an owner and a group exist | Automated | 1458 | OK |  |
| 7.1.13 | Ensure SUID and SGID files are reviewed | Manual | 1460 | OK | Manual; evidence only. |
| 7.2.1 | Ensure accounts in /etc/passwd use shadowed passwords | Automated | 1465 | OK |  |
| 7.2.2 | Ensure /etc/shadow password fields are not empty | Automated | 1468 | OK |  |
| 7.2.3 | Ensure all groups in /etc/passwd exist in /etc/group | Automated | 1481 | OK |  |
| 7.2.4 | Ensure shadow group is empty | Automated | 1484 | PARTIAL | PDF also fails users whose primary GID is the shadow group. |
| 7.2.5 | Ensure no duplicate UIDs exist | Automated | 1487 | OK |  |
| 7.2.6 | Ensure no duplicate GIDs exist | Automated | 1490 | OK |  |
| 7.2.7 | Ensure no duplicate user names exist | Automated | 1493 | OK |  |
| 7.2.8 | Ensure no duplicate group names exist | Automated | 1496 | OK |  |
| 7.2.9 | Ensure local interactive user home directories are configured | Automated | 1530 | OK | FIXED (A): PDF script implemented: each interactive user's home exists, is owned by the user, mode 0750 or stricter. |
| 7.2.10 | Ensure local interactive user dot files access is configured | Automated | 1587 | OK | FIXED (A): PDF script implemented (recursive, same filesystem). Also flags `.rhosts` in addition to the PDF's `.rhost` spelling. |

 #!/usr/bin/env bash
# =============================================================================
# CIS Ubuntu Linux 24.04 LTS Benchmark v2.0.0 — compliance audit
# Generates an HTML report with Pass/Fail/Manual/N/A and command evidence
# for every recommendation in the benchmark (Automated and Manual).
#
# Also writes a persistent JSON results document (results.json contract, see
# CLAUDE.md) for the governance mapper / delta engine / exception handler.
#
# Run on the target Ubuntu 24.04 system as root:
#   sudo bash cis_ubuntu_24.04_lts_v2.0.0_audit.sh
#   sudo bash cis_ubuntu_24.04_lts_v2.0.0_audit.sh -o /root/cis-report.html
#   sudo bash cis_ubuntu_24.04_lts_v2.0.0_audit.sh -o /root/r.html --json /root/r.json
#   bash cis_ubuntu_24.04_lts_v2.0.0_audit.sh --dry-run-safe   # self-test only
# =============================================================================

set -u
umask 077

BENCHMARK="CIS Ubuntu Linux 24.04 LTS Benchmark"
BENCHMARK_VER="v2.0.0"
BENCHMARK_DATE="05-28-2026"
OUTFILE=""
JSON_OUT=""
FORCE_OS=0
SELF_TEST=0
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]:-$0}")"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Audits all recommendations in ${BENCHMARK} ${BENCHMARK_VER} and writes
an HTML report with evidence, plus a JSON results document.

Options:
  -o, --output FILE   HTML output path (default: ./cis-ubuntu-24.04-v2.0.0-audit-TIMESTAMP.html)
  --json FILE         JSON results path (default: HTML path with .json extension)
  --dry-run-safe      Self-test only: bash -n, shellcheck (if installed) and an
                      embedded-Python compile check. Runs no audit commands,
                      needs no root, writes nothing.
  --force             Skip Ubuntu 24.04 check
  -h, --help          Show help
EOF
}

self_test() {
  # Static checks of this script only. Never executes audit logic.
  local rc=0 sc_out sc_rc n_err n_warn n_info n_style
  echo "Self-test (--dry-run-safe) for: ${SCRIPT_PATH}"
  echo "No audit commands are executed and no files are written."
  echo
  if [[ ! -r "$SCRIPT_PATH" ]]; then
    echo "FAIL: cannot read script file (was it piped via stdin?)"
    return 1
  fi

  echo "[1/3] bash -n (syntax)"
  if sc_out="$(bash -n "$SCRIPT_PATH" 2>&1)"; then
    echo "  OK: no syntax errors"
  else
    printf '%s\n' "$sc_out" | sed 's/^/  /'
    echo "  FAIL: bash -n reported syntax errors"
    rc=1
  fi
  echo

  echo "[2/3] shellcheck"
  if command -v shellcheck >/dev/null 2>&1; then
    echo "  $(shellcheck --version 2>/dev/null | grep -m1 '^version' || echo 'version unknown')"
    sc_out="$(shellcheck -s bash -f gcc "$SCRIPT_PATH" 2>&1)"; sc_rc=$?
    if [[ $sc_rc -eq 0 ]]; then
      echo "  OK: no findings"
    else
      printf '%s\n' "$sc_out" | sed 's/^/  /'
      n_err="$(grep -c ': error:' <<<"$sc_out")"
      n_warn="$(grep -c ': warning:' <<<"$sc_out")"
      n_info="$(grep -c ': note:' <<<"$sc_out")"
      n_style="$(grep -c ': style:' <<<"$sc_out")"
      echo "  Summary: errors=${n_err} warnings=${n_warn} info=${n_info} style=${n_style}"
      if [[ "$n_err" -gt 0 ]]; then
        echo "  FAIL: shellcheck reported errors"
        rc=1
      else
        echo "  WARN: shellcheck findings above are warnings/info/style only"
      fi
    fi
  else
    echo "  SKIPPED: shellcheck not installed (sudo apt install shellcheck)"
  fi
  echo

  echo "[3/3] embedded Python 3 (stdlib only) compile check"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$SCRIPT_PATH" <<'PY' || rc=1
import sys
path = sys.argv[1]
start_marker = "<<" + "'PY'"
blocks, cur, start = [], None, 0
with open(path, encoding="utf-8") as f:
    for n, line in enumerate(f, 1):
        if cur is None:
            if start_marker in line:
                cur, start = [], n + 1
        elif line.rstrip("\n") == "PY":
            blocks.append((start, "".join(cur)))
            cur = None
        else:
            cur.append(line)
bad = 0
for start, src in blocks:
    try:
        compile(src, f"{path}:{start}", "exec")
    except SyntaxError as e:
        bad += 1
        print(f"  FAIL: Python block starting line {start}: {e}")
print(f"  Checked {len(blocks)} quoted Python heredoc block(s); {bad} with errors.")
print("  Note: the unquoted HTML-report block is bash-expanded at runtime and is covered by bash -n only.")
sys.exit(1 if bad else 0)
PY
  else
    echo "  FAIL: python3 not found (required at runtime)"
    rc=1
  fi
  echo
  if [[ $rc -eq 0 ]]; then echo "Self-test result: PASS"; else echo "Self-test result: FAIL"; fi
  return $rc
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) OUTFILE="${2:-}"; shift 2 ;;
    --json) JSON_OUT="${2:-}"; [[ -n "$JSON_OUT" ]] || { echo "--json requires a FILE argument" >&2; exit 2; }; shift 2 ;;
    --dry-run-safe) SELF_TEST=1; shift ;;
    --force) FORCE_OS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ "$SELF_TEST" -eq 1 ]]; then
  self_test
  exit $?
fi

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root so audit commands can collect complete evidence." >&2
  exit 1
fi

if [[ "$FORCE_OS" -eq 0 && -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    echo "This benchmark is for Ubuntu 24.04 LTS (detected: ${PRETTY_NAME:-unknown}). Use --force to continue." >&2
    exit 1
  fi
fi

command -v python3 >/dev/null 2>&1 || { echo "python3 is required to generate HTML." >&2; exit 1; }

TS="$(date +%Y%m%dT%H%M%S)"
[[ -n "$OUTFILE" ]] || OUTFILE="./cis-ubuntu-24.04-v2.0.0-audit-${TS}.html"
[[ -n "$JSON_OUT" ]] || JSON_OUT="${OUTFILE%.html}.json"
WORKDIR="$(mktemp -d /tmp/cis-audit.XXXXXX)"
JSONL="${WORKDIR}/results.jsonl"
trap 'rm -rf "$WORKDIR"' EXIT

HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
OS_PRETTY="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
KERNEL="$(uname -r)"
ARCH="$(uname -m)"
START_ISO="$(date -Is)"
START_EPOCH="$(date +%s)"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
cap() {
  # cap CMD...  — capture stdout+stderr, trim to 8000 chars
  local out
  out="$("$@" 2>&1)" || true
  if [[ ${#out} -gt 8000 ]]; then
    out="${out:0:8000}
... [truncated] ..."
  fi
  printf '%s' "$out"
}

record() {
  # record ID TITLE ASSESSMENT SECTION STATUS EVIDENCE
  local id="$1" title="$2" assessment="$3" section="$4" status="$5" evidence="$6"
  python3 - "$id" "$title" "$assessment" "$section" "$status" "$evidence" "$JSONL" <<'PY'
import json, sys
rec = {
    "id": sys.argv[1],
    "title": sys.argv[2],
    "assessment": sys.argv[3],
    "section": sys.argv[4],
    "status": sys.argv[5],
    "evidence": sys.argv[6],
}
with open(sys.argv[7], "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PY
  printf '  %-6s %s %s\n' "$status" "$id" "$title"
}

pkg_status() {
  dpkg-query -W -f='${Package} ${Status}\n' "$1" 2>&1 || echo "$1 not installed"
}

pkg_ok() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

unit_state() {
  local u="$1"
  printf 'is-enabled: %s\n' "$(systemctl is-enabled "$u" 2>&1 || true)"
  printf 'is-active:  %s\n' "$(systemctl is-active "$u" 2>&1 || true)"
}

kmod_evidence() {
  local name="$1" type="${2:-fs}"
  printf 'lsmod:\n%s\n\n' "$(lsmod | grep -E "${name}|${name//-/_}" || echo "(not loaded)")"
  printf 'modprobe --showconfig:\n%s\n\n' "$(modprobe --showconfig 2>/dev/null | grep -E "(install|blacklist)[[:space:]]+(${name}|${name//-/_})" || echo "(no install/blacklist line)")"
  printf 'module path present:\n'
  # shellcheck disable=SC2086
  ls -d /usr/lib/modules/*/kernel/${type}/${name//-/\/} /lib/modules/*/kernel/${type}/${name//-/\/} 2>/dev/null || echo "(path not found)"
}

kmod_pass() {
  local name="$1"
  if lsmod | grep -Eq "(^| )${name//-/_}|(^| )${name}"; then
    return 1
  fi
  if modprobe --showconfig 2>/dev/null | grep -Eq "(install|blacklist)[[:space:]]+(${name}|${name//-/_})"; then
    return 0
  fi
  # Not loaded and no module files → pass (CIS: not available)
  if ls -d /usr/lib/modules/*/kernel/*/"${name}" /usr/lib/modules/*/kernel/*/"${name//-/_}" \
           /usr/lib/modules/*/kernel/fs/"${name}" /lib/modules/*/kernel/fs/"${name}" 2>/dev/null | grep -q .; then
    return 1
  fi
  return 0
}

check_kmod() {
  local id="$1" title="$2" section="$3" name="$4" type="${5:-fs}"
  local ev st
  ev="$(kmod_evidence "$name" "$type")"
  if kmod_pass "$name"; then st="Pass"; else st="Fail"; fi
  record "$id" "$title" "Automated" "$section" "$st" "$ev"
}

mnt_line() {
  findmnt -kn "$1" 2>&1 || echo "$1 is not a mountpoint"
}

has_opt() {
  local mp="$1" opt="$2"
  local opts
  opts="$(findmnt -n -o OPTIONS "$mp" 2>/dev/null || true)"
  [[ ",${opts}," == *",${opt},"* ]]
}

check_separate_mp() {
  local id="$1" title="$2" section="$3" mp="$4"
  local ev st
  ev="$(mnt_line "$mp")"$'\n'"systemctl is-enabled for tmp.mount (if /tmp): $(systemctl is-enabled tmp.mount 2>&1 || true)"
  if findmnt -kn "$mp" >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
  record "$id" "$title" "Automated" "$section" "$st" "$ev"
}

check_mp_opt() {
  local id="$1" title="$2" section="$3" mp="$4" opt="$5"
  local ev st
  ev="$(mnt_line "$mp")"
  if ! findmnt -kn "$mp" >/dev/null 2>&1; then
    record "$id" "$title" "Automated" "$section" "Fail" "$ev"$'\n'"Mount does not exist; option ${opt} cannot be verified."
    return
  fi
  if has_opt "$mp" "$opt"; then st="Pass"; else st="Fail"; fi
  record "$id" "$title" "Automated" "$section" "$st" "$ev"$'\n'"Required option: ${opt}"
}

file_stat() {
  local f="$1"
  if [[ -e "$f" ]]; then
    stat -Lc 'Path=%n Mode=%a Owner=%U Group=%G Type=%F' "$f"
  else
    echo "$f does not exist"
  fi
}

mode_ok() {
  # mode_ok PATH MAX_OCTAL  — true if mode bits outside max are clear
  local path="$1" max="$2"
  [[ -e "$path" ]] || return 1
  python3 - "$path" "$max" <<'PY'
import os, sys
path, maxs = sys.argv[1], sys.argv[2]
mode = os.stat(path).st_mode & 0o777
mx = int(maxs, 8)
sys.exit(0 if (mode | mx) == mx else 1)
PY
}

check_perm() {
  local id="$1" title="$2" section="$3" path="$4" maxmode="$5" owner="$6" group="$7"
  local ev st="Pass"
  ev="$(file_stat "$path")"
  if [[ ! -e "$path" ]]; then
    record "$id" "$title" "Automated" "$section" "Not Applicable" "$ev"
    return
  fi
  local ou og
  ou="$(stat -c '%U' "$path")"
  og="$(stat -c '%G' "$path")"
  if ! mode_ok "$path" "$maxmode"; then st="Fail"; fi
  if [[ "$ou" != "$owner" ]]; then st="Fail"; fi
  if [[ -n "$group" && "$og" != "$group" ]]; then
    # allow alternate group if group contains |
    if [[ "$group" == *"|"* ]]; then
      python3 - "$og" "$group" <<'PY' || st="Fail"
import sys
og, allowed = sys.argv[1], sys.argv[2].split("|")
sys.exit(0 if og in allowed else 1)
PY
    else
      st="Fail"
    fi
  fi
  record "$id" "$title" "Automated" "$section" "$st" "$ev"$'\n'"Expected mode ${maxmode} or more restrictive, owner ${owner}, group ${group}"
}

sysctl_val() {
  sysctl -n "$1" 2>&1 || echo "unset"
}

check_sysctl() {
  local id="$1" title="$2" section="$3" key="$4" expected="$5"
  local ev cur st
  ev="sysctl ${key} = $(sysctl_val "$key")"$'\n'
  ev+="$(grep -Rhs "^[[:space:]]*${key}" /etc/sysctl.conf /etc/sysctl.d /usr/lib/sysctl.d 2>/dev/null | head -n 20 || true)"
  cur="$(sysctl -n "$key" 2>/dev/null || echo "")"
  if [[ "$cur" == "$expected" ]]; then st="Pass"; else st="Fail"; fi
  record "$id" "$title" "Automated" "$section" "$st" "$ev"$'\n'"Expected: ${expected}"
}

sshd_get() {
  sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==tolower(k){print $2; exit}'
}

check_sshd() {
  local id="$1" title="$2" section="$3" key="$4" expected="$5"
  local ev got st
  ev="$(sshd -T 2>/dev/null | grep -i "^${key} " || echo "(sshd -T: ${key} not found)")"
  got="$(sshd_get "$key")"
  if [[ "${got,,}" == "${expected,,}" ]]; then st="Pass"; else st="Fail"; fi
  record "$id" "$title" "Automated" "$section" "$st" "$ev"$'\n'"Expected: ${key} ${expected}"
}

service_not_in_use() {
  # Pass if none of the packages are installed, or all related units are masked/inactive
  local pkgs="$1" units="$2"
  local p u installed=0 active=0 ev=""
  for p in $pkgs; do
    ev+="$(pkg_status "$p")"$'\n'
    pkg_ok "$p" && installed=1
  done
  for u in $units; do
    ev+="$(unit_state "$u")"$'\n'
    if systemctl is-active "$u" 2>/dev/null | grep -q '^active'; then active=1; fi
    if systemctl is-enabled "$u" 2>/dev/null | grep -Eq 'enabled|alias'; then active=1; fi
  done
  if [[ "$installed" -eq 0 ]]; then echo Pass; printf '%s' "$ev"; return; fi
  if [[ "$active" -eq 0 ]]; then echo Pass; printf '%s' "$ev"$'\n'"Packages present but services not enabled/active."; return; fi
  echo Fail
  printf '%s' "$ev"
}

check_service_unused() {
  local id="$1" title="$2" section="$3" pkgs="$4" units="$5"
  local result ev st
  result="$(service_not_in_use "$pkgs" "$units")"
  st="$(printf '%s\n' "$result" | head -n1)"
  ev="$(printf '%s\n' "$result" | tail -n +2)"
  record "$id" "$title" "Automated" "$section" "$st" "$ev"
}

pkg_absent() {
  local id="$1" title="$2" section="$3" pkg="$4"
  local ev st
  ev="$(pkg_status "$pkg")"
  if pkg_ok "$pkg"; then st="Fail"; else st="Pass"; fi
  record "$id" "$title" "Automated" "$section" "$st" "$ev"
}

pkgs_absent() {
  # pkgs_absent ID TITLE SECTION "pkg1 pkg2 ..." — Fail if ANY listed package is installed
  local id="$1" title="$2" section="$3" pkgs="$4" p ev="" st="Pass"
  for p in $pkgs; do
    ev+="$(pkg_status "$p")"$'\n'
    pkg_ok "$p" && st="Fail"
  done
  record "$id" "$title" "Automated" "$section" "$st" "$ev"
}

pkg_present() {
  local id="$1" title="$2" section="$3" pkg="$4"
  local ev st
  ev="$(pkg_status "$pkg")"
  if pkg_ok "$pkg"; then st="Pass"; else st="Fail"; fi
  record "$id" "$title" "Automated" "$section" "$st" "$ev"
}

grep_conf() {
  grep -RhsE "$1" "${@:2}" 2>/dev/null | grep -v '^[[:space:]]*#' | head -n 40 || true
}

perm_ok() {
  # perm_ok PATH MAX_OCTAL OWNERS GROUPS — OWNERS/GROUPS are '|'-separated allow-lists
  local path="$1" max="$2" owners="$3" groups="$4" ou og
  [[ -e "$path" ]] || return 1
  mode_ok "$path" "$max" || return 1
  ou="$(stat -Lc '%U' "$path")"; og="$(stat -Lc '%G' "$path")"
  [[ "|${owners}|" == *"|${ou}|"* ]] || return 1
  [[ "|${groups}|" == *"|${og}|"* ]] || return 1
}

os_id() {
  # CIS banner checks use the ID= value from /etc/os-release (e.g. "ubuntu")
  grep '^ID=' /etc/os-release 2>/dev/null | cut -d= -f2 | sed -e 's/"//g'
}

banner_leaks() {
  # banner_leaks FILE... — prints lines (with file name) that disclose OS
  # information per CIS: \v \r \m \s escapes or the OS ID (case-insensitive).
  local id; id="$(os_id)"
  grep -PHsi -- '(\\v|\\r|\\m|\\s|\b'"${id:-ubuntu}"'\b)' "$@" 2>/dev/null
}

grub_linux_lines() {
  # Kernel command lines from every grub.cfg under /boot (persisted boot config)
  find /boot -type f -name 'grub.cfg' -exec grep -Ph -- '^\h*linux' {} + 2>/dev/null
}

audit_has() {
  (auditctl -l 2>/dev/null; cat /etc/audit/rules.d/*.rules 2>/dev/null) | grep -E "$1" >/dev/null
}

check_audit_rule() {
  local id="$1" title="$2" section="$3" pattern="$4"
  local ev st
  ev="auditctl -l (matching):"$'\n'"$(auditctl -l 2>/dev/null | grep -E "$pattern" || echo "(no matching live rules)")"$'\n\n'
  ev+="rules.d matching:"$'\n'"$(grep -RhsE "$pattern" /etc/audit/rules.d 2>/dev/null || echo "(no matching on-disk rules)")"
  if audit_has "$pattern"; then st="Pass"; else st="Fail"; fi
  record "$id" "$title" "Automated" "$section" "$st" "$ev"
}

echo "Collecting evidence for ${BENCHMARK} ${BENCHMARK_VER} on ${HOSTNAME_FQDN} ..."
echo

# =============================================================================
# 1 Initial Setup
# =============================================================================
S="1.1 Filesystem"

check_kmod "1.1.1.1" "Ensure cramfs kernel module is not available" "$S" cramfs fs
check_kmod "1.1.1.2" "Ensure freevxfs kernel module is not available" "$S" freevxfs fs
check_kmod "1.1.1.3" "Ensure hfs kernel module is not available" "$S" hfs fs
check_kmod "1.1.1.4" "Ensure hfsplus kernel module is not available" "$S" hfsplus fs
check_kmod "1.1.1.5" "Ensure jffs2 kernel module is not available" "$S" jffs2 fs
check_kmod "1.1.1.6" "Ensure overlay kernel module is not available" "$S" overlay fs
check_kmod "1.1.1.7" "Ensure squashfs kernel module is not available" "$S" squashfs fs
check_kmod "1.1.1.8" "Ensure udf kernel module is not available" "$S" udf fs
check_kmod "1.1.1.9" "Ensure firewire-core kernel module is not available" "$S" firewire-core drivers
check_kmod "1.1.1.10" "Ensure usb-storage kernel module is not available" "$S" usb-storage drivers

ev="$(ls /usr/lib/modules/"$(uname -r)"/kernel/fs 2>/dev/null | sort -u)"
record "1.1.1.11" "Ensure unused filesystems kernel modules are not available" "Manual" "$S" "Manual Review" \
  "Available filesystem modules under /usr/lib/modules/\$(uname -r)/kernel/fs:"$'\n'"$ev"$'\n'"Review and disable unused types per site policy."

check_separate_mp "1.1.2.1.1" "Ensure /tmp is tmpfs or a separate partition" "$S" /tmp
check_mp_opt "1.1.2.1.2" "Ensure nodev option set on /tmp partition" "$S" /tmp nodev
check_mp_opt "1.1.2.1.3" "Ensure nosuid option set on /tmp partition" "$S" /tmp nosuid
check_mp_opt "1.1.2.1.4" "Ensure noexec option set on /tmp partition" "$S" /tmp noexec
check_separate_mp "1.1.2.2.1" "Ensure /dev/shm is tmpfs or a separate partition" "$S" /dev/shm
check_mp_opt "1.1.2.2.2" "Ensure nodev option set on /dev/shm partition" "$S" /dev/shm nodev
check_mp_opt "1.1.2.2.3" "Ensure nosuid option set on /dev/shm partition" "$S" /dev/shm nosuid
check_mp_opt "1.1.2.2.4" "Ensure noexec option set on /dev/shm partition" "$S" /dev/shm noexec
check_separate_mp "1.1.2.3.1" "Ensure separate partition exists for /home" "$S" /home
check_mp_opt "1.1.2.3.2" "Ensure nodev option set on /home partition" "$S" /home nodev
check_mp_opt "1.1.2.3.3" "Ensure nosuid option set on /home partition" "$S" /home nosuid
check_separate_mp "1.1.2.4.1" "Ensure separate partition exists for /var" "$S" /var
check_mp_opt "1.1.2.4.2" "Ensure nodev option set on /var partition" "$S" /var nodev
check_mp_opt "1.1.2.4.3" "Ensure nosuid option set on /var partition" "$S" /var nosuid
check_separate_mp "1.1.2.5.1" "Ensure separate partition exists for /var/tmp" "$S" /var/tmp
check_mp_opt "1.1.2.5.2" "Ensure nodev option set on /var/tmp partition" "$S" /var/tmp nodev
check_mp_opt "1.1.2.5.3" "Ensure nosuid option set on /var/tmp partition" "$S" /var/tmp nosuid
check_mp_opt "1.1.2.5.4" "Ensure noexec option set on /var/tmp partition" "$S" /var/tmp noexec
check_separate_mp "1.1.2.6.1" "Ensure separate partition exists for /var/log" "$S" /var/log
check_mp_opt "1.1.2.6.2" "Ensure nodev option set on /var/log partition" "$S" /var/log nodev
check_mp_opt "1.1.2.6.3" "Ensure nosuid option set on /var/log partition" "$S" /var/log nosuid
check_mp_opt "1.1.2.6.4" "Ensure noexec option set on /var/log partition" "$S" /var/log noexec
check_separate_mp "1.1.2.7.1" "Ensure separate partition exists for /var/log/audit" "$S" /var/log/audit
check_mp_opt "1.1.2.7.2" "Ensure nodev option set on /var/log/audit partition" "$S" /var/log/audit nodev
check_mp_opt "1.1.2.7.3" "Ensure nosuid option set on /var/log/audit partition" "$S" /var/log/audit nosuid
check_mp_opt "1.1.2.7.4" "Ensure noexec option set on /var/log/audit partition" "$S" /var/log/audit noexec

S="1.2 Package Management"
ev="$(grep -RhsE 'Signed-By|signed-by|\[signed-by' /etc/apt/sources.list /etc/apt/sources.list.d /etc/apt/sources.list.d/*.sources 2>/dev/null | head -n 50)"
ev+=$'\n\n'"sources files:"$'\n'"$(ls -la /etc/apt/sources.list /etc/apt/sources.list.d 2>&1 | head -n 40)"
st="Manual Review"
if grep -RhsE 'Signed-By|signed-by' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -q .; then
  if grep -RLE 'Signed-By|signed-by' /etc/apt/sources.list.d --include='*.list' --include='*.sources' 2>/dev/null | grep -q .; then
    st="Fail"
  else
    st="Pass"
  fi
fi
record "1.2.1.1" "Ensure the source.list and .source files use the Signed-By option" "Manual" "$S" "$st" "$ev"

# CIS: apt-config dump must show Install-Recommends "0" AND Install-Suggests "0"
# (no output = Fail). "false" is accepted as apt's boolean equivalent of "0".
aptdump="$(apt-config dump 2>/dev/null | grep 'APT::Install-' || true)"
ev="apt-config dump | grep APT::Install-:"$'\n'"${aptdump:-(no APT::Install- options set: apt defaults to installing Recommends)}"
ev+=$'\n\n'"config files:"$'\n'"$(grep -RhsE 'Install-Recommends|Install-Suggests' /etc/apt/apt.conf /etc/apt/apt.conf.d 2>/dev/null || echo "(not set)")"
if grep -Eq '^APT::Install-Recommends "(0|false)";' <<<"$aptdump" && \
   grep -Eq '^APT::Install-Suggests "(0|false)";' <<<"$aptdump"; then st="Pass"; else st="Fail"; fi
record "1.2.1.2" "Ensure weak dependencies are configured" "Automated" "$S" "$st" "$ev"

ev="$(find /etc/apt /usr/share/keyrings -name '*.gpg' -o -name '*.asc' -o -name '*.gpg~' 2>/dev/null | while read -r f; do file_stat "$f"; done)"
st="Pass"
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  mode_ok "$f" "0644" || st="Fail"
done < <(find /etc/apt /usr/share/keyrings -type f \( -name '*.gpg' -o -name '*.asc' \) 2>/dev/null)
record "1.2.1.3" "Ensure access to gpg key files are configured" "Automated" "$S" "$st" "${ev:-"(no key files found)"}"

check_perm "1.2.1.4" "Ensure access to /etc/apt/trusted.gpg.d directory is configured" "$S" /etc/apt/trusted.gpg.d 0755 root root
check_perm "1.2.1.5" "Ensure access to /etc/apt/auth.conf.d directory is configured" "$S" /etc/apt/auth.conf.d 0755 root root
st="Pass"; ev=""
if [[ -d /etc/apt/auth.conf.d ]]; then
  while IFS= read -r f; do
    ev+="$(file_stat "$f")"$'\n'
    perm_ok "$f" "0640" root root || st="Fail"
  done < <(find /etc/apt/auth.conf.d -type f 2>/dev/null)
fi
record "1.2.1.6" "Ensure access to files in the /etc/apt/auth.conf.d/ directory is configured" "Automated" "$S" "$st" "${ev:-"(no files)"}"$'\n'"Expected each file mode 0640 or more restrictive, owner root, group root"
check_perm "1.2.1.7" "Ensure access to /usr/share/keyrings directory is configured" "$S" /usr/share/keyrings 0755 root root
check_perm "1.2.1.8" "Ensure access to /etc/apt/sources.list.d directory is configured" "$S" /etc/apt/sources.list.d 0755 root root
st="Pass"; ev=""
while IFS= read -r f; do
  ev+="$(file_stat "$f")"$'\n'
  mode_ok "$f" "0644" || st="Fail"
done < <(find /etc/apt/sources.list.d -type f 2>/dev/null)
record "1.2.1.9" "Ensure access to files in /etc/apt/sources.list.d are configured" "Automated" "$S" "$st" "${ev:-"(no files)"}"

ev="$(cap apt-get -s upgrade | tail -n 30)"
if apt-get -s upgrade 2>/dev/null | grep -q '0 upgraded, 0 newly installed'; then st="Pass"; else st="Fail"; fi
record "1.2.2.1" "Ensure updates, patches, and additional security software are installed" "Manual" "$S" "$st" "$ev"

S="1.3 Mandatory Access Control"
pkg_present "1.3.1.1" "Ensure apparmor packages are installed" "$S" apparmor
# CIS: no grub.cfg "linux" line may contain apparmor=0
glines="$(grub_linux_lines)"
ev="grub.cfg linux lines containing apparmor=0:"$'\n'"$(grep -E '(^|[[:space:]])apparmor=0([[:space:]]|$)' <<<"$glines" || echo "(none)")"
ev+=$'\n\n'"$(unit_state apparmor)"$'\n'"/sys/module/apparmor/parameters/enabled: $(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || echo unavailable)"
if [[ -z "$glines" ]]; then
  st="Fail"; ev+=$'\n'"No grub.cfg kernel (linux) lines found under /boot; cannot verify."
elif grep -Eq '(^|[[:space:]])apparmor=0([[:space:]]|$)' <<<"$glines"; then st="Fail"; else st="Pass"; fi
record "1.3.1.2" "Ensure AppArmor is enabled" "Automated" "$S" "$st" "$ev"
# CIS: profiles loaded, 0 profiles in complain mode, 0 processes unconfined but with a profile
aaout="$(aa-status 2>/dev/null || apparmor_status 2>/dev/null || true)"
ev="$(printf '%s\n' "$aaout" | grep -E 'profiles|processes' | head -n 40)"
aa_n() { grep -Eo "^[[:space:]]*[0-9]+ $1" <<<"$aaout" | grep -Eo '[0-9]+' | head -n1; }
aa_loaded="$(aa_n 'profiles are loaded')"
aa_complain="$(aa_n 'profiles are in complain mode')"
aa_unconf="$(aa_n 'processes are unconfined but have a profile defined')"
if [[ "${aa_loaded:-0}" -gt 0 && "${aa_complain:-1}" -eq 0 && "${aa_unconf:-1}" -eq 0 ]]; then st="Pass"; else st="Fail"; fi
record "1.3.1.3" "Ensure all AppArmor Profiles are enforcing" "Automated" "$S" "$st" "${ev:-"(aa-status produced no output)"}"$'\n'"Parsed: loaded=${aa_loaded:-?} complain=${aa_complain:-?} unconfined_with_profile=${aa_unconf:-?} (expected loaded>0, complain=0, unconfined=0)"
# CIS defines this as a sysctl (kernel.apparmor_restrict_unprivileged_unconfined = 1)
check_sysctl "1.3.1.4" "Ensure apparmor_restrict_unprivileged_unconfined is enabled" "$S" kernel.apparmor_restrict_unprivileged_unconfined 1

S="1.4 Configure Bootloader"
# CIS: grub.cfg must contain BOTH "set superusers" AND a password_pbkdf2 entry
ev="$(grep -Ehs '^[[:space:]]*(set[[:space:]]+superusers|password)' /boot/grub/grub.cfg 2>/dev/null | sed -E 's/(grub\.pbkdf2\.sha512\.[0-9]+\.)[^ ]+/\1<hash redacted>/' | head -n 20)"
if grep -Eqs '^[[:space:]]*set[[:space:]]+superusers' /boot/grub/grub.cfg && \
   grep -Eqs '^[[:space:]]*password_pbkdf2[[:space:]]' /boot/grub/grub.cfg; then st="Pass"; else st="Fail"; fi
record "1.4.1" "Ensure bootloader password is set" "Automated" "$S" "$st" "${ev:-"(no superusers/password lines in /boot/grub/grub.cfg)"}"$'\n'"Expected both: set superusers=... AND password_pbkdf2 <user> grub.pbkdf2.sha512..."
if [[ -f /boot/grub/grub.cfg ]]; then
  check_perm "1.4.2" "Ensure access to bootloader config is configured" "$S" /boot/grub/grub.cfg 0600 root root
else
  record "1.4.2" "Ensure access to bootloader config is configured" "Automated" "$S" "Fail" "grub.cfg not found"
fi

S="1.5 Additional Process Hardening"
check_sysctl "1.5.1" "Ensure fs.protected_hardlinks is configured" "$S" fs.protected_hardlinks 1
check_sysctl "1.5.2" "Ensure fs.protected_symlinks is configured" "$S" fs.protected_symlinks 1
cur="$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null || echo "")"
ev="sysctl kernel.yama.ptrace_scope = ${cur}"$'\n'"$(grep -Rhs kernel.yama.ptrace_scope /etc/sysctl.conf /etc/sysctl.d 2>/dev/null)"
if [[ "$cur" == "1" || "$cur" == "2" || "$cur" == "3" ]]; then st="Pass"; else st="Fail"; fi
record "1.5.3" "Ensure kernel.yama.ptrace_scope is configured" "Automated" "$S" "$st" "$ev"$'\n'"Expected: 1, 2, or 3"
check_sysctl "1.5.4" "Ensure fs.suid_dumpable is configured" "$S" fs.suid_dumpable 0
check_sysctl "1.5.5" "Ensure kernel.dmesg_restrict is configured" "$S" kernel.dmesg_restrict 1
pkg_absent "1.5.6" "Ensure prelink is not installed" "$S" prelink
ev="$(grep -R '^enabled' /etc/default/apport 2>/dev/null; unit_state apport.service 2>/dev/null)"
if grep -Eq '^enabled=0' /etc/default/apport 2>/dev/null || ! pkg_ok apport; then st="Pass"; else st="Fail"; fi
record "1.5.7" "Ensure Automatic Error Reporting is configured" "Automated" "$S" "$st" "${ev:-"(apport not present)"}"
check_sysctl "1.5.8" "Ensure kernel.kptr_restrict is configured" "$S" kernel.kptr_restrict 2
check_sysctl "1.5.9" "Ensure kernel.randomize_va_space is configured" "$S" kernel.randomize_va_space 2
ev="$(grep -RhsE 'ProcessSizeMax|Storage' /etc/systemd/coredump.conf /etc/systemd/coredump.conf.d 2>/dev/null)"
psm="$(grep -RhsE '^ProcessSizeMax' /etc/systemd/coredump.conf /etc/systemd/coredump.conf.d 2>/dev/null | tail -n1)"
if echo "$psm" | grep -Eq 'ProcessSizeMax\s*=\s*0'; then st="Pass"; else st="Fail"; fi
record "1.5.11" "Ensure systemd-coredump ProcessSizeMax is configured" "Automated" "$S" "$st" "$ev"
if grep -RhsE '^Storage\s*=\s*none' /etc/systemd/coredump.conf /etc/systemd/coredump.conf.d >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
record "1.5.12" "Ensure systemd-coredump Storage is configured" "Automated" "$S" "$st" "$ev"

S="1.6 Command Line Warning Banners"
banner_ok() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  ! grep -E '(\\v|\\r|\\m|\\s|Ubuntu)' "$f" >/dev/null
}
# 1.6.1 — CIS: no MOTD source (static or update-motd.d script) may disclose OS
# information; a missing /etc/motd is compliant ("Nothing should be returned").
motd_files=(/etc/motd /run/motd /usr/lib/motd /etc/motd.d/* /run/motd.d/* /usr/lib/motd.d/* /etc/update-motd.d/*)
leaks="$(banner_leaks "${motd_files[@]}" | head -n 40)"
ev="$(file_stat /etc/motd)"$'\n'"OS ID checked: $(os_id)"$'\n'"Lines disclosing OS information (\\v \\r \\m \\s or OS ID):"$'\n'"${leaks:-(none)}"
if [[ -z "$leaks" ]]; then st="Pass"; else st="Fail"; fi
record "1.6.1" "Ensure /etc/motd is configured" "Automated" "$S" "$st" "$ev"
for rec in "1.6.2|/etc/issue" "1.6.3|/etc/issue.net"; do
  id="${rec%%|*}"; f="${rec#*|}"
  ev="$(file_stat "$f")"$'\n'"--- contents ---"$'\n'"$(cat "$f" 2>/dev/null || true)"
  if banner_ok "$f"; then st="Pass"; else st="Fail"; fi
  record "$id" "Ensure $f is configured" "Automated" "$S" "$st" "$ev"
done
# 1.6.4 — CIS: for sshd/login/su/gdm-password, any pam_motd line with an explicit
# motd=<file> must reference a file that does not disclose OS information.
pam_motd_files() {
  # prints "pamfile<TAB>motdpath" for every motd= on an active pam_motd session line
  local svc file line p
  for svc in sshd login su gdm-password; do
    if [[ -f "/etc/pam.d/$svc" ]]; then file="/etc/pam.d/$svc"
    elif [[ -f "/usr/lib/pam.d/$svc" ]]; then file="/usr/lib/pam.d/$svc"
    else continue; fi
    while IFS= read -r line; do
      while IFS= read -r p; do
        p="${p%\"}"; p="${p#\"}"; p="${p%\'}"; p="${p#\'}"
        [[ -n "$p" ]] && printf '%s\t%s\n' "$file" "$p"
      done < <(printf '%s\n' "$line" | grep -oP '\bmotd=\K"[^"]+"|\bmotd=\K'\''[^'\'']+'\''|\bmotd=\K\S+')
    done < <(grep -Pi '^\h*session\h+(required|optional)\h+pam_motd\.so\b.*\bmotd=' "$file" 2>/dev/null)
  done
}
pm="$(pam_motd_files)"
ev="pam_motd session lines:"$'\n'"$(grep -PHs '^\h*session\h+\S+\h+pam_motd\.so\b' /etc/pam.d/sshd /etc/pam.d/login /etc/pam.d/su /etc/pam.d/gdm-password 2>/dev/null || echo "(none)")"
st="Pass"; leaks=""
while IFS=$'\t' read -r pf mp; do
  [[ -n "$mp" && -r "$mp" ]] || continue
  l="$(banner_leaks "$mp")"
  [[ -n "$l" ]] && { st="Fail"; leaks+="${pf} motd=${mp}"$'\n'"${l}"$'\n'; }
done <<<"$pm"
ev+=$'\n\n'"Explicit motd= files: $(cut -f2 <<<"$pm" | sort -u | tr '\n' ' ')"$'\n'"Files disclosing OS information:"$'\n'"${leaks:-(none)}"
record "1.6.4" "Ensure pam_motd is configured" "Automated" "$S" "$st" "$ev"
ev="$(sshd -T 2>/dev/null | grep -i banner || true)"$'\n'"$(ls -l /etc/ssh/sshd_config.d 2>/dev/null)"
bn="$(sshd_get banner)"
if [[ -n "$bn" && "$bn" != "none" ]]; then st="Pass"; else st="Fail"; fi
record "1.6.5" "Ensure sshd warning Banner is configured" "Automated" "$S" "$st" "$ev"
check_perm "1.6.6" "Ensure access to /etc/motd is configured" "$S" /etc/motd 0644 root root
check_perm "1.6.7" "Ensure access to /etc/issue is configured" "$S" /etc/issue 0644 root root
check_perm "1.6.8" "Ensure access to /etc/issue.net is configured" "$S" /etc/issue.net 0644 root root
# CIS: every motd= file referenced in /etc/pam.d must be 0644 or stricter, root:root
st="Pass"; ev=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  [[ -e "$f" ]] || { ev+="$f (referenced, does not exist)"$'\n'; continue; }
  ev+="$(file_stat "$f")"$'\n'
  perm_ok "$f" 0644 root root || st="Fail"
done < <(grep -hPo 'motd=\K\S+' /etc/pam.d/* 2>/dev/null | sed -e 's/^["'\'']//' -e 's/["'\'']$//' | sort -u)
record "1.6.9" "Ensure access to pam_motd file is configured" "Automated" "$S" "$st" "${ev:-"(no motd= files referenced in /etc/pam.d)"}"$'\n'"Expected mode 0644 or more restrictive, owner root, group root"
bnf="$(sshd_get banner)"
if [[ -n "$bnf" && "$bnf" != "none" && -e "$bnf" ]]; then
  check_perm "1.6.10" "Ensure access to sshd warning banner is configured" "$S" "$bnf" 0644 root root
else
  record "1.6.10" "Ensure access to sshd warning banner is configured" "Automated" "$S" "Fail" "Banner file not set or missing (sshd banner=${bnf:-unset})"
fi

S="1.7 GNOME Display Manager"
if pkg_ok gdm3 || pkg_ok gdm; then
  ev="$(grep -Rhs banner-message /etc/dconf/db 2>/dev/null | head -n 30; ls -R /etc/dconf 2>/dev/null | head -n 40)"
  if grep -Rhs 'banner-message-enable=true' /etc/dconf/db >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
  record "1.7.1" "Ensure GDM login banner is configured" "Automated" "$S" "$st" "$ev"
  if grep -Rhs 'disable-user-list=true' /etc/dconf/db >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
  record "1.7.2" "Ensure GDM disable-user-list is configured" "Automated" "$S" "$st" "$ev"
  if grep -Rhs 'idle-delay' /etc/dconf/db >/dev/null 2>&1 && grep -Rhs 'lock-enabled=true' /etc/dconf/db >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
  record "1.7.3" "Ensure GDM screen lock is configured" "Automated" "$S" "$st" "$ev"
  if grep -Rhs 'automount=false' /etc/dconf/db >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
  record "1.7.4" "Ensure GDM automount is configured" "Automated" "$S" "$st" "$ev"
  if grep -Rhs 'autorun-never=true' /etc/dconf/db >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
  record "1.7.5" "Ensure GDM autorun-never is configured" "Automated" "$S" "$st" "$ev"
  ev="$(grep -n Enable /etc/gdm3/custom.conf 2>/dev/null || echo "(no custom.conf Enable line)")"
  if grep -Eqs '^[[:space:]]*Enable[[:space:]]*=[[:space:]]*true' /etc/gdm3/custom.conf 2>/dev/null; then st="Fail"; else st="Pass"; fi
  record "1.7.6" "Ensure XDMCP is not enabled" "Automated" "$S" "$st" "$ev"
  # CIS: WaylandEnable=false in the [daemon] section of the GDM custom.conf
  # (PDF path /etc/gdm/custom.conf; Ubuntu's gdm3 uses /etc/gdm3/custom.conf)
  wl="$(for f in /etc/gdm3/custom.conf /etc/gdm/custom.conf; do
          [[ -f "$f" ]] && sed -n '/\[daemon\]/,/\[/p' "$f" | grep -Psi '^\h*waylandenable\b' | sed "s|^|$f: |"
        done)"
  ev="[daemon] WaylandEnable lines:"$'\n'"${wl:-(not set — GDM default is Wayland enabled)}"
  if grep -Piq ':\h*waylandenable\h*=\h*false\b' <<<"$wl"; then st="Pass"; else st="Fail"; fi
  record "1.7.7" "Ensure Xwayland is configured" "Automated" "$S" "$st" "$ev"
else
  # Same IDs/titles as the gdm3 branch above so downstream mapping joins correctly.
  for rec in \
    "1.7.1|Ensure GDM login banner is configured" \
    "1.7.2|Ensure GDM disable-user-list is configured" \
    "1.7.3|Ensure GDM screen lock is configured" \
    "1.7.4|Ensure GDM automount is configured" \
    "1.7.5|Ensure GDM autorun-never is configured" \
    "1.7.6|Ensure XDMCP is not enabled" \
    "1.7.7|Ensure Xwayland is configured"; do
    record "${rec%%|*}" "${rec#*|}" "Automated" "$S" "Not Applicable" "GDM/gdm3 is not installed."
  done
fi

# =============================================================================
# 2 Services
# =============================================================================
S="2.1 Server Services"
check_service_unused "2.1.1" "Ensure autofs services are not in use" "$S" "autofs" "autofs.service"
ev="$(postconf inet_interfaces 2>/dev/null; ss -tlnp | grep -E ':25|:587|:465' || echo "(no SMTP sockets)")"
if command -v postconf >/dev/null && postconf inet_interfaces 2>/dev/null | grep -Eq 'loopback-only|localhost|127.0.0.1'; then st="Pass"
elif ! ss -tln | grep -qE ':25|:587'; then st="Pass"
else st="Fail"; fi
record "2.1.2" "Ensure mail transfer agents are configured for local-only mode" "Automated" "$S" "$st" "$ev"
check_service_unused "2.1.3" "Ensure avahi daemon services are not in use" "$S" "avahi-daemon" "avahi-daemon.service avahi-daemon.socket"
ev="$(ss -tulnp 2>/dev/null)"
record "2.1.4" "Ensure only approved services are listening on a network interface" "Manual" "$S" "Manual Review" "$ev"$'\n'"Compare this listen list to the approved service inventory."
# CIS: no kea* package installed, or kea-dhcp4/6-server and kea-dhcp-ddns-server units not enabled/active
kea_pkgs="$(dpkg-query -W -f='${Package}\n' '*kea*' 2>/dev/null | sort -u | tr '\n' ' ')"
check_service_unused "2.1.5" "Ensure dhcp server services are not in use" "$S" "isc-dhcp-server ${kea_pkgs:-kea}" "isc-dhcp-server.service isc-dhcp-server6.service kea-dhcp4-server.service kea-dhcp6-server.service kea-dhcp-ddns-server.service"
check_service_unused "2.1.6" "Ensure web server services are not in use" "$S" "apache2 nginx lighttpd" "apache2.service nginx.service lighttpd.service"
check_service_unused "2.1.7" "Ensure dns server services are not in use" "$S" "bind9 unbound" "named.service bind9.service unbound.service"
check_service_unused "2.1.8" "Ensure ftp server services are not in use" "$S" "vsftpd proftpd-basic" "vsftpd.service proftpd.service"
check_service_unused "2.1.9" "Ensure dnsmasq services are not in use" "$S" "dnsmasq" "dnsmasq.service"
check_service_unused "2.1.10" "Ensure ldap server services are not in use" "$S" "slapd" "slapd.service"
check_service_unused "2.1.11" "Ensure message access server services are not in use" "$S" "dovecot-imapd dovecot-pop3d cyrus-imapd" "dovecot.service cyrus-imapd.service"
check_service_unused "2.1.12" "Ensure network file system services are not in use" "$S" "nfs-kernel-server" "nfs-server.service nfs-kernel-server.service"
check_service_unused "2.1.13" "Ensure nis server services are not in use" "$S" "nis ypserv" "ypserv.service"
check_service_unused "2.1.14" "Ensure print server services are not in use" "$S" "cups" "cups.service cups.socket cups.path"
check_service_unused "2.1.15" "Ensure rpcbind services are not in use" "$S" "rpcbind" "rpcbind.service rpcbind.socket"
check_service_unused "2.1.16" "Ensure rsync services are not in use" "$S" "rsync" "rsync.service rsyncd.service"
check_service_unused "2.1.17" "Ensure samba file server services are not in use" "$S" "samba samba-common-bin" "smbd.service nmbd.service"
check_service_unused "2.1.18" "Ensure snmp services are not in use" "$S" "snmpd" "snmpd.service"
check_service_unused "2.1.19" "Ensure telnet server services are not in use" "$S" "telnetd telnetd-ssl inetutils-telnetd" "inetutils-inetd.service telnet.socket telnet.service"
check_service_unused "2.1.20" "Ensure tftp server services are not in use" "$S" "tftpd-hpa" "tftpd-hpa.service"
check_service_unused "2.1.21" "Ensure web proxy server services are not in use" "$S" "squid" "squid.service"
check_service_unused "2.1.22" "Ensure xinetd services are not in use" "$S" "xinetd" "xinetd.service"
# CIS: xserver-common must not be installed (unless a GUI is required and approved)
pkg_absent "2.1.23" "Ensure X window server services are not in use" "$S" xserver-common

S="2.2 Client Services"
pkg_absent "2.2.1" "Ensure nis client is not installed" "$S" nis
pkg_absent "2.2.2" "Ensure rsh client is not installed" "$S" rsh-client
pkg_absent "2.2.3" "Ensure talk client is not installed" "$S" talk
pkgs_absent "2.2.4" "Ensure telnet client is not installed" "$S" "telnet inetutils-telnet"
pkg_absent "2.2.5" "Ensure ldap client is not installed" "$S" ldap-utils
pkgs_absent "2.2.6" "Ensure ftp client is not installed" "$S" "ftp tnftp"

S="2.3 Time Synchronization"
ev="$(unit_state systemd-timesyncd.service)"$'\n'"$(unit_state chrony.service)"$'\n'"$(timedatectl status 2>/dev/null)"
tsd=0; ch=0
systemctl is-active systemd-timesyncd 2>/dev/null | grep -q active && tsd=1
systemctl is-active chrony 2>/dev/null | grep -q active && ch=1
if [[ $((tsd+ch)) -eq 1 ]]; then st="Pass"; else st="Fail"; fi
record "2.3.1.1" "Ensure a single time synchronization daemon is in use" "Automated" "$S" "$st" "$ev"
ev="$(cat /etc/systemd/timesyncd.conf /etc/systemd/timesyncd.conf.d/*.conf 2>/dev/null | grep -v '^#' | grep -v '^$')"
if grep -RhsE '^NTP=' /etc/systemd/timesyncd.conf /etc/systemd/timesyncd.conf.d >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
if [[ "$tsd" -eq 0 ]]; then st="Not Applicable"; fi
record "2.3.2.1" "Ensure systemd-timesyncd configured with authorized timeserver" "Automated" "$S" "$st" "${ev:-"(timesyncd not in use)"}"
if [[ "$tsd" -eq 1 ]] && systemctl is-enabled systemd-timesyncd 2>/dev/null | grep -q enabled; then st="Pass"; elif [[ "$tsd" -eq 0 ]]; then st="Not Applicable"; else st="Fail"; fi
record "2.3.2.2" "Ensure systemd-timesyncd is enabled and running" "Automated" "$S" "$st" "$(unit_state systemd-timesyncd.service)"
ev="$(grep -RhsE '^(server|pool|user) ' /etc/chrony/chrony.conf /etc/chrony/conf.d 2>/dev/null)"
if [[ "$ch" -eq 0 ]]; then
  record "2.3.3.1" "Ensure chrony is configured" "Automated" "$S" "Not Applicable" "(chrony not in use)"
  record "2.3.3.2" "Ensure chrony is running as user _chrony" "Automated" "$S" "Not Applicable" "(chrony not in use)"
  record "2.3.3.3" "Ensure chrony is enabled and running" "Automated" "$S" "Not Applicable" "(chrony not in use)"
else
  if echo "$ev" | grep -qE 'server|pool'; then st="Pass"; else st="Fail"; fi
  record "2.3.3.1" "Ensure chrony is configured" "Automated" "$S" "$st" "$ev"
  ev2="$(ps -eo user,cmd | grep -E '[c]hronyd|[c]hrony' || true)"
  if echo "$ev2" | grep -q _chrony; then st="Pass"; else st="Fail"; fi
  record "2.3.3.2" "Ensure chrony is running as user _chrony" "Automated" "$S" "$st" "$ev2"
  if systemctl is-enabled chrony 2>/dev/null | grep -q enabled; then st="Pass"; else st="Fail"; fi
  record "2.3.3.3" "Ensure chrony is enabled and running" "Automated" "$S" "$st" "$(unit_state chrony.service)"
fi

S="2.4 Job Schedulers"
ev="$(unit_state cron.service)"$'\n'"$(unit_state crond.service)"
if systemctl is-active cron 2>/dev/null | grep -q active || systemctl is-active crond 2>/dev/null | grep -q active; then st="Pass"; else st="Fail"; fi
record "2.4.1.1" "Ensure cron daemon is enabled and active" "Automated" "$S" "$st" "$ev"
check_perm "2.4.1.2" "Ensure access to /etc/crontab is configured" "$S" /etc/crontab 0600 root root
check_perm "2.4.1.3" "Ensure access to /etc/cron.hourly is configured" "$S" /etc/cron.hourly 0700 root root
check_perm "2.4.1.4" "Ensure access to /etc/cron.daily is configured" "$S" /etc/cron.daily 0700 root root
check_perm "2.4.1.5" "Ensure access to /etc/cron.weekly is configured" "$S" /etc/cron.weekly 0700 root root
check_perm "2.4.1.6" "Ensure access to /etc/cron.monthly is configured" "$S" /etc/cron.monthly 0700 root root
if [[ -d /etc/cron.yearly ]]; then
  check_perm "2.4.1.7" "Ensure access to /etc/cron.yearly is configured" "$S" /etc/cron.yearly 0700 root root
else
  record "2.4.1.7" "Ensure access to /etc/cron.yearly is configured" "Automated" "$S" "Not Applicable" "/etc/cron.yearly does not exist"
fi
check_perm "2.4.1.8" "Ensure access to /etc/cron.d is configured" "$S" /etc/cron.d 0700 root root
ev="$(file_stat /etc/cron.allow; file_stat /etc/cron.deny; echo '--- cron.allow ---'; cat /etc/cron.allow 2>/dev/null || true)"
# CIS: cron.allow exists, 0640 or stricter, owner root, group root|crontab;
#      cron.deny absent OR meets the same requirements
if [[ -f /etc/cron.allow ]] && perm_ok /etc/cron.allow 0640 root "root|crontab" && \
   { [[ ! -e /etc/cron.deny ]] || perm_ok /etc/cron.deny 0640 root "root|crontab"; }; then st="Pass"; else st="Fail"; fi
record "2.4.1.9" "Ensure access to crontab is configured" "Automated" "$S" "$st" "$ev"$'\n'"Expected cron.allow (and cron.deny if present): mode 0640 or more restrictive, owner root, group root or crontab"
# CIS: at.allow exists, 0640 or stricter, owner root, group daemon|root;
#      at.deny absent OR meets the same requirements
ev="$(file_stat /etc/at.allow; file_stat /etc/at.deny; echo '--- at.allow ---'; cat /etc/at.allow 2>/dev/null || true)"
if [[ -f /etc/at.allow ]] && perm_ok /etc/at.allow 0640 root "daemon|root" && \
   { [[ ! -e /etc/at.deny ]] || perm_ok /etc/at.deny 0640 root "daemon|root"; }; then st="Pass"; else st="Fail"; fi
record "2.4.2.1" "Ensure access to at is configured" "Automated" "$S" "$st" "$ev"$'\n'"Expected at.allow (and at.deny if present): mode 0640 or more restrictive, owner root, group daemon or root"

# =============================================================================
# 3 Network
# =============================================================================
S="3.1 Network Devices"
ev="sysctl net.ipv6.conf.all.disable_ipv6 = $(sysctl_val net.ipv6.conf.all.disable_ipv6)"$'\n'"ip -6 addr 2>/dev/null | head -n 40"
record "3.1.1" "Ensure IPv6 status is identified" "Manual" "$S" "Manual Review" "$ev"$'\n'"Document whether IPv6 is required by site policy."
ev="$(ip link show 2>/dev/null | grep -iE 'wlan|wifi|wl' || echo "(no wireless links named)")"$'\n'"$(nmcli radio 2>/dev/null || true)"$'\n'"$(lsmod | grep -iE 'wifi|wlan|cfg80211|mac80211' || echo "(wireless modules not loaded)")"
if ip link show 2>/dev/null | grep -qiE 'wlan|wifi'; then st="Fail"; else st="Pass"; fi
record "3.1.2" "Ensure wireless interfaces are not available" "Automated" "$S" "$st" "$ev"
check_service_unused "3.1.3" "Ensure bluetooth services are not in use" "$S" "bluez" "bluetooth.service"

S="3.2 Network Kernel Modules"
check_kmod "3.2.1" "Ensure atm kernel module is not available" "$S" atm net
check_kmod "3.2.2" "Ensure can kernel module is not available" "$S" can net
check_kmod "3.2.3" "Ensure dccp kernel module is not available" "$S" dccp net
check_kmod "3.2.4" "Ensure rds kernel module is not available" "$S" rds net
check_kmod "3.2.5" "Ensure sctp kernel module is not available" "$S" sctp net
check_kmod "3.2.6" "Ensure tipc kernel module is not available" "$S" tipc net

S="3.3 Network Kernel Parameters"
check_sysctl "3.3.1.1" "Ensure net.ipv4.ip_forward is configured" "$S" net.ipv4.ip_forward 0
check_sysctl "3.3.1.2" "Ensure net.ipv4.conf.all.forwarding is configured" "$S" net.ipv4.conf.all.forwarding 0
check_sysctl "3.3.1.3" "Ensure net.ipv4.conf.default.forwarding is configured" "$S" net.ipv4.conf.default.forwarding 0
check_sysctl "3.3.1.4" "Ensure net.ipv4.conf.all.send_redirects is configured" "$S" net.ipv4.conf.all.send_redirects 0
check_sysctl "3.3.1.5" "Ensure net.ipv4.conf.default.send_redirects is configured" "$S" net.ipv4.conf.default.send_redirects 0
check_sysctl "3.3.1.6" "Ensure net.ipv4.icmp_ignore_bogus_error_responses is configured" "$S" net.ipv4.icmp_ignore_bogus_error_responses 1
check_sysctl "3.3.1.7" "Ensure net.ipv4.icmp_echo_ignore_broadcasts is configured" "$S" net.ipv4.icmp_echo_ignore_broadcasts 1
check_sysctl "3.3.1.8" "Ensure net.ipv4.conf.all.accept_redirects is configured" "$S" net.ipv4.conf.all.accept_redirects 0
check_sysctl "3.3.1.9" "Ensure net.ipv4.conf.default.accept_redirects is configured" "$S" net.ipv4.conf.default.accept_redirects 0
check_sysctl "3.3.1.10" "Ensure net.ipv4.conf.all.secure_redirects is configured" "$S" net.ipv4.conf.all.secure_redirects 0
check_sysctl "3.3.1.11" "Ensure net.ipv4.conf.default.secure_redirects is configured" "$S" net.ipv4.conf.default.secure_redirects 0
check_sysctl "3.3.1.12" "Ensure net.ipv4.conf.all.rp_filter is configured" "$S" net.ipv4.conf.all.rp_filter 1
check_sysctl "3.3.1.13" "Ensure net.ipv4.conf.default.rp_filter is configured" "$S" net.ipv4.conf.default.rp_filter 1
check_sysctl "3.3.1.14" "Ensure net.ipv4.conf.all.accept_source_route is configured" "$S" net.ipv4.conf.all.accept_source_route 0
check_sysctl "3.3.1.15" "Ensure net.ipv4.conf.default.accept_source_route is configured" "$S" net.ipv4.conf.default.accept_source_route 0
check_sysctl "3.3.1.16" "Ensure net.ipv4.conf.all.log_martians is configured" "$S" net.ipv4.conf.all.log_martians 1
check_sysctl "3.3.1.17" "Ensure net.ipv4.conf.default.log_martians is configured" "$S" net.ipv4.conf.default.log_martians 1
check_sysctl "3.3.1.18" "Ensure net.ipv4.tcp_syncookies is configured" "$S" net.ipv4.tcp_syncookies 1
check_sysctl "3.3.2.1" "Ensure net.ipv6.conf.all.forwarding is configured" "$S" net.ipv6.conf.all.forwarding 0
check_sysctl "3.3.2.2" "Ensure net.ipv6.conf.default.forwarding is configured" "$S" net.ipv6.conf.default.forwarding 0
check_sysctl "3.3.2.3" "Ensure net.ipv6.conf.all.accept_redirects is configured" "$S" net.ipv6.conf.all.accept_redirects 0
check_sysctl "3.3.2.4" "Ensure net.ipv6.conf.default.accept_redirects is configured" "$S" net.ipv6.conf.default.accept_redirects 0
check_sysctl "3.3.2.5" "Ensure net.ipv6.conf.all.accept_source_route is configured" "$S" net.ipv6.conf.all.accept_source_route 0
check_sysctl "3.3.2.6" "Ensure net.ipv6.conf.default.accept_source_route is configured" "$S" net.ipv6.conf.default.accept_source_route 0
check_sysctl "3.3.2.7" "Ensure net.ipv6.conf.all.accept_ra is configured" "$S" net.ipv6.conf.all.accept_ra 0
check_sysctl "3.3.2.8" "Ensure net.ipv6.conf.default.accept_ra is configured" "$S" net.ipv6.conf.default.accept_ra 0

# =============================================================================
# 4 UFW
# =============================================================================
S="4 Host Based Firewall"
pkg_present "4.1.1" "Ensure ufw is installed" "$S" ufw
ev="$(unit_state ufw.service)"$'\n'"$(ufw status verbose 2>&1 | head -n 80)"
# CIS: ufw.service enabled AND active AND `ufw status` reports active
if systemctl is-enabled ufw.service 2>/dev/null | grep -q '^enabled' && \
   systemctl is-active ufw.service 2>/dev/null | grep -q '^active' && \
   ufw status 2>/dev/null | grep -qi 'Status: active'; then st="Pass"; else st="Fail"; fi
record "4.1.2" "Ensure ufw service is configured" "Automated" "$S" "$st" "$ev"
def="$(ufw status verbose 2>/dev/null | grep -i 'Default:' || true)"
# CIS: incoming deny|reject; outgoing deny|reject; routed disabled|deny
echo "$def" | grep -Eqi '(deny|reject) \(incoming\)' && st="Pass" || st="Fail"
record "4.1.3" "Ensure ufw incoming default is configured" "Automated" "$S" "$st" "${def:-"(ufw inactive or not installed)"}"$'\n'"Expected: deny or reject (incoming)"
echo "$def" | grep -Eqi '(deny|reject) \(outgoing\)' && st="Pass" || st="Fail"
record "4.1.4" "Ensure ufw outgoing default is configured" "Automated" "$S" "$st" "${def:-"(ufw inactive or not installed)"}"$'\n'"Expected: deny or reject (outgoing)"
echo "$def" | grep -Eqi '(disabled|deny) \(routed\)' && st="Pass" || st="Fail"
record "4.1.5" "Ensure ufw routed default is configured" "Automated" "$S" "$st" "${def:-"(ufw inactive or not installed)"}"$'\n'"Expected: disabled or deny (routed)"

# =============================================================================
# 5 Access Control
# =============================================================================
S="5.1 SSH Server"
check_perm "5.1.1" "Ensure access to /etc/ssh/sshd_config is configured" "$S" /etc/ssh/sshd_config 0600 root root
ev="$(find /etc/ssh -xdev -type f -name 'ssh_host_*_key' -exec stat -Lc 'Path=%n Mode=%a Owner=%U Group=%G' {} \; 2>/dev/null)"
st="Pass"
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  mode_ok "$f" "0600" || st="Fail"
  [[ "$(stat -c '%U:%G' "$f")" == "root:root" ]] || st="Fail"
done < <(find /etc/ssh -xdev -type f -name 'ssh_host_*_key' 2>/dev/null)
record "5.1.2" "Ensure access to SSH private host key files is configured" "Automated" "$S" "$st" "$ev"
ev="$(find /etc/ssh -xdev -type f -name 'ssh_host_*_key.pub' -exec stat -Lc 'Path=%n Mode=%a Owner=%U Group=%G' {} \; 2>/dev/null)"
st="Pass"
while IFS= read -r f; do
  mode_ok "$f" "0644" || st="Fail"
done < <(find /etc/ssh -xdev -type f -name 'ssh_host_*_key.pub' 2>/dev/null)
record "5.1.3" "Ensure access to SSH public host key files is configured" "Automated" "$S" "$st" "$ev"
ev="$(sshd -T 2>/dev/null | grep -iE '^(allowusers|allowgroups|denyusers|denygroups) ' || echo "(no AllowUsers/AllowGroups/Deny* set)")"
if sshd -T 2>/dev/null | grep -qiE '^(allowusers|allowgroups|denyusers|denygroups) '; then st="Pass"; else st="Fail"; fi
record "5.1.4" "Ensure sshd access is configured" "Automated" "$S" "$st" "$ev"
# CIS: Banner set to an absolute path AND the banner file discloses no OS information
bn="$(sshd_get banner)"
ev="$(sshd -T 2>/dev/null | grep -i '^banner ' || echo "(sshd -T: banner not found)")"
if [[ "$bn" == /* ]]; then
  leaks="$(banner_leaks "$bn")"
  ev+=$'\n'"$(file_stat "$bn")"$'\n'"--- contents ---"$'\n'"$(head -n 40 "$bn" 2>/dev/null)"
  ev+=$'\n'"Lines disclosing OS information:"$'\n'"${leaks:-(none)}"
  if [[ -z "$leaks" ]]; then st="Pass"; else st="Fail"; fi
else
  st="Fail"
fi
record "5.1.5" "Ensure sshd Banner is configured" "Automated" "$S" "$st" "$ev"$'\n'"Expected: banner /<path> whose contents do not disclose OS information"
ev="$(sshd -T 2>/dev/null | grep -i '^ciphers ')"
if echo "$ev" | grep -Piq '(3des|blowfish|cast128|aes(128|192|256)-cbc|arcfour)'; then st="Fail"; else st="Pass"; fi
record "5.1.6" "Ensure sshd Ciphers are configured" "Automated" "$S" "$st" "$ev"
ev="$(sshd -T 2>/dev/null | grep -iE '^clientaliveinterval|^clientalivecountmax')"
iv="$(sshd_get clientaliveinterval)"; cm="$(sshd_get clientalivecountmax)"
# CIS: both ClientAliveInterval and ClientAliveCountMax greater than zero
if [[ "$iv" =~ ^[0-9]+$ && "$cm" =~ ^[0-9]+$ && "$iv" -gt 0 && "$cm" -gt 0 ]]; then st="Pass"; else st="Fail"; fi
record "5.1.7" "Ensure sshd ClientAliveInterval and ClientAliveCountMax are configured" "Automated" "$S" "$st" "$ev"
check_sshd "5.1.8" "Ensure sshd DisableForwarding is enabled" "$S" disableforwarding yes
check_sshd "5.1.9" "Ensure sshd GSSAPIAuthentication is disabled" "$S" gssapiauthentication no
check_sshd "5.1.10" "Ensure sshd HostbasedAuthentication is disabled" "$S" hostbasedauthentication no
check_sshd "5.1.11" "Ensure sshd IgnoreRhosts is enabled" "$S" ignorerhosts yes
ev="$(sshd -T 2>/dev/null | grep -i '^kexalgorithms ')"
if echo "$ev" | grep -Piq 'diffie-hellman-group1-sha1|diffie-hellman-group14-sha1|diffie-hellman-group-exchange-sha1'; then st="Fail"; else st="Pass"; fi
record "5.1.12" "Ensure sshd KexAlgorithms is configured" "Automated" "$S" "$st" "$ev"
ev="$(sshd -T 2>/dev/null | grep -i '^logingracetime ')"
lg="$(sshd_get logingracetime)"
if [[ -n "$lg" && "$lg" -ge 1 && "$lg" -le 60 ]]; then st="Pass"; else st="Fail"; fi
record "5.1.13" "Ensure sshd LoginGraceTime is configured" "Automated" "$S" "$st" "$ev"
# CIS: LogLevel VERBOSE or INFO
ev="$(sshd -T 2>/dev/null | grep -i '^loglevel ' || echo "(sshd -T: loglevel not found)")"
ll="$(sshd_get loglevel)"
if [[ "${ll^^}" == "VERBOSE" || "${ll^^}" == "INFO" ]]; then st="Pass"; else st="Fail"; fi
record "5.1.14" "Ensure sshd LogLevel is configured" "Automated" "$S" "$st" "$ev"$'\n'"Expected: loglevel VERBOSE or INFO"
ev="$(sshd -T 2>/dev/null | grep -i '^macs ')"
if echo "$ev" | grep -Piq 'hmac-md5|hmac-sha1-96|umac-64@openssh'; then st="Fail"; else st="Pass"; fi
record "5.1.15" "Ensure sshd MACs are configured" "Automated" "$S" "$st" "$ev"
ev="$(sshd -T 2>/dev/null | grep -i '^maxauthtries ')"
mt="$(sshd_get maxauthtries)"
if [[ -n "$mt" && "$mt" -le 4 ]]; then st="Pass"; else st="Fail"; fi
record "5.1.16" "Ensure sshd MaxAuthTries is configured" "Automated" "$S" "$st" "$ev"
ev="$(sshd -T 2>/dev/null | grep -i '^maxstartups ')"
# CIS: 10:30:60 or more restrictive (start <= 10, rate <= 30, full <= 60)
mxs="$(sshd_get maxstartups)"
if [[ -n "$mxs" ]] && awk -v v="$mxs" 'BEGIN{n=split(v,a,":"); if(a[1]>10 || (n>1 && a[2]>30) || (n>2 && a[3]>60)) exit 1; exit 0}'; then st="Pass"; else st="Fail"; fi
record "5.1.17" "Ensure sshd MaxStartups is configured" "Automated" "$S" "$st" "$ev"$'\n'"Expected 10:30:60 or more restrictive"
ms="$(sshd_get maxsessions)"
ev="$(sshd -T 2>/dev/null | grep -i '^maxsessions ')"
if [[ -n "$ms" && "$ms" -le 10 ]]; then st="Pass"; else st="Fail"; fi
record "5.1.18" "Ensure sshd MaxSessions is configured" "Automated" "$S" "$st" "$ev"
check_sshd "5.1.19" "Ensure sshd PermitEmptyPasswords is disabled" "$S" permitemptypasswords no
check_sshd "5.1.20" "Ensure sshd PermitRootLogin is disabled" "$S" permitrootlogin no
check_sshd "5.1.21" "Ensure sshd PermitUserEnvironment is disabled" "$S" permituserenvironment no
check_sshd "5.1.22" "Ensure sshd UsePAM is enabled" "$S" usepam yes
ev="$(sshd -T 2>/dev/null | grep -i '^kexalgorithms ')"
if echo "$ev" | grep -q 'sntrup761x25519-sha512'; then st="Pass"; else st="Fail"; fi
record "5.1.23" "Ensure sshd post-quantum cryptography key exchange algorithms are configured" "Automated" "$S" "$st" "$ev"
ev="$(sshd -T 2>/dev/null | grep -i '^listenaddress ')"
# sshd -T prints host:port (e.g. 0.0.0.0:22, [::]:22); strip the port before comparing.
# Fail if unset or if any ListenAddress is a wildcard (all interfaces).
st="Pass"; n_la=0
while read -r _ la; do
  [[ -n "$la" ]] || continue
  n_la=$((n_la+1))
  host="$(sed -E 's/:[0-9]+$//' <<<"$la")"
  case "$host" in 0.0.0.0|"[::]"|"::"|"*") st="Fail" ;; esac
done < <(sshd -T 2>/dev/null | awk 'tolower($1)=="listenaddress"')
[[ "$n_la" -gt 0 ]] || st="Fail"
record "5.1.24" "Ensure sshd ListenAddress is configured" "Automated" "$S" "$st" "$ev"$'\n'"Should not listen on all interfaces unless approved."

S="5.2 Privilege escalation"
pkg_present "5.2.1" "Ensure sudo is installed" "$S" sudo
ev="$(grep -Rhs 'use_pty' /etc/sudoers /etc/sudoers.d 2>/dev/null)"
if grep -Rhs '^Defaults.*use_pty' /etc/sudoers /etc/sudoers.d >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
record "5.2.2" "Ensure sudo commands use pty" "Automated" "$S" "$st" "$ev"
ev="$(grep -Rhs 'logfile' /etc/sudoers /etc/sudoers.d 2>/dev/null; ls -l /var/log/sudo.log 2>&1)"
if grep -Rhs 'logfile=' /etc/sudoers /etc/sudoers.d >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
record "5.2.3" "Ensure sudo log file exists" "Automated" "$S" "$st" "$ev"
ev="$(grep -RhsE 'NOPASSWD|!authenticate' /etc/sudoers /etc/sudoers.d 2>/dev/null || echo "(no NOPASSWD/!authenticate found)")"
if grep -RhsE '^[^#].*NOPASSWD' /etc/sudoers /etc/sudoers.d >/dev/null 2>&1; then st="Fail"; else st="Pass"; fi
record "5.2.4" "Ensure users must provide password for escalation" "Automated" "$S" "$st" "$ev"
if grep -RhsE 'Defaults\s+!authenticate' /etc/sudoers /etc/sudoers.d >/dev/null 2>&1; then st="Fail"; else st="Pass"; fi
record "5.2.5" "Ensure re-authentication for privilege escalation is not disabled globally" "Automated" "$S" "$st" "$ev"
# CIS: timestamp_timeout not negative (disabled) and not greater than 15 minutes.
# Configured values in /etc/sudoers* take precedence; otherwise use the sudo default (sudo -V).
tt_cfg="$(grep -rhPs '^\h*Defaults\b[^#\n\r]*\btimestamp_timeout\h*=\h*-?[0-9.]+' /etc/sudoers /etc/sudoers.d 2>/dev/null)"
tt_vals="$(grep -oP 'timestamp_timeout\h*=\h*\K-?[0-9.]+' <<<"$tt_cfg")"
if [[ -n "$tt_vals" ]]; then
  ev="Configured in /etc/sudoers*:"$'\n'"$tt_cfg"
else
  tt_def="$(sudo -V 2>/dev/null | grep -Pi 'timestamp\h+timeout\b' | head -n1)"
  tt_vals="$(grep -oP ':\h*\K-?[0-9.]+' <<<"$tt_def" | head -n1)"
  ev="Not set in /etc/sudoers*; sudo default (sudo -V): ${tt_def:-(could not determine)}"
fi
if [[ -n "$tt_vals" ]] && awk '{ if ($1 < 0 || $1 > 15) bad=1 } END { exit bad }' <<<"$tt_vals"; then st="Pass"; else st="Fail"; fi
record "5.2.6" "Ensure sudo timestamp_timeout is configured" "Automated" "$S" "$st" "$ev"$'\n'"Expected: 0 to 15 minutes (negative = never expires = Fail)"
# CIS: active "auth required|requisite pam_wheel.so use_uid group=<g>" in /etc/pam.d/su,
#      and group <g> exists with no members (commented lines do not count)
wl="$(grep -Pi '^\h*auth\h+(required|requisite)\h+pam_wheel\.so\b' /etc/pam.d/su 2>/dev/null | grep -Pi '\buse_uid\b' | grep -Pi '\bgroup=\S+' | head -n1)"
wg="$(grep -oP '\bgroup=\K\S+' <<<"$wl" | head -n1)"
ev="Active pam_wheel lines in /etc/pam.d/su:"$'\n'"$(grep -Pi '^\h*auth\h+\S+\h+pam_wheel\.so\b' /etc/pam.d/su 2>/dev/null || echo "(none — commented lines are ignored)")"
st="Fail"
if [[ -n "$wg" ]]; then
  wgl="$(awk -F: -v g="$wg" '$1==g' /etc/group)"
  ev+=$'\n'"Group ${wg}: ${wgl:-(does not exist)}"
  if [[ -n "$wgl" && -z "$(cut -d: -f4 <<<"$wgl")" ]]; then st="Pass"; fi
fi
record "5.2.7" "Ensure access to the su command is restricted" "Automated" "$S" "$st" "$ev"$'\n'"Expected: auth required pam_wheel.so use_uid group=<group> and <group> has no members"

S="5.3 PAM"
pkg_present "5.3.1.1" "Ensure latest version of pam is installed" "$S" libpam-runtime
pkg_present "5.3.1.2" "Ensure latest version of libpam-modules is installed" "$S" libpam-modules
pkg_present "5.3.1.3" "Ensure latest version of libpam-pwquality is installed" "$S" libpam-pwquality
pkg_present "5.3.1.4" "Ensure latest version of cracklib-runtime is installed" "$S" cracklib-runtime
ev="$(grep -n pam_unix /etc/pam.d/common-password /etc/pam.d/common-auth 2>/dev/null | head -n 20)"
if grep -q pam_unix.so /etc/pam.d/common-password 2>/dev/null; then st="Pass"; else st="Fail"; fi
record "5.3.2.1" "Ensure pam_unix module is enabled" "Automated" "$S" "$st" "$ev"
ev="$(grep -n pam_faillock /etc/pam.d/common-auth /etc/pam.d/common-account 2>/dev/null)"
if grep -q pam_faillock /etc/pam.d/common-auth 2>/dev/null; then st="Pass"; else st="Fail"; fi
record "5.3.2.2" "Ensure pam_faillock module is enabled" "Automated" "$S" "$st" "$ev"
ev="$(grep -n pam_pwquality /etc/pam.d/common-password 2>/dev/null)"
if grep -q pam_pwquality /etc/pam.d/common-password 2>/dev/null; then st="Pass"; else st="Fail"; fi
record "5.3.2.3" "Ensure pam_pwquality module is enabled" "Automated" "$S" "$st" "$ev"
ev="$(grep -n pam_pwhistory /etc/pam.d/common-password 2>/dev/null)"
if grep -q pam_pwhistory /etc/pam.d/common-password 2>/dev/null; then st="Pass"; else st="Fail"; fi
record "5.3.2.4" "Ensure pam_pwhistory module is enabled" "Automated" "$S" "$st" "$ev"

pwq_get() { grep -E "^[[:space:]]*$1" /etc/security/pwquality.conf /etc/security/faillock.conf /etc/security/pwhistory.conf 2>/dev/null | tail -n1; }
ev="$(cat /etc/security/faillock.conf 2>/dev/null | grep -v '^#' | grep -v '^$')"
deny="$(grep -E '^[[:space:]]*deny' /etc/security/faillock.conf 2>/dev/null | awk '{print $NF}')"
if [[ "${deny:-99}" -le 5 ]]; then st="Pass"; else st="Fail"; fi
record "5.3.3.1.1" "Ensure password failed attempts lockout is configured" "Automated" "$S" "$st" "$ev"
# CIS: unlock_time = 0 (never) or >= 900 in faillock.conf, and no pam_faillock
#      unlock_time argument of 1-899 in common-auth
ut="$(grep -Pi '^\h*unlock_time\h*=\h*\d+' /etc/security/faillock.conf 2>/dev/null | tail -n1 | grep -oP '\d+\h*$' | tr -d '[:space:]')"
ut_pam="$(grep -Pi '^\h*auth\h+(requisite|required|sufficient)\h+pam_faillock\.so\h+([^#\n\r]+\h+)?unlock_time\h*=\h*([1-9]|[1-9][0-9]|[1-8][0-9][0-9])\b' /etc/pam.d/common-auth 2>/dev/null)"
if [[ -n "$ut" ]] && { [[ "$ut" -eq 0 ]] || [[ "$ut" -ge 900 ]]; } && [[ -z "$ut_pam" ]]; then st="Pass"; else st="Fail"; fi
record "5.3.3.1.2" "Ensure password unlock time is configured" "Automated" "$S" "$st" "$ev"$'\n'"unlock_time=${ut:-unset}; common-auth override: ${ut_pam:-(none)}"$'\n'"Expected: 0 (never) or 900 or more"
if grep -Eq '^[[:space:]]*even_deny_root|^[[:space:]]*root_unlock_time' /etc/security/faillock.conf 2>/dev/null; then st="Pass"; else st="Fail"; fi
record "5.3.3.1.3" "Ensure password failed attempts lockout includes root account" "Automated" "$S" "$st" "$ev"

ev="$(grep -vE '^#|^$' /etc/security/pwquality.conf 2>/dev/null)"
difok="$(awk -F= '/^[[:space:]]*difok/{gsub(/ /,"",$2); print $2}' /etc/security/pwquality.conf 2>/dev/null | tail -n1)"
if [[ "${difok:-0}" -ge 2 ]]; then st="Pass"; else st="Fail"; fi
record "5.3.3.2.1" "Ensure password number of changed characters is configured" "Automated" "$S" "$st" "$ev"
minlen="$(awk -F= '/^[[:space:]]*minlen/{gsub(/ /,"",$2); print $2}' /etc/security/pwquality.conf 2>/dev/null | tail -n1)"
if [[ "${minlen:-0}" -ge 14 ]]; then st="Pass"; else st="Fail"; fi
record "5.3.3.2.2" "Ensure password length is configured" "Automated" "$S" "$st" "$ev"
record "5.3.3.2.3" "Ensure password complexity is configured" "Manual" "$S" "Manual Review" "$ev"$'\n'"Confirm minclass/credit settings match site policy (CIS Manual)."
maxr="$(awk -F= '/^[[:space:]]*maxrepeat/{gsub(/ /,"",$2); print $2}' /etc/security/pwquality.conf 2>/dev/null | tail -n1)"
if [[ -n "${maxr:-}" && "${maxr}" -le 3 ]]; then st="Pass"; else st="Fail"; fi
record "5.3.3.2.4" "Ensure password same consecutive characters is configured" "Automated" "$S" "$st" "$ev"
maxs="$(awk -F= '/^[[:space:]]*maxsequence/{gsub(/ /,"",$2); print $2}' /etc/security/pwquality.conf 2>/dev/null | tail -n1)"
if [[ -n "${maxs:-}" && "${maxs}" -le 3 ]]; then st="Pass"; else st="Fail"; fi
record "5.3.3.2.5" "Ensure password maximum sequential characters is configured" "Automated" "$S" "$st" "$ev"
# CIS: dictcheck must NOT be set to 0 (default is enabled) in pwquality.conf,
#      pwquality.conf.d/*.conf, or as a pam_pwquality argument
dc="$(grep -PHsi -- '^\h*dictcheck\h*=\h*0\b' /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf 2>/dev/null)"
dc+="$(grep -PHsi -- '^\h*password\h+(requisite|required|sufficient)\h+pam_pwquality\.so\h+([^#\n\r]+\h+)?dictcheck\h*=\h*0\b' /etc/pam.d/common-password 2>/dev/null)"
if [[ -z "$dc" ]]; then st="Pass"; else st="Fail"; fi
record "5.3.3.2.6" "Ensure password dictionary check is enabled" "Automated" "$S" "$st" "$ev"$'\n'"dictcheck=0 found in: ${dc:-(none — default enabled)}"
# CIS: enforcing must NOT be set to 0 (default is enforcing)
ef="$(grep -PHsi -- '^\h*enforcing\h*=\h*0\b' /etc/security/pwquality.conf /etc/security/pwquality.conf.d/*.conf 2>/dev/null)"
ef+="$(grep -PHsi -- '^\h*password\h+[^#\n\r]+\h+pam_pwquality\.so\h+([^#\n\r]+\h+)?enforcing=0\b' /etc/pam.d/common-password 2>/dev/null)"
if [[ -z "$ef" ]]; then st="Pass"; else st="Fail"; fi
record "5.3.3.2.7" "Ensure password quality checking is enforced" "Automated" "$S" "$st" "$ev"$'\n'"enforcing=0 found in: ${ef:-(none — default enforcing)}"
if grep -Eq '^[[:space:]]*enforce_for_root' /etc/security/pwquality.conf 2>/dev/null; then st="Pass"; else st="Fail"; fi
record "5.3.3.2.8" "Ensure password quality is enforced for the root user" "Automated" "$S" "$st" "$ev"

ev="$(grep -vE '^#|^$' /etc/security/pwhistory.conf 2>/dev/null; grep pam_pwhistory /etc/pam.d/common-password 2>/dev/null)"
rem="$(grep -Eo 'remember[[:space:]]*=[[:space:]]*[0-9]+' /etc/security/pwhistory.conf /etc/pam.d/common-password 2>/dev/null | tail -n1 | grep -Eo '[0-9]+')"
if [[ "${rem:-0}" -ge 24 ]]; then st="Pass"; else st="Fail"; fi
record "5.3.3.3.1" "Ensure password history remember is configured" "Automated" "$S" "$st" "$ev"
if echo "$ev" | grep -q enforce_for_root; then st="Pass"; else st="Fail"; fi
record "5.3.3.3.2" "Ensure password history is enforced for the root user" "Automated" "$S" "$st" "$ev"
if echo "$ev" | grep -q use_authtok; then st="Pass"; else st="Fail"; fi
record "5.3.3.3.3" "Ensure pam_pwhistory includes use_authtok" "Automated" "$S" "$st" "$ev"
ev="$(grep pam_unix /etc/pam.d/common-password /etc/pam.d/common-auth 2>/dev/null)"
if echo "$ev" | grep -q nullok; then st="Fail"; else st="Pass"; fi
record "5.3.3.4.1" "Ensure pam_unix does not include nullok" "Automated" "$S" "$st" "$ev"
if echo "$ev" | grep -q remember=; then st="Fail"; else st="Pass"; fi
record "5.3.3.4.2" "Ensure pam_unix does not include remember" "Automated" "$S" "$st" "$ev"
if echo "$ev" | grep -Eq 'yescrypt|sha512'; then st="Pass"; else st="Fail"; fi
record "5.3.3.4.3" "Ensure pam_unix includes a strong password hashing algorithm" "Automated" "$S" "$st" "$ev"
if grep pam_unix /etc/pam.d/common-password 2>/dev/null | grep -q use_authtok; then st="Pass"; else st="Fail"; fi
record "5.3.3.4.4" "Ensure pam_unix includes use_authtok" "Automated" "$S" "$st" "$ev"

S="5.4 User Accounts and Environment"
login_get() { awk -v k="$1" '$1==k{print $2}' /etc/login.defs; }
ev="$(grep -E '^(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE|ENCRYPT_METHOD|UMASK|INACTIVE)' /etc/login.defs /etc/default/useradd 2>/dev/null)"
pmax="$(login_get PASS_MAX_DAYS)"
if [[ "${pmax:-99999}" -le 365 && "${pmax:-0}" -ge 1 ]]; then st="Pass"; else st="Fail"; fi
record "5.4.1.1" "Ensure password expiration is configured" "Automated" "$S" "$st" "$ev"
pmin="$(login_get PASS_MIN_DAYS)"
record "5.4.1.2" "Ensure minimum password days is configured" "Manual" "$S" "$([[ "${pmin:-0}" -ge 1 ]] && echo Pass || echo Fail)" "$ev"$'\n'"PASS_MIN_DAYS=${pmin:-unset}"
pwarn="$(login_get PASS_WARN_AGE)"
if [[ "${pwarn:-0}" -ge 7 ]]; then st="Pass"; else st="Fail"; fi
record "5.4.1.3" "Ensure password expiration warning days is configured" "Automated" "$S" "$st" "$ev"
enc="$(login_get ENCRYPT_METHOD)"
if echo "${enc}" | grep -Eqi 'YESCRYPT|SHA512'; then st="Pass"; else st="Fail"; fi
record "5.4.1.4" "Ensure strong password hashing algorithm is configured" "Automated" "$S" "$st" "$ev"
ina="$(grep ^INACTIVE /etc/default/useradd 2>/dev/null | cut -d= -f2)"
if [[ -n "$ina" && "$ina" -ge 0 && "$ina" -le 45 ]]; then st="Pass"; else st="Fail"; fi
record "5.4.1.5" "Ensure inactive password lock is configured" "Automated" "$S" "$st" "$ev"$'\n'"INACTIVE=${ina:-unset}"
ev="$(awk -F: '{print $1,$3}' /etc/shadow | while read -r u lst; do [[ "$lst" == "!!" || "$lst" == "*" || -z "$lst" ]] && continue; python3 - "$u" "$lst" <<'PY'
import datetime,sys
u,lst=sys.argv[1],sys.argv[2]
try:
    d=int(lst)
except:
    print(f"{u}: lastchg={lst}"); raise SystemExit
epoch=datetime.date(1970,1,1)+datetime.timedelta(days=d)
print(f"{u}: lastchg={epoch.isoformat()} ({d})")
if epoch>datetime.date.today():
    print("FUTURE")
PY
done)"
if echo "$ev" | grep -q FUTURE; then st="Fail"; else st="Pass"; fi
record "5.4.1.6" "Ensure all users last password change date is in the past" "Automated" "$S" "$st" "$ev"

ev="$(awk -F: '($3==0){print $1": uid="$3}' /etc/passwd)"
if [[ "$(awk -F: '($3==0){print $1}' /etc/passwd)" == "root" ]]; then st="Pass"; else st="Fail"; fi
record "5.4.2.1" "Ensure root is the only UID 0 account" "Automated" "$S" "$st" "$ev"
ev="$(awk -F: '($4==0){print $1": gid="$4}' /etc/passwd)"
if [[ "$(awk -F: '($4==0){print $1}' /etc/passwd)" == "root" ]]; then st="Pass"; else st="Fail"; fi
record "5.4.2.2" "Ensure root is the only GID 0 account" "Automated" "$S" "$st" "$ev"
ev="$(awk -F: '($3==0){print $1": gid="$3}' /etc/group)"
if [[ "$(awk -F: '($3==0){c++} END{print c+0}' /etc/group)" -eq 1 ]]; then st="Pass"; else st="Fail"; fi
record "5.4.2.3" "Ensure group root is the only GID 0 group" "Automated" "$S" "$st" "$ev"
# CIS: passwd -S root status is P (password set) or L (locked); NP (no password) fails
rps="$(passwd -S root 2>/dev/null)"
ev="passwd -S root: ${rps:-(unavailable)}"
if awk '$2 ~ /^(P|L)/ {ok=1} END {exit !ok}' <<<"$rps"; then st="Pass"; else st="Fail"; fi
record "5.4.2.4" "Ensure root account access is controlled" "Automated" "$S" "$st" "$ev"$'\n'"Expected status P (password set) or L (locked)"
# CIS: root's PATH has no empty entry (::), no trailing ':', no '.', only existing
#      directories owned by root and not group/other writable (0755 or stricter)
root_path="$(su - root -c env 2>/dev/null | awk -F= '$1=="PATH"{print $2}')"
rp_src="su - root -c env"
[[ -n "$root_path" ]] || { root_path="$PATH"; rp_src="audit process PATH (su - root unavailable)"; }
rp_bad=""
grep -q -- '::' <<<"$root_path" && rp_bad+=" - root's PATH contains an empty directory (::)"$'\n'
grep -Pq -- ':\h*$' <<<"$root_path" && rp_bad+=" - root's PATH contains a trailing (:)"$'\n'
grep -Pq -- '(^\h*|:)\.(:|\h*$)' <<<"$root_path" && rp_bad+=" - root's PATH contains current working directory (.)"$'\n'
IFS=':' read -ra rp_parts <<<"$root_path"
for p in "${rp_parts[@]}"; do
  if [[ -d "$p" ]]; then
    IFS=: read -r p_mode p_own <<<"$(stat -Lc '%#a:%U' "$p")"
    [[ "$p_own" != "root" ]] && rp_bad+=" - Directory \"$p\" is owned by \"$p_own\" (should be root)"$'\n'
    (( p_mode & 0022 )) && rp_bad+=" - Directory \"$p\" is mode $p_mode (should be 0755 or more restrictive)"$'\n'
  else
    rp_bad+=" - \"$p\" is not a directory"$'\n'
  fi
done
ev="root PATH (${rp_src}): ${root_path}"$'\n'"Problems:"$'\n'"${rp_bad:-(none)}"
if [[ -z "$rp_bad" ]]; then st="Pass"; else st="Fail"; fi
record "5.4.2.5" "Ensure root path integrity" "Automated" "$S" "$st" "$ev"
# CIS: /root/.profile and /root/.bashrc must not set a umask less restrictive than 0027
#      (no umask line at all is compliant)
rum="$(grep -PHsi -- '^\h*umask\h+((\d{1,2}(\d[^7]|[^2-7]\d)\b)|(u=[rwx]{1,3},)?(((g=[rx]?[rx]?w[rx]?[rx]?\b)(,o=[rwx]{1,3})?)|((g=[wrx]{1,3},)?o=[wrx]{1,3}\b)))' /root/.profile /root/.bashrc 2>/dev/null)"
ev="umask lines in /root/.profile and /root/.bashrc:"$'\n'"$(grep -PHsi '^\h*umask\b' /root/.profile /root/.bashrc 2>/dev/null || echo "(none)")"$'\n'"Less restrictive than 0027:"$'\n'"${rum:-(none)}"
if [[ -z "$rum" ]]; then st="Pass"; else st="Fail"; fi
record "5.4.2.6" "Ensure root user umask is configured" "Automated" "$S" "$st" "$ev"
# CIS: accounts with UID < UID_MIN (or 65534), except root/halt/sync/shutdown/nfsnobody,
#      must not have a valid login shell (valid = listed in /etc/shells, not nologin)
ev="$(python3 <<'PY'
import os
try:
    shells = {l.strip() for l in open("/etc/shells") if l.strip().startswith("/")
              and os.path.basename(l.strip()) != "nologin"}
except OSError:
    shells = set()
uid_min = 1000
try:
    for l in open("/etc/login.defs"):
        p = l.split()
        if len(p) >= 2 and p[0] == "UID_MIN":
            uid_min = int(p[1])
except (OSError, ValueError):
    pass
bad = []
for l in open("/etc/passwd"):
    f = l.rstrip("\n").split(":")
    if len(f) < 7 or f[0] in ("root", "halt", "sync", "shutdown", "nfsnobody"):
        continue
    try:
        uid = int(f[2])
    except ValueError:
        continue
    if (uid < uid_min or uid == 65534) and f[6] in shells:
        bad.append(f'Service account: "{f[0]}" (uid {uid}) has a valid shell: {f[6]}')
print(f"UID_MIN={uid_min}; valid shells: {' '.join(sorted(shells)) or '(none)'}")
print("\n".join(bad) if bad else "(no service accounts with a valid login shell)")
raise SystemExit(1 if bad else 0)
PY
)" && st="Pass" || st="Fail"
record "5.4.2.7" "Ensure system accounts do not have a valid login shell" "Automated" "$S" "$st" "$ev"
ev="$(awk -F: '($7 ~ /nologin|false/){print $1}' /etc/passwd | while read -r u; do passwd -S "$u" 2>/dev/null; done)"
st="Pass"
awk -F: '($7 ~ /nologin|false/){print $1}' /etc/passwd | while read -r u; do
  [[ "$u" == "root" ]] && continue
  passwd -S "$u" 2>/dev/null | grep -qvE ' L | LK ' && echo UNLOCKED "$u"
done | grep -q UNLOCKED && st="Fail"
record "5.4.2.8" "Ensure accounts without a valid login shell are locked" "Automated" "$S" "$st" "$ev"
ev="$(cat /etc/shells 2>/dev/null)"
if grep -q nologin /etc/shells 2>/dev/null; then st="Fail"; else st="Pass"; fi
record "5.4.3.1" "Ensure nologin is not listed in /etc/shells" "Automated" "$S" "$st" "$ev"
ev="$(grep -Rhs TMOUT /etc/profile /etc/profile.d /etc/bash.bashrc 2>/dev/null | head -n 20)"
if grep -RhsE 'TMOUT=([1-9][0-9]{0,2}|[1-8][0-9]{3}|900)' /etc/profile /etc/profile.d >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
record "5.4.3.2" "Ensure default user shell timeout is configured" "Automated" "$S" "$st" "$ev"
ev="$(grep -RhsE 'umask|UMASK' /etc/login.defs /etc/profile /etc/profile.d 2>/dev/null | head -n 30)"
if grep -Eqs 'UMASK[[:space:]]+027|umask[[:space:]]+027' /etc/login.defs /etc/profile /etc/profile.d/* 2>/dev/null; then st="Pass"; else st="Fail"; fi
record "5.4.3.3" "Ensure default user umask is configured" "Automated" "$S" "$st" "$ev"

# =============================================================================
# 6 Logging and Auditing
# =============================================================================
S="6.1 System Logging"
ev="$(unit_state systemd-journald.service)"
if systemctl is-active systemd-journald 2>/dev/null | grep -q active; then st="Pass"; else st="Fail"; fi
record "6.1.1.1.1" "Ensure journald service is active" "Automated" "$S" "$st" "$ev"
ev="$(unit_state systemd-journal-remote.service)"$'\n'"$(unit_state systemd-journal-remote.socket)"
if systemctl is-enabled systemd-journal-remote.socket 2>/dev/null | grep -Eq 'masked|disabled|not-found' && \
   systemctl is-enabled systemd-journal-remote.service 2>/dev/null | grep -Eq 'masked|disabled|not-found'; then st="Pass"; else st="Fail"; fi
record "6.1.1.1.2" "Ensure systemd-journal-remote service is not in use" "Automated" "$S" "$st" "$ev"
ev="$(grep -Rhs ForwardToSyslog /etc/systemd/journald.conf /etc/systemd/journald.conf.d 2>/dev/null)"
if grep -RhsE '^ForwardToSyslog=yes' /etc/systemd/journald.conf /etc/systemd/journald.conf.d >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
record "6.1.1.1.3" "Ensure journald is configured to send logs to rsyslog" "Automated" "$S" "$st" "$ev"
ev="$(ls -la /var/log/journal 2>&1 | head -n 20)"
record "6.1.1.1.4" "Ensure journald log file access is configured" "Manual" "$S" "Manual Review" "$ev"
ev="$(grep -RhsE 'SystemMaxUse|MaxFileSec|RuntimeMaxUse' /etc/systemd/journald.conf /etc/systemd/journald.conf.d 2>/dev/null)"
record "6.1.1.1.5" "Ensure journald log file rotation is configured" "Manual" "$S" "Manual Review" "$ev"
ev="$(grep -Rhs '^Storage' /etc/systemd/journald.conf /etc/systemd/journald.conf.d 2>/dev/null)"
if grep -RhsE '^Storage=persistent' /etc/systemd/journald.conf /etc/systemd/journald.conf.d >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
record "6.1.1.1.6" "Ensure journald Storage is configured" "Automated" "$S" "$st" "$ev"
ev="$(grep -Rhs '^Compress' /etc/systemd/journald.conf /etc/systemd/journald.conf.d 2>/dev/null)"
if grep -RhsE '^Compress=yes' /etc/systemd/journald.conf /etc/systemd/journald.conf.d >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
record "6.1.1.1.7" "Ensure journald Compress is configured" "Automated" "$S" "$st" "$ev"
pkg_present "6.1.2.1" "Ensure rsyslog is installed" "$S" rsyslog
ev="$(unit_state rsyslog.service)"
if systemctl is-active rsyslog 2>/dev/null | grep -q active; then st="Pass"; else st="Fail"; fi
record "6.1.2.2" "Ensure rsyslog service is enabled and active" "Automated" "$S" "$st" "$ev"
ev="$(grep -Rhs FileCreateMode /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null)"
if grep -RhsE '\$FileCreateMode[[:space:]]+0[246][04]0' /etc/rsyslog.conf /etc/rsyslog.d >/dev/null 2>&1; then st="Pass"; else st="Fail"; fi
record "6.1.2.3" "Ensure rsyslog log file creation mode is configured" "Automated" "$S" "$st" "$ev"
ev="$(ls /etc/rsyslog.d 2>/dev/null; grep -vE '^#|^$' /etc/rsyslog.conf 2>/dev/null | head -n 40)"
record "6.1.2.4" "Ensure rsyslog logging is configured" "Manual" "$S" "Manual Review" "$ev"
ev="$(grep -RhsE '@@|action\(.*omfwd|target=' /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null || echo "(no remote host forwarding found)")"
record "6.1.2.5" "Ensure rsyslog is configured to send logs to a remote log host" "Manual" "$S" "Manual Review" "$ev"
# CIS: no ACTIVE (uncommented) imtcp module/input, advanced or legacy format.
rsy_files=(/etc/rsyslog.conf /etc/rsyslog.d/*.conf)
rsy="$(grep -PHsi -- '^\h*module\(load="?imtcp"?\)|^\h*input\(type="?imtcp"?\b|^\h*\$ModLoad\h+imtcp\b|^\h*\$InputTCPServerRun\b' "${rsy_files[@]}" 2>/dev/null)"
rsy_udp="$(grep -PHsi -- '^\h*module\(load="?imudp"?\)|^\h*input\(type="?imudp"?\b|^\h*\$ModLoad\h+imudp\b|^\h*\$UDPServerRun\b' "${rsy_files[@]}" 2>/dev/null)"
ev="Active imtcp configuration (CIS check):"$'\n'"${rsy:-(none)}"$'\n\n'"Active imudp configuration (informational, not scored by CIS):"$'\n'"${rsy_udp:-(none)}"
if [[ -z "$rsy" ]]; then st="Pass"; else st="Fail"; fi
record "6.1.2.6" "Ensure rsyslog is not configured to receive logs from a remote client" "Automated" "$S" "$st" "$ev"
ev="$(cat /etc/logrotate.conf 2>/dev/null | head -n 40; ls /etc/logrotate.d 2>/dev/null)"
record "6.1.2.7" "Ensure logrotate is configured" "Manual" "$S" "Manual Review" "$ev"
pkg_present "6.1.2.8" "Ensure rsyslog-gnutls is installed" "$S" rsyslog-gnutls
ev="$(grep -RhsE 'gtls|StreamDriver|DefaultNetstreamDriver' /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null)"
if echo "$ev" | grep -qi gtls; then st="Pass"; else st="Fail"; fi
record "6.1.2.9" "Ensure rsyslog forwarding uses gtls" "Automated" "$S" "$st" "${ev:-"(gtls not configured)"}"
ev="$(grep -RhsE 'DefaultNetstreamDriverCAFile|CAFile' /etc/rsyslog.conf /etc/rsyslog.d 2>/dev/null)"
record "6.1.2.10" "Ensure rsyslog CA certificates are configured" "Manual" "$S" "Manual Review" "${ev:-"(no CA file setting found)"}"
ev="$(find /var/log -xdev -type f -printf '%m %u %g %p\n' 2>/dev/null | head -n 80)"
st="Pass"
while IFS= read -r line; do
  mode="${line%% *}"
  python3 - "$mode" <<'PY' || st="Fail"
import sys
m=int(sys.argv[1],8)
# world-writable or world-readable sensitive default: o+w or (often) o+r except known
if m & 0o002: raise SystemExit(1)
sys.exit(0)
PY
done < <(find /var/log -xdev -type f -printf '%m\n' 2>/dev/null | head -n 200)
record "6.1.3.1" "Ensure access to all logfiles has been configured" "Automated" "$S" "$st" "$ev"$'\n'"Sample of /var/log file modes (world-writable files fail)."

S="6.2 System Auditing"
pkg_present "6.2.1.1" "Ensure auditd packages are installed" "$S" auditd
ev="$(unit_state auditd.service)"
if systemctl is-active auditd 2>/dev/null | grep -q active; then st="Pass"; else st="Fail"; fi
record "6.2.1.2" "Ensure auditd service is enabled and active" "Automated" "$S" "$st" "$ev"
ev="cmdline: $(cat /proc/cmdline)"$'\n'"$(grep GRUB_CMDLINE /etc/default/grub 2>/dev/null)"
# CIS checks the persisted boot config: every grub.cfg "linux" line must carry the parameter
glines="$(grub_linux_lines)"
ev+=$'\n\n'"grub.cfg linux lines:"$'\n'"${glines:-(none found under /boot)}"
if [[ -n "$glines" ]] && ! grep -v 'audit=1' <<<"$glines" | grep -q .; then st="Pass"; else st="Fail"; fi
record "6.2.1.3" "Ensure auditing for processes that start prior to auditd is enabled" "Automated" "$S" "$st" "$ev"$'\n'"Expected: audit=1 on every grub.cfg linux line"
if [[ -n "$glines" ]] && ! grep -Pv 'audit_backlog_limit=\d+\b' <<<"$glines" | grep -q .; then st="Pass"; else st="Fail"; fi
record "6.2.1.4" "Ensure audit_backlog_limit is configured" "Automated" "$S" "$st" "$ev"$'\n'"Expected: audit_backlog_limit=<n> on every grub.cfg linux line"
ev="$(grep -E '^(max_log_file|max_log_file_action|space_left_action|admin_space_left_action|disk_full_action)' /etc/audit/auditd.conf 2>/dev/null)"
if grep -Eq '^max_log_file\s*=' /etc/audit/auditd.conf 2>/dev/null; then st="Pass"; else st="Fail"; fi
record "6.2.2.1" "Ensure audit log storage size is configured" "Automated" "$S" "$st" "$ev"
if grep -Eq '^max_log_file_action\s*=\s*keep_logs' /etc/audit/auditd.conf 2>/dev/null; then st="Pass"; else st="Fail"; fi
record "6.2.2.2" "Ensure audit logs are not automatically deleted" "Automated" "$S" "$st" "$ev"
ev+=$'\n'"$(grep -E '^[[:space:]]*disk_error_action' /etc/audit/auditd.conf 2>/dev/null)"
# CIS: disk_full_action = halt|single AND disk_error_action = syslog|single|halt
if grep -Piq '^\h*disk_full_action\h*=\h*(halt|single)\b' /etc/audit/auditd.conf 2>/dev/null && \
   grep -Piq '^\h*disk_error_action\h*=\h*(syslog|single|halt)\b' /etc/audit/auditd.conf 2>/dev/null; then st="Pass"; else st="Fail"; fi
record "6.2.2.3" "Ensure system is disabled when audit logs are full" "Automated" "$S" "$st" "$ev"$'\n'"Expected: disk_full_action halt|single AND disk_error_action syslog|single|halt"
# CIS: space_left_action = email|exec|single|halt AND admin_space_left_action = single|halt
if grep -Piq '^\h*space_left_action\h*=\h*(email|exec|single|halt)\b' /etc/audit/auditd.conf 2>/dev/null && \
   grep -Piq '^\h*admin_space_left_action\h*=\h*(single|halt)\b' /etc/audit/auditd.conf 2>/dev/null; then st="Pass"; else st="Fail"; fi
record "6.2.2.4" "Ensure system warns when audit logs are low on space" "Automated" "$S" "$st" "$ev"$'\n'"Expected: space_left_action email|exec|single|halt AND admin_space_left_action single|halt"

check_audit_rule "6.2.3.1" "Ensure changes to system administration scope (sudoers) is collected" "$S" 'sudoers|key=scope'
check_audit_rule "6.2.3.2" "Ensure actions as another user are always logged" "$S" 'user_emulation|euid!=uid'
check_audit_rule "6.2.3.3" "Ensure events that modify the sudo log file are collected" "$S" 'sudo.log|sudo_log'
check_audit_rule "6.2.3.4" "Ensure events that modify date and time information are collected" "$S" 'adjtimex|settimeofday|time-change'
check_audit_rule "6.2.3.5" "Ensure events that modify sethostname and setdomainname are collected" "$S" 'sethostname|setdomainname'
check_audit_rule "6.2.3.6" "Ensure events that modify /etc/issue and /etc/issue.net are collected" "$S" '/etc/issue'
check_audit_rule "6.2.3.7" "Ensure events that modify /etc/hosts and /etc/hostname are collected" "$S" '/etc/hosts|/etc/hostname'
check_audit_rule "6.2.3.8" "Ensure events that modify /etc/network and /etc/networks are collected" "$S" '/etc/network'
check_audit_rule "6.2.3.9" "Ensure events that modify /etc/netplan are collected" "$S" '/etc/netplan'
check_audit_rule "6.2.3.10" "Ensure use of privileged commands are collected" "$S" 'key=privileged|-k privileged'
check_audit_rule "6.2.3.11" "Ensure events that modify /etc/group information are collected" "$S" '/etc/group'
check_audit_rule "6.2.3.12" "Ensure events that modify /etc/passwd information are collected" "$S" '/etc/passwd'
check_audit_rule "6.2.3.13" "Ensure events that modify /etc/shadow and /etc/gshadow are collected" "$S" '/etc/shadow|/etc/gshadow'
check_audit_rule "6.2.3.14" "Ensure events that modify /etc/security/opasswd are collected" "$S" 'opasswd'
check_audit_rule "6.2.3.15" "Ensure events that modify /etc/nsswitch.conf file are collected" "$S" 'nsswitch'
check_audit_rule "6.2.3.16" "Ensure events that modify /etc/pam.conf and /etc/pam.d/ information are collected" "$S" '/etc/pam'
check_audit_rule "6.2.3.17" "Ensure unsuccessful file access attempts are collected" "$S" 'EACCES|EPERM|key=access|-k access'
check_audit_rule "6.2.3.18" "Ensure discretionary access control permission modification events are collected" "$S" 'chmod|perm_mod'
check_audit_rule "6.2.3.19" "Ensure successful file system mounts are collected" "$S" 'key=mounts|-k mounts|[[:space:]]mount[[:space:]]'
check_audit_rule "6.2.3.20" "Ensure session initiation information is collected" "$S" 'utmp|wtmp|btmp|key=session'
check_audit_rule "6.2.3.21" "Ensure login and logout events are collected" "$S" 'lastlog|faillock|key=logins'
check_audit_rule "6.2.3.22" "Ensure file deletion events by users are collected" "$S" 'unlink|key=delete|-k delete'
check_audit_rule "6.2.3.23" "Ensure events that modify the system's Mandatory Access Controls are collected" "$S" 'apparmor|MAC-policy'
check_audit_rule "6.2.3.24" "Ensure successful and unsuccessful attempts to use the chcon command are collected" "$S" 'chcon'
check_audit_rule "6.2.3.25" "Ensure successful and unsuccessful attempts to use the setfacl command are collected" "$S" 'setfacl'
check_audit_rule "6.2.3.26" "Ensure successful and unsuccessful attempts to use the chacl command are collected" "$S" 'chacl'
check_audit_rule "6.2.3.27" "Ensure successful and unsuccessful attempts to use the usermod command are collected" "$S" 'usermod'
check_audit_rule "6.2.3.28" "Ensure kernel module loading unloading and modification is collected" "$S" 'init_module|kmod|kernel_modules'
ev="$(auditctl -s 2>/dev/null; grep -- '-e 2' /etc/audit/rules.d/* 2>/dev/null)"
if grep -Rqs -- '-e 2' /etc/audit/rules.d 2>/dev/null || auditctl -s 2>/dev/null | grep -q 'enabled 2'; then st="Pass"; else st="Fail"; fi
record "6.2.3.29" "Ensure the audit configuration is immutable" "Automated" "$S" "$st" "$ev"
ev="$(auditctl -l 2>/dev/null | wc -l; echo '--- augenrules ---'; augenrules --check 2>&1 | head -n 20)"
record "6.2.3.30" "Ensure the running and on disk configuration is the same" "Manual" "$S" "Manual Review" "$ev"

S="6.2.4 auditd File Access"
alogdir="$(awk -F= '/^\s*log_file/{gsub(/ /,"",$2); print $2}' /etc/audit/auditd.conf 2>/dev/null | xargs dirname)"
[[ -n "$alogdir" ]] || alogdir=/var/log/audit
check_perm "6.2.4.1" "Ensure the audit log file directory mode is configured" "$S" "$alogdir" 0750 root root
st="Pass"; ev=""
while IFS= read -r f; do
  ev+="$(file_stat "$f")"$'\n'
  mode_ok "$f" "0640" || st="Fail"
done < <(find "$alogdir" -type f 2>/dev/null)
record "6.2.4.2" "Ensure audit log files mode is configured" "Automated" "$S" "$st" "${ev:-"(no audit log files)"}"
st="Pass"; ev=""
while IFS= read -r f; do
  ev+="$(file_stat "$f")"$'\n'
  [[ "$(stat -c '%U' "$f")" == "root" ]] || st="Fail"
done < <(find "$alogdir" -type f 2>/dev/null)
record "6.2.4.3" "Ensure audit log files owner is configured" "Automated" "$S" "$st" "${ev:-"(no files)"}"
st="Pass"; ev=""
while IFS= read -r f; do
  ev+="$(file_stat "$f")"$'\n'
  g="$(stat -c '%G' "$f")"
  [[ "$g" == "root" || "$g" == "adm" ]] || st="Fail"
done < <(find "$alogdir" -type f 2>/dev/null)
record "6.2.4.4" "Ensure audit log files group owner is configured" "Automated" "$S" "$st" "${ev:-"(no files)"}"
st="Pass"; ev=""
while IFS= read -r f; do
  ev+="$(file_stat "$f")"$'\n'
  mode_ok "$f" "0640" || st="Fail"
done < <(find /etc/audit /etc/libaudit.conf -type f 2>/dev/null)
record "6.2.4.5" "Ensure audit configuration files mode is configured" "Automated" "$S" "$st" "$ev"
st="Pass"; ev=""
while IFS= read -r f; do
  ev+="$(file_stat "$f")"$'\n'
  [[ "$(stat -c '%U' "$f")" == "root" ]] || st="Fail"
done < <(find /etc/audit -type f 2>/dev/null)
record "6.2.4.6" "Ensure audit configuration files owner is configured" "Automated" "$S" "$st" "$ev"
st="Pass"; ev=""
while IFS= read -r f; do
  ev+="$(file_stat "$f")"$'\n'
  g="$(stat -c '%G' "$f")"
  [[ "$g" == "root" ]] || st="Fail"
done < <(find /etc/audit -type f 2>/dev/null)
record "6.2.4.7" "Ensure audit configuration files group owner is configured" "Automated" "$S" "$st" "$ev"
st="Pass"; ev=""
for t in /sbin/auditctl /sbin/aureport /sbin/ausearch /sbin/autrace /sbin/augenrules /sbin/auditd; do
  [[ -e "$t" ]] || continue
  ev+="$(file_stat "$t")"$'\n'
  mode_ok "$t" "0755" || st="Fail"
done
record "6.2.4.8" "Ensure audit tools mode is configured" "Automated" "$S" "$st" "$ev"
st="Pass"; ev=""
for t in /sbin/auditctl /sbin/aureport /sbin/ausearch /sbin/autrace /sbin/augenrules /sbin/auditd; do
  [[ -e "$t" ]] || continue
  ev+="$(file_stat "$t")"$'\n'
  [[ "$(stat -c '%U' "$t")" == "root" ]] || st="Fail"
done
record "6.2.4.9" "Ensure audit tools owner is configured" "Automated" "$S" "$st" "$ev"
st="Pass"; ev=""
for t in /sbin/auditctl /sbin/aureport /sbin/ausearch /sbin/autrace /sbin/augenrules /sbin/auditd; do
  [[ -e "$t" ]] || continue
  ev+="$(file_stat "$t")"$'\n'
  [[ "$(stat -c '%G' "$t")" == "root" ]] || st="Fail"
done
record "6.2.4.10" "Ensure audit tools group owner is configured" "Automated" "$S" "$st" "$ev"

S="6.3 Integrity Checking"
pkg_present "6.3.1" "Ensure AIDE is installed" "$S" aide
# CIS: dailyaidecheck.timer enabled AND active; dailyaidecheck.service static or enabled
ai_t_en="$(systemctl is-enabled dailyaidecheck.timer 2>&1 || true)"
ai_t_ac="$(systemctl is-active dailyaidecheck.timer 2>&1 || true)"
ai_s_en="$(systemctl is-enabled dailyaidecheck.service 2>&1 || true)"
ev="dailyaidecheck.timer is-enabled: ${ai_t_en}"$'\n'"dailyaidecheck.timer is-active: ${ai_t_ac}"$'\n'"dailyaidecheck.service is-enabled: ${ai_s_en}"
ev+=$'\n\n'"aide cron entries (informational):"$'\n'"$(grep -Rs aide /etc/cron.d /etc/cron.daily /etc/crontab 2>/dev/null | head -n 20 || true)"
if [[ "$ai_t_en" == "enabled" && "$ai_t_ac" == "active" ]] && [[ "$ai_s_en" == "static" || "$ai_s_en" == "enabled" ]]; then st="Pass"; else st="Fail"; fi
record "6.3.2" "Ensure filesystem integrity is regularly checked" "Automated" "$S" "$st" "$ev"
ev="$(grep -n audit /etc/aide/aide.conf /etc/aide.conf 2>/dev/null | head -n 30)"
record "6.3.3" "Ensure cryptographic mechanisms are used to protect the integrity of audit tools" "Automated" "$S" "$(echo "$ev" | grep -q auditctl && echo Pass || echo Fail)" "$ev"

# =============================================================================
# 7 System Maintenance
# =============================================================================
S="7.1 System file and directory access"
check_perm "7.1.1" "Ensure access to /etc/passwd is configured" "$S" /etc/passwd 0644 root root
check_perm "7.1.2" "Ensure access to /etc/passwd- is configured" "$S" /etc/passwd- 0644 root root
check_perm "7.1.3" "Ensure access to /etc/group is configured" "$S" /etc/group 0644 root root
check_perm "7.1.4" "Ensure access to /etc/group- is configured" "$S" /etc/group- 0644 root root
check_perm "7.1.5" "Ensure access to /etc/shadow is configured" "$S" /etc/shadow 0640 root "root|shadow"
check_perm "7.1.6" "Ensure access to /etc/shadow- is configured" "$S" /etc/shadow- 0640 root "root|shadow"
check_perm "7.1.7" "Ensure access to /etc/gshadow is configured" "$S" /etc/gshadow 0640 root "root|shadow"
check_perm "7.1.8" "Ensure access to /etc/gshadow- is configured" "$S" /etc/gshadow- 0640 root "root|shadow"
check_perm "7.1.9" "Ensure access to /etc/shells is configured" "$S" /etc/shells 0644 root root
if [[ -e /etc/security/opasswd ]]; then
  check_perm "7.1.10" "Ensure access to /etc/security/opasswd is configured" "$S" /etc/security/opasswd 0600 root root
else
  record "7.1.10" "Ensure access to /etc/security/opasswd is configured" "Automated" "$S" "Pass" "/etc/security/opasswd does not exist (acceptable if pwhistory unused on disk)"
fi
ev="$(timeout 45 find / -xdev -type f -perm -0002 2>/dev/null | head -n 50)"
if [[ -z "$ev" ]]; then st="Pass"; else st="Fail"; fi
record "7.1.11" "Ensure world writable files and directories are secured" "Automated" "$S" "$st" "${ev:-"(no world-writable files on local xdev filesystems in sample)"}"$'\n'"World-writable directories should use sticky bit (not listed here)."
ev="$(timeout 45 find / -xdev \( -nouser -o -nogroup \) 2>/dev/null | head -n 50)"
if [[ -z "$ev" ]]; then st="Pass"; else st="Fail"; fi
record "7.1.12" "Ensure no files or directories without an owner and a group exist" "Automated" "$S" "$st" "${ev:-"(none found on xdev sample)"}"
ev="$(timeout 45 find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | head -n 80)"
record "7.1.13" "Ensure SUID and SGID files are reviewed" "Manual" "$S" "Manual Review" "$ev"$'\n'"Review this inventory against the approved SUID/SGID list."

S="7.2 Local User and Group Settings"
ev="$(awk -F: '($2 != "x"){print $1" password field="$2}' /etc/passwd)"
if awk -F: '($2 != "x"){found=1} END{exit !found}' /etc/passwd; then st="Fail"; else st="Pass"; fi
record "7.2.1" "Ensure accounts in /etc/passwd use shadowed passwords" "Automated" "$S" "$st" "${ev:-"(all passwd fields are x)"}"
ev="$(awk -F: '($2 == ""){print $1" has empty password"}' /etc/shadow)"
if awk -F: '($2 == ""){found=1} END{exit !found}' /etc/shadow; then st="Fail"; else st="Pass"; fi
record "7.2.2" "Ensure /etc/shadow password fields are not empty" "Automated" "$S" "$st" "${ev:-"(no empty shadow fields)"}"
ev="$(python3 <<'PY'
import pwd, grp
missing=[]
for u in pwd.getpwall():
    try:
        grp.getgrgid(u.pw_gid)
    except KeyError:
        missing.append(f"{u.pw_name} gid={u.pw_gid}")
print("\n".join(missing) if missing else "(all passwd GIDs exist in group)")
raise SystemExit(1 if missing else 0)
PY
)" && st="Pass" || st="Fail"
record "7.2.3" "Ensure all groups in /etc/passwd exist in /etc/group" "Automated" "$S" "$st" "$ev"
ev="$(awk -F: '($1=="shadow"){print $0}' /etc/group)"$'\n'"$(awk -F: '($4=="42" || $1=="shadow"){print}' /etc/passwd /etc/group 2>/dev/null)"
if awk -F: '($1=="shadow" && $4!=""){found=1} END{exit !found}' /etc/group; then st="Fail"; else st="Pass"; fi
record "7.2.4" "Ensure shadow group is empty" "Automated" "$S" "$st" "$ev"
ev="$(awk -F: '{print $3}' /etc/passwd | sort | uniq -d)"
if [[ -z "$ev" ]]; then st="Pass"; else st="Fail"; fi
record "7.2.5" "Ensure no duplicate UIDs exist" "Automated" "$S" "$st" "${ev:-"(no duplicate UIDs)"}"$'\n'"$(awk -F: '{print $1,$3}' /etc/passwd | head)"
ev="$(awk -F: '{print $3}' /etc/group | sort | uniq -d)"
if [[ -z "$ev" ]]; then st="Pass"; else st="Fail"; fi
record "7.2.6" "Ensure no duplicate GIDs exist" "Automated" "$S" "$st" "${ev:-"(no duplicate GIDs)"}"
ev="$(awk -F: '{print $1}' /etc/passwd | sort | uniq -d)"
if [[ -z "$ev" ]]; then st="Pass"; else st="Fail"; fi
record "7.2.7" "Ensure no duplicate user names exist" "Automated" "$S" "$st" "${ev:-"(no duplicate names)"}"
ev="$(awk -F: '{print $1}' /etc/group | sort | uniq -d)"
if [[ -z "$ev" ]]; then st="Pass"; else st="Fail"; fi
record "7.2.8" "Ensure no duplicate group names exist" "Automated" "$S" "$st" "${ev:-"(no duplicate group names)"}"
# 7.2.9 / 7.2.10 implement the CIS audit scripts. "Interactive user" = /etc/passwd
# entry whose shell is listed in /etc/shells and is not nologin (includes root).
# CIS 7.2.9: home exists, is owned by the user, and is mode 0750 or more restrictive
ev="$(python3 <<'PY'
import os, pwd
shells = {l.strip() for l in open("/etc/shells") if l.strip().startswith("/")
          and os.path.basename(l.strip()) != "nologin"}
users = [u for u in pwd.getpwall() if u.pw_shell in shells]
bad, ok = [], []
for u in users:
    h = u.pw_dir
    if not os.path.isdir(h):
        bad.append(f' - User "{u.pw_name}" home "{h}" does not exist')
        continue
    st = os.stat(h)
    mode = st.st_mode & 0o7777
    try:
        owner = pwd.getpwuid(st.st_uid).pw_name
    except KeyError:
        owner = str(st.st_uid)
    line = f' - User "{u.pw_name}" home "{h}" mode {mode:04o} owner {owner}'
    probs = []
    if owner != u.pw_name:
        probs.append(f"owned by {owner}")
    if mode & 0o027:
        probs.append("mode should be 0750 or more restrictive")
    (bad if probs else ok).append(line + (" -> " + "; ".join(probs) if probs else ""))
print(f"Interactive users checked: {len(users)}")
print("Failures:\n" + ("\n".join(bad) if bad else " (none)"))
print("Correctly set:\n" + ("\n".join(ok[:100]) if ok else " (none)"))
raise SystemExit(1 if bad else 0)
PY
)" && st="Pass" || st="Fail"
record "7.2.9" "Ensure local interactive user home directories are configured" "Automated" "$S" "$st" "$ev"
# CIS 7.2.10: in each interactive user's home (recursive, same filesystem, regular files):
#   no .forward / .rhost(s); .netrc and .bash_history 0600 or stricter; other dot files
#   0644 or stricter; all owned by the user and group-owned by the user's primary group.
ev="$(python3 <<'PY'
import grp, os, pwd, stat
shells = {l.strip() for l in open("/etc/shells") if l.strip().startswith("/")
          and os.path.basename(l.strip()) != "nologin"}
def name_u(uid):
    try: return pwd.getpwuid(uid).pw_name
    except KeyError: return str(uid)
def name_g(gid):
    try: return grp.getgrgid(gid).gr_name
    except KeyError: return str(gid)
fails, warns, nfiles = [], [], 0
for u in pwd.getpwall():
    if u.pw_shell not in shells or not os.path.isdir(u.pw_dir):
        continue
    home, user, group = u.pw_dir, u.pw_name, name_g(u.pw_gid)
    dev = os.lstat(home).st_dev
    for root, dirs, files in os.walk(home, onerror=lambda e: None):
        dirs[:] = [d for d in dirs if os.lstat(os.path.join(root, d)).st_dev == dev]
        for fn in files:
            if not fn.startswith("."):
                continue
            p = os.path.join(root, fn)
            try:
                if not stat.S_ISREG(os.lstat(p).st_mode):
                    continue
                st = os.stat(p)
            except OSError:
                continue
            nfiles += 1
            mode, ow, gr = st.st_mode & 0o7777, name_u(st.st_uid), name_g(st.st_gid)
            def access(mask):
                r = []
                if mode & mask: r.append(f"mode {mode:04o} should be {0o777 & ~mask:04o} or more restrictive")
                if ow != user: r.append(f"owned by {ow} (should be {user})")
                if gr != group: r.append(f"group {gr} (should be {group})")
                return r
            if fn in (".forward", ".rhost", ".rhosts"):
                fails.append(f' - User "{user}": "{p}" exists')
                continue
            if fn == ".netrc":
                r = access(0o177)
                if r: fails.append(f' - User "{user}": "{p}": ' + "; ".join(r))
                else: warns.append(f' - User "{user}": "{p}" exists (verify it is required by site policy)')
                continue
            r = access(0o177 if fn == ".bash_history" else 0o133)
            if r: fails.append(f' - User "{user}": "{p}": ' + "; ".join(r))
print(f"Dot files examined: {nfiles}")
print("Failures:\n" + ("\n".join(fails[:200]) if fails else " (none)"))
if len(fails) > 200: print(f" ... {len(fails) - 200} more")
if warns: print("Warnings:\n" + "\n".join(warns))
raise SystemExit(1 if fails else 0)
PY
)" && st="Pass" || st="Fail"
record "7.2.10" "Ensure local interactive user dot files access is configured" "Automated" "$S" "$st" "$ev"

END_ISO="$(date -Is)"

# -----------------------------------------------------------------------------
# HTML report
# -----------------------------------------------------------------------------
python3 - "$JSONL" "$OUTFILE" <<PY
import json, html, collections, os, sys
from datetime import datetime

jsonl, outfile = sys.argv[1], sys.argv[2]
rows = []
with open(jsonl, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            rows.append(json.loads(line))

counts = collections.Counter(r["status"] for r in rows)
total = len(rows)
scored = counts["Pass"] + counts["Fail"]
pct = (100.0 * counts["Pass"] / scored) if scored else 0.0

def badge(st):
    return {
        "Pass": ("pass", "Pass"),
        "Fail": ("fail", "Fail"),
        "Manual Review": ("manual", "Manual"),
        "Not Applicable": ("na", "N/A"),
    }.get(st, ("manual", st))

sections = []
seen = []
for r in rows:
    if r["section"] not in seen:
        seen.append(r["section"])

host = ${HOSTNAME_FQDN@Q}
osn = ${OS_PRETTY@Q}
kern = ${KERNEL@Q}
arch = ${ARCH@Q}
start = ${START_ISO@Q}
end = ${END_ISO@Q}
bname = ${BENCHMARK@Q}
bver = ${BENCHMARK_VER@Q}
bdate = ${BENCHMARK_DATE@Q}

parts = []
cur = None
for r in rows:
    if r["section"] != cur:
        cur = r["section"]
        parts.append(f'<h2 id="{html.escape(cur)}">{html.escape(cur)}</h2>')
    cls, label = badge(r["status"])
    evid = html.escape(r.get("evidence") or "")
    parts.append(f'''
<article class="rec" data-status="{html.escape(r["status"])}" data-assess="{html.escape(r["assessment"])}">
  <header>
    <span class="id">{html.escape(r["id"])}</span>
    <span class="badge {cls}">{label}</span>
    <span class="assess">{html.escape(r["assessment"])}</span>
    <h3>{html.escape(r["title"])}</h3>
  </header>
  <details open>
    <summary>Evidence</summary>
    <pre>{evid}</pre>
  </details>
</article>''')

nav = "".join(f'<a href="#{html.escape(s)}">{html.escape(s)}</a>' for s in seen)

html_out = f'''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>{html.escape(bname)} {html.escape(bver)} — Compliance Audit</title>
<style>
:root {{
  --bg:#0f172a; --card:#111827; --ink:#e5e7eb; --muted:#94a3b8;
  --pass:#16a34a; --fail:#dc2626; --manual:#d97706; --na:#64748b;
  --line:#1f2937; --accent:#38bdf8;
}}
* {{ box-sizing:border-box; }}
body {{
  margin:0; font-family: "Segoe UI", system-ui, sans-serif;
  background:linear-gradient(180deg,#0b1220,#0f172a 30%);
  color:var(--ink);
}}
header.hero {{
  padding:32px 28px 20px; border-bottom:1px solid var(--line);
  background:#020617;
}}
header.hero h1 {{ margin:0 0 6px; font-size:1.55rem; }}
header.hero p {{ margin:4px 0; color:var(--muted); }}
.meta {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:8px 24px; margin-top:14px; font-size:.92rem; }}
.cards {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr)); gap:12px; padding:20px 28px; }}
.card {{ background:var(--card); border:1px solid var(--line); border-radius:12px; padding:14px 16px; }}
.card .n {{ font-size:1.8rem; font-weight:700; }}
.card span {{ color:var(--muted); font-size:.85rem; }}
.pass .n {{ color:var(--pass); }} .fail .n {{ color:var(--fail); }}
.manual .n {{ color:var(--manual); }} .na .n {{ color:var(--na); }}
.filters {{ padding:0 28px 12px; display:flex; flex-wrap:wrap; gap:8px; }}
.filters button, .filters input {{
  background:#1e293b; color:var(--ink); border:1px solid var(--line);
  border-radius:8px; padding:8px 12px; cursor:pointer;
}}
.filters input {{ min-width:240px; cursor:text; }}
.filters button.active {{ outline:2px solid var(--accent); }}
nav.toc {{ padding:8px 28px 18px; display:flex; flex-wrap:wrap; gap:8px; }}
nav.toc a {{ color:var(--accent); text-decoration:none; font-size:.85rem; background:#1e293b; padding:4px 8px; border-radius:6px; }}
main {{ padding:0 28px 48px; }}
h2 {{ margin-top:28px; border-bottom:1px solid var(--line); padding-bottom:6px; }}
.rec {{ background:var(--card); border:1px solid var(--line); border-radius:12px; margin:12px 0; overflow:hidden; }}
.rec header {{ padding:12px 16px 8px; display:grid; grid-template-columns:auto auto auto 1fr; gap:8px 12px; align-items:center; }}
.rec h3 {{ grid-column:1 / -1; margin:4px 0 0; font-size:1rem; font-weight:600; }}
.id {{ font-family:ui-monospace,Consolas,monospace; color:var(--accent); font-weight:700; }}
.assess {{ color:var(--muted); font-size:.8rem; }}
.badge {{ font-size:.75rem; font-weight:700; padding:3px 8px; border-radius:999px; text-transform:uppercase; }}
.badge.pass {{ background:#14532d; color:#bbf7d0; }}
.badge.fail {{ background:#7f1d1d; color:#fecaca; }}
.badge.manual {{ background:#78350f; color:#fde68a; }}
.badge.na {{ background:#334155; color:#cbd5e1; }}
details {{ border-top:1px solid var(--line); }}
summary {{ padding:8px 16px; cursor:pointer; color:var(--muted); }}
pre {{
  margin:0; padding:12px 16px 16px; white-space:pre-wrap; word-break:break-word;
  font-family:ui-monospace,Consolas,monospace; font-size:.78rem; color:#cbd5e1;
  background:#020617; max-height:320px; overflow:auto;
}}
footer {{ padding:20px 28px 40px; color:var(--muted); font-size:.8rem; }}
@media print {{
  body {{ background:#fff; color:#111; }}
  .filters, nav.toc {{ display:none; }}
  .rec {{ break-inside:avoid; border-color:#ddd; }}
  pre {{ background:#f8fafc; color:#111; max-height:none; }}
}}
</style>
</head>
<body>
<header class="hero">
  <h1>{html.escape(bname)} {html.escape(bver)}</h1>
  <p>Compliance audit with evidence for every recommendation (Automated and Manual).</p>
  <div class="meta">
    <div><strong>Host</strong><br/>{html.escape(host)}</div>
    <div><strong>Operating system</strong><br/>{html.escape(osn)} ({html.escape(arch)})</div>
    <div><strong>Kernel</strong><br/>{html.escape(kern)}</div>
    <div><strong>Benchmark date</strong><br/>{html.escape(bdate)}</div>
    <div><strong>Scan start</strong><br/>{html.escape(start)}</div>
    <div><strong>Scan end</strong><br/>{html.escape(end)}</div>
    <div><strong>Recommendations</strong><br/>{total}</div>
    <div><strong>Scored pass rate</strong><br/>{pct:.1f}% ({counts["Pass"]} / {scored} scored)</div>
  </div>
</header>
<section class="cards">
  <div class="card pass"><div class="n">{counts["Pass"]}</div><span>Pass</span></div>
  <div class="card fail"><div class="n">{counts["Fail"]}</div><span>Fail</span></div>
  <div class="card manual"><div class="n">{counts["Manual Review"]}</div><span>Manual review</span></div>
  <div class="card na"><div class="n">{counts["Not Applicable"]}</div><span>Not applicable</span></div>
  <div class="card"><div class="n">{total}</div><span>Total controls</span></div>
</section>
<div class="filters">
  <input id="q" placeholder="Filter by ID or title..." oninput="applyFilter()"/>
  <button class="active" data-f="all" onclick="setFilter('all', this)">All</button>
  <button data-f="Pass" onclick="setFilter('Pass', this)">Pass</button>
  <button data-f="Fail" onclick="setFilter('Fail', this)">Fail</button>
  <button data-f="Manual Review" onclick="setFilter('Manual Review', this)">Manual</button>
  <button data-f="Not Applicable" onclick="setFilter('Not Applicable', this)">N/A</button>
</div>
<nav class="toc">{nav}</nav>
<main>
{''.join(parts)}
</main>
<footer>
  Generated by cis_ubuntu_24.04_lts_v2.0.0_audit.sh against {html.escape(bname)} {html.escape(bver)}.
  Manual items still require human sign-off even when a Pass/Fail is suggested from collected evidence.
  CIS Benchmarks are the property of the Center for Internet Security; this report is an independent assessment, not a CIS-CAT certified result.
</footer>
<script>
let filter = "all";
function setFilter(v, btn) {{
  filter = v;
  document.querySelectorAll('.filters button').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  applyFilter();
}}
function applyFilter() {{
  const q = document.getElementById('q').value.toLowerCase();
  document.querySelectorAll('.rec').forEach(el => {{
    const st = el.getAttribute('data-status');
    const text = el.innerText.toLowerCase();
    const okF = (filter === 'all' || st === filter);
    const okQ = !q || text.includes(q);
    el.style.display = (okF && okQ) ? '' : 'none';
  }});
}}
</script>
</body>
</html>
'''
os.makedirs(os.path.dirname(os.path.abspath(outfile)) or ".", exist_ok=True)
with open(outfile, "w", encoding="utf-8") as f:
    f.write(html_out)
print(outfile)
print(f"TOTAL={total} PASS={counts['Pass']} FAIL={counts['Fail']} MANUAL={counts['Manual Review']} NA={counts['Not Applicable']}")
PY

# -----------------------------------------------------------------------------
# JSON results (persistent, machine-readable; consumed by governance mapper,
# delta engine and exception handler). Python 3 stdlib only.
# -----------------------------------------------------------------------------
END_EPOCH="$(date +%s)"
python3 - "$JSONL" "$JSON_OUT" "$HOSTNAME_FQDN" "$OS_PRETTY" "$KERNEL" "$ARCH" \
  "$BENCHMARK" "$BENCHMARK_VER" "$BENCHMARK_DATE" "$START_ISO" "$END_ISO" \
  "$START_EPOCH" "$END_EPOCH" "$SCRIPT_PATH" <<'PY'
import collections, hashlib, json, os, sys, tempfile, uuid

(jsonl, out, host, osn, kern, arch, bname, bver, bdate,
 start_iso, end_iso, start_ep, end_ep, script_path) = sys.argv[1:15]

rows = []
with open(jsonl, encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if line:
            rows.append(json.loads(line))

def sha256_of(path):
    try:
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except OSError:
        return None

STATUSES = ["Pass", "Fail", "Manual Review", "Not Applicable"]
ASSESSMENTS = ["Automated", "Manual"]

by_status = collections.OrderedDict((s, 0) for s in STATUSES)
by_assessment = collections.OrderedDict((a, 0) for a in ASSESSMENTS)
by_section = collections.OrderedDict()
for r in rows:
    by_status[r["status"]] = by_status.get(r["status"], 0) + 1
    by_assessment[r["assessment"]] = by_assessment.get(r["assessment"], 0) + 1
    sec = by_section.setdefault(r["section"], collections.OrderedDict(
        [("total", 0)] + [(a, 0) for a in ASSESSMENTS] + [(s, 0) for s in STATUSES]))
    sec["total"] += 1
    sec[r["assessment"]] = sec.get(r["assessment"], 0) + 1
    sec[r["status"]] = sec.get(r["status"], 0) + 1

scored = by_status["Pass"] + by_status["Fail"]
try:
    duration = max(0, int(end_ep) - int(start_ep))
except ValueError:
    duration = None

doc = collections.OrderedDict()
doc["metadata"] = collections.OrderedDict([
    ("schema_version", "1.0"),
    ("run_id", str(uuid.uuid4())),
    ("timestamp", start_iso),
    ("hostname", host),
    ("os", osn),
    ("kernel", kern),
    ("architecture", arch),
    ("benchmark", bname),
    ("benchmark_version", bver),
    ("benchmark_date", bdate),
    ("scan_start", start_iso),
    ("scan_end", end_iso),
    ("script_sha256", sha256_of(script_path)),
    ("duration_seconds", duration),
])
doc["summary"] = collections.OrderedDict([
    ("total", len(rows)),
    ("by_status", by_status),
    ("by_assessment", by_assessment),
    ("by_section", by_section),
    ("scored", scored),
    ("pass_rate_percent", round(100.0 * by_status["Pass"] / scored, 1) if scored else 0.0),
])
doc["controls"] = [
    collections.OrderedDict((k, r.get(k)) for k in
                            ("id", "title", "assessment", "section", "status", "evidence"))
    for r in rows
]

outdir = os.path.dirname(os.path.abspath(out)) or "."
os.makedirs(outdir, exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=outdir, prefix=".cis-results-", suffix=".json")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, out)
except BaseException:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print(out)
PY

echo
echo "HTML report written to: $OUTFILE"
echo "JSON results written to: $JSON_OUT"
echo "Open it in a browser on this machine or copy it off-host."

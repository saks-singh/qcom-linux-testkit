#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Boot time markers for qcom-linux-testkit (performance)
# - Publishes boot-phase TIMESTAMPS and DURATIONS to LAVA as measurements
# - Sources: systemd-analyze (time, blame, critical-chain), the systemd
#   manager's own monotonic timestamp properties, per-unit properties, and the
#   kernel log (dmesg, or journalctl -k when dmesg is unavailable)
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use Boot_Time_Markers.res for gating.
# - This measures the boot that is already over. Nothing here reboots the
#   target; see Boot_Systemd_KPI_Loop for repeated-boot statistics.
# - A marker that this platform does not have is recorded as SKIP, never as 0.
#   Reporting a missing firmware phase as "0 s" would read as an instant
#   firmware rather than as no measurement, and 0 would then pollute any
#   average taken across boards. In particular, firmware and loader times come
#   from UEFI variables: a board that boots without UEFI legitimately has no
#   such figure, which is a gap in the data and not a fast boot.
#
# Timeline
# --------
# dmesg timestamps and systemd's *TimestampMonotonic properties are the SAME
# clock (CLOCK_MONOTONIC, zero at kernel start), so they can be subtracted from
# each other - that is what makes the kernel breakdown below line up with the
# systemd phases. The firmware and loader phases happen BEFORE that zero, so
# systemd reports them as durations only; they have no timestamp on this scale.

SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"

INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
  if [ -f "$SEARCH/init_env" ]; then
    INIT_ENV="$SEARCH/init_env"
    break
  fi
  SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
  echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
  exit 1
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
  # shellcheck disable=SC1090
  . "$INIT_ENV"
  __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_benchmark.sh"

LC_ALL=C
export LC_ALL

TESTNAME="Boot_Time_Markers"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"

# Target whose "reached after" time is the headline userspace figure. Yocto
# images are frequently multi-user.target only, so the default target is also
# measured and reported under its own case id.
TARGET="${TARGET:-graphical.target}"

# systemd-analyze refuses to report until the initial transaction is done.
# Poll rather than guess, so a slow-settling image does not read as "no data".
WAIT_FINISH_SEC="${WAIT_FINISH_SEC:-120}"

# Units whose start timestamp and duration are published. The udev pair and
# sysinit.target are the ones usually under investigation; the rest give the
# surrounding phase boundaries so a regression can be localised.
UNITS="${UNITS:-systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service local-fs.target sysinit.target basic.target multi-user.target graphical.target}"

# Number of slowest units from systemd-analyze blame to publish as
# measurements (the full list is always archived).
BLAME_TOP="${BLAME_TOP:-10}"

COLLECT_JOURNAL="${COLLECT_JOURNAL:-1}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR        output directory (default: $OUT_DIR)
  --target UNIT        headline target (default: $TARGET)
  --wait-finish-sec N  how long to wait for systemd to call the boot finished
                       (default: $WAIT_FINISH_SEC)
  --units "A B C"      units to measure (default: $UNITS)
  --blame-top N        publish the N slowest units from blame (default: $BLAME_TOP)
  --collect-journal 0|1 archive the boot journal (default: $COLLECT_JOURNAL)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --wait-finish-sec) WAIT_FINISH_SEC="$2"; shift 2 ;;
    --units) UNITS="$2"; shift 2 ;;
    --blame-top) BLAME_TOP="$2"; shift 2 ;;
    --collect-journal) COLLECT_JOURNAL="$2"; shift 2 ;;
    *)
      echo "[WARN] Unknown option: $1" >&2
      usage
      echo "$TESTNAME FAIL" > "$test_path/${TESTNAME}.res"
      exit 0
      ;;
  esac
done

case "$WAIT_FINISH_SEC" in ''|*[!0-9]*) WAIT_FINISH_SEC=120 ;; esac
case "$BLAME_TOP" in ''|*[!0-9]*) BLAME_TOP=10 ;; esac

bench_init "$TESTNAME" "$OUT_DIR" "$test_path" || exit 0
bench_log_env

if ! bench_require_cmds awk sed grep tr; then
  bench_skip_exit "core utilities missing"
  exit 0
fi

# ---------------------------------------------------------------- awk helpers

# systemd prints human durations: "1.234s", "567ms", "1min 2.345s", "2h 3min".
# Every parse below needs to turn those into seconds, so the function is shared
# by prepending it to each awk program.
AWK_DUR='
function dur_to_s(s,   n, i, arr, tot, v, u) {
    tot = 0
    n = split(s, arr, /[ \t]+/)
    for (i = 1; i <= n; i++) {
        if (match(arr[i], /^[0-9]+([.][0-9]+)?/)) {
            v = substr(arr[i], RSTART, RLENGTH) + 0
            u = substr(arr[i], RSTART + RLENGTH)
            sub(/[^a-z].*$/, "", u)
            if (u == "us" || u == "\xc2\xb5s") { tot += v / 1000000 }
            else if (u == "ms")                { tot += v / 1000 }
            else if (u == "s" || u == "sec")   { tot += v }
            else if (u == "min")               { tot += v * 60 }
            else if (u == "h")                 { tot += v * 3600 }
            else if (u == "d")                 { tot += v * 86400 }
            else if (u == "w")                 { tot += v * 604800 }
            else if (u == "")                  { tot += v }
        }
    }
    return tot
}
'

# ---------------------------------------------------------------- shell helpers

is_uint() {
  case "${1:-}" in
    ''|*[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# LAVA test case ids are flat identifiers, so unit names have to lose their
# dots and @ signs. systemd-udev-trigger.service -> systemd-udev-trigger-service
# The second tr drops anything else; a backslash in the first set would be an
# unportable trailing escape, and nothing in a unit name needs it.
sanitize_id() {
  printf '%s' "${1:-}" | tr '.@/:' '----' | tr -cd 'A-Za-z0-9_-'
}

us_to_s() {
  awk -v v="${1:-}" 'BEGIN {
    if (v == "" || v !~ /^[0-9]+$/) { exit 1 }
    printf "%.6f\n", v / 1000000
  }' 2>/dev/null
}

# publish_ts <case_id> <value_us> [allow_zero]
#
# allow_zero matters because 0 means two different things: for a unit property
# it means "this never happened", but KernelTimestampMonotonic is 0 by
# definition (it is the origin of the clock).
publish_ts() {
  _id="$1"
  _us="$2"
  _allow_zero="${3:-0}"

  if ! is_uint "$_us"; then
    bench_metric "$_id" "skip"
    return 1
  fi

  if [ "$_us" = "0" ] && [ "$_allow_zero" != "1" ]; then
    bench_metric "$_id" "skip"
    return 1
  fi

  _s="$(us_to_s "$_us")" || {
    bench_metric "$_id" "skip"
    return 1
  }

  bench_metric "$_id" "pass" "$_s" "s"
  return 0
}

# publish_dur_us <case_id> <from_us> <to_us>
publish_dur_us() {
  _id="$1"
  _a="$2"
  _b="$3"

  if ! is_uint "$_a" || ! is_uint "$_b"; then
    bench_metric "$_id" "skip"
    return 1
  fi

  # A unit that never ran leaves one end at 0, and an end-before-start pair
  # means the unit was restarted after boot - neither is a boot duration.
  if [ "$_b" -le "$_a" ]; then
    bench_metric "$_id" "skip"
    return 1
  fi

  _s="$(awk -v a="$_a" -v b="$_b" 'BEGIN { printf "%.6f\n", (b - a) / 1000000 }' 2>/dev/null)"

  if [ -z "$_s" ]; then
    bench_metric "$_id" "skip"
    return 1
  fi

  bench_metric "$_id" "pass" "$_s" "s"
  return 0
}

# publish_seconds <case_id> <value_seconds>
publish_seconds() {
  _id="$1"
  _v="$2"

  if [ -n "$_v" ] && bench_is_number "$_v"; then
    bench_metric "$_id" "pass" "$_v" "s"
    return 0
  fi

  bench_metric "$_id" "skip"
  return 1
}

sd_manager_prop() {
  systemctl show -p "$1" 2>/dev/null |
    awk -F= -v k="$1" '$1 == k { print $2; exit }' 2>/dev/null
}

sd_unit_prop() {
  systemctl show -p "$2" "$1" 2>/dev/null |
    awk -F= -v k="$2" '$1 == k { print $2; exit }' 2>/dev/null
}

# ---------------------------------------------------------------- collect

HAVE_SYSTEMCTL=0
HAVE_ANALYZE=0
command -v systemctl >/dev/null 2>&1 && HAVE_SYSTEMCTL=1
command -v systemd-analyze >/dev/null 2>&1 && HAVE_ANALYZE=1

ATIME="$OUT_DIR/systemd-analyze-time.txt"
ABLAME="$OUT_DIR/systemd-analyze-blame.txt"
ACHAIN="$OUT_DIR/systemd-analyze-critical-chain.txt"
KLOG="$OUT_DIR/kernel-log.txt"
PROPS="$OUT_DIR/manager-properties.txt"

BOOT_FINISHED=0

if [ "$HAVE_ANALYZE" = "1" ]; then
  # Wait for the initial transaction to drain. Until it does, systemd-analyze
  # answers "Bootup is not yet finished" and every phase would read as absent.
  waited=0
  while :; do
    out="$(systemd-analyze time 2>&1 || true)"

    case "$out" in
      *"not yet finished"*)
        if [ "$waited" -ge "$WAIT_FINISH_SEC" ]; then
          log_warn "$TESTNAME: boot still not finished after ${waited}s; phase data will be partial"
          break
        fi
        [ "$waited" = "0" ] && log_info "$TESTNAME: waiting for systemd to finish the boot transaction"
        sleep 2
        waited=$((waited + 2))
        ;;
      *)
        BOOT_FINISHED=1
        break
        ;;
    esac
  done

  systemd-analyze time > "$ATIME" 2>&1 || true
  systemd-analyze blame > "$ABLAME" 2>&1 || true
  systemd-analyze critical-chain "$TARGET" > "$ACHAIN" 2>&1 ||
    systemd-analyze critical-chain > "$ACHAIN" 2>&1 || true

  log_info "$TESTNAME: $(head -1 "$ATIME" 2>/dev/null || echo 'no systemd-analyze time output')"
else
  log_warn "$TESTNAME: systemd-analyze not present; phase durations unavailable"
  : > "$ATIME"
  : > "$ABLAME"
fi

# The kernel log gives the in-kernel markers. dmesg needs CONFIG_PRINTK_TIME
# for the bracketed timestamps and may be restricted by kernel.dmesg_restrict,
# so fall back to the journal's own kernel stream, which prints the same
# monotonic clock with -o short-monotonic.
if dmesg > "$KLOG" 2>/dev/null && [ -s "$KLOG" ]; then
  log_info "$TESTNAME: kernel log from dmesg"
elif command -v journalctl >/dev/null 2>&1 &&
     journalctl -k -b -o short-monotonic > "$KLOG" 2>/dev/null && [ -s "$KLOG" ]; then
  log_info "$TESTNAME: kernel log from journalctl -k (dmesg unavailable)"
else
  log_warn "$TESTNAME: no readable kernel log; kernel-phase markers will be skipped"
  : > "$KLOG"
fi

if [ "$COLLECT_JOURNAL" = "1" ] && command -v journalctl >/dev/null 2>&1; then
  journalctl -b -o short-monotonic > "$OUT_DIR/journal-boot.txt" 2>&1 || true
  journalctl -b -p err..alert > "$OUT_DIR/journal-errors.txt" 2>&1 || true
fi

if [ "$HAVE_SYSTEMCTL" = "1" ]; then
  systemctl show > "$PROPS" 2>&1 || true
  systemctl list-units --type=target --all > "$OUT_DIR/targets.txt" 2>&1 || true
  DEFAULT_TARGET="$(systemctl get-default 2>/dev/null || true)"
else
  : > "$PROPS"
  DEFAULT_TARGET=""
fi

[ -n "$DEFAULT_TARGET" ] && log_info "$TESTNAME: default target is $DEFAULT_TARGET"

if [ "$HAVE_SYSTEMCTL" != "1" ] && [ ! -s "$KLOG" ]; then
  bench_skip_exit "neither systemctl nor a readable kernel log is available"
  exit 0
fi

# ------------------------------------------------- phase durations (analyze)

analyze_component_s() {
  [ -s "$ATIME" ] || return 1

  awk -v want="$1" "$AWK_DUR"'
    /Startup finished in/ {
        line = $0
        sub(/^.*Startup finished in[ \t]*/, "", line)

        # "A (firmware) + B (loader) + C (kernel) + D (userspace) = TOTAL"
        n = split(line, parts, / \+ /)
        for (i = 1; i <= n; i++) {
            p = parts[i]
            if (match(p, /\([a-z]+\)/)) {
                lbl = substr(p, RSTART + 1, RLENGTH - 2)
                val = substr(p, 1, RSTART - 1)
                if (lbl == want) { printf "%.6f\n", dur_to_s(val); exit }
            }
        }
    }
  ' "$ATIME" 2>/dev/null
}

analyze_total_s() {
  [ -s "$ATIME" ] || return 1

  awk "$AWK_DUR"'
    /Startup finished in/ {
        if (match($0, /=[ \t]*[^=]+$/)) {
            printf "%.6f\n", dur_to_s(substr($0, RSTART + 1))
            exit
        }
    }
  ' "$ATIME" 2>/dev/null
}

analyze_target_reached_s() {
  [ -s "$ATIME" ] || return 1

  awk -v t="$1" "$AWK_DUR"'
    index($0, t " reached after") == 1 {
        line = $0
        sub(/^.*reached after[ \t]*/, "", line)
        sub(/[ \t]+in[ \t]+userspace.*$/, "", line)
        printf "%.6f\n", dur_to_s(line)
        exit
    }
  ' "$ATIME" 2>/dev/null
}

blame_duration_s() {
  [ -s "$ABLAME" ] || return 1

  awk -v u="$1" "$AWK_DUR"'
    {
        unit = $NF
        if (unit != u) { next }
        # everything before the unit name is the duration ("1min 2.345s")
        dur = ""
        for (i = 1; i < NF; i++) { dur = dur $i " " }
        printf "%.6f\n", dur_to_s(dur)
        exit
    }
  ' "$ABLAME" 2>/dev/null
}

log_info "$TESTNAME: --- boot phase durations ---"

for comp in firmware loader kernel initrd userspace; do
  publish_seconds "boot-phase-${comp}-duration" "$(analyze_component_s "$comp" || true)" || true
done

publish_seconds "boot-total-duration" "$(analyze_total_s || true)" || true

# ------------------------------------------------- manager timestamps

log_info "$TESTNAME: --- systemd manager timestamps ---"

KERNEL_TS_US=""
INITRD_TS_US=""
USERSPACE_TS_US=""
FINISH_TS_US=""
UNITS_LOAD_START_US=""
UNITS_LOAD_FINISH_US=""
GEN_START_US=""
GEN_FINISH_US=""
SEC_START_US=""
SEC_FINISH_US=""

if [ "$HAVE_SYSTEMCTL" = "1" ]; then
  KERNEL_TS_US="$(sd_manager_prop KernelTimestampMonotonic)"
  INITRD_TS_US="$(sd_manager_prop InitRDTimestampMonotonic)"
  USERSPACE_TS_US="$(sd_manager_prop UserspaceTimestampMonotonic)"
  FINISH_TS_US="$(sd_manager_prop FinishTimestampMonotonic)"
  UNITS_LOAD_START_US="$(sd_manager_prop UnitsLoadStartTimestampMonotonic)"
  UNITS_LOAD_FINISH_US="$(sd_manager_prop UnitsLoadFinishTimestampMonotonic)"
  GEN_START_US="$(sd_manager_prop GeneratorsStartTimestampMonotonic)"
  GEN_FINISH_US="$(sd_manager_prop GeneratorsFinishTimestampMonotonic)"
  SEC_START_US="$(sd_manager_prop SecurityStartTimestampMonotonic)"
  SEC_FINISH_US="$(sd_manager_prop SecurityFinishTimestampMonotonic)"
fi

# Zero is the real value here: it is where CLOCK_MONOTONIC starts.
publish_ts "boot-kernel-start-timestamp" "$KERNEL_TS_US" 1 || true
publish_ts "boot-initrd-start-timestamp" "$INITRD_TS_US" || true
publish_ts "boot-userspace-start-timestamp" "$USERSPACE_TS_US" || true
publish_ts "boot-finish-timestamp" "$FINISH_TS_US" || true

# "systemd start and completion of unit files loading": systemd records exactly
# this pair, so publish both ends and the span between them rather than only
# the span - a shift in when loading starts and a change in how long it takes
# have different causes.
publish_ts "boot-units-load-start-timestamp" "$UNITS_LOAD_START_US" || true
publish_ts "boot-units-load-finish-timestamp" "$UNITS_LOAD_FINISH_US" || true
publish_dur_us "boot-units-load-duration" "$UNITS_LOAD_START_US" "$UNITS_LOAD_FINISH_US" || true

publish_ts "boot-generators-start-timestamp" "$GEN_START_US" || true
publish_ts "boot-generators-finish-timestamp" "$GEN_FINISH_US" || true
publish_dur_us "boot-generators-duration" "$GEN_START_US" "$GEN_FINISH_US" || true

publish_ts "boot-security-start-timestamp" "$SEC_START_US" || true
publish_ts "boot-security-finish-timestamp" "$SEC_FINISH_US" || true
publish_dur_us "boot-security-duration" "$SEC_START_US" "$SEC_FINISH_US" || true

# Userspace span measured from the manager's own clock, independent of
# systemd-analyze's phrasing.
publish_dur_us "boot-userspace-to-finish-duration" "$USERSPACE_TS_US" "$FINISH_TS_US" || true

# ------------------------------------------------- kernel breakdown (dmesg)

log_info "$TESTNAME: --- kernel phase markers ---"

# First kernel-log line matching an ERE, as monotonic seconds. Both dmesg and
# journalctl -o short-monotonic prefix "[   12.345678]".
klog_first_ts() {
  [ -s "$KLOG" ] || return 1

  awk -v pat="$1" '
    {
        if (match($0, /^\[[ \t]*[0-9]+\.[0-9]+\]/)) {
            ts = substr($0, RSTART + 1, RLENGTH - 2)
            gsub(/[ \t]/, "", ts)
            if ($0 ~ pat) { print ts; exit }
        }
    }
  ' "$KLOG" 2>/dev/null
}

if [ -s "$KLOG" ] && [ -z "$(klog_first_ts '.')" ]; then
  log_warn "$TESTNAME: kernel log has no timestamps (CONFIG_PRINTK_TIME off?); kernel markers will be skipped"
fi

# The rootfs mount is announced differently depending on the filesystem and on
# whether an initramfs was involved, so accept either spelling and take the
# first - which is the root mount, later ones being /boot and friends.
#
# Keep these patterns free of parentheses. They are passed into awk with -v and
# used as DYNAMIC regexes, which costs one level of escaping: a "\(" here
# reaches awk as a bare "(" and aborts the whole program with "unbalanced (",
# silently yielding no marker at all.
ROOTFS_TS="$(klog_first_ts 'VFS: Mounted root|mounted filesystem' || true)"

# "/init as a process": the kernel logs the handover to PID 1 by name, as
# "Run /sbin/init as init process".
INIT_TS="$(klog_first_ts 'as init process' || true)"

FREEING_TS="$(klog_first_ts 'Freeing unused kernel memory' || true)"
SMP_TS="$(klog_first_ts 'smp: Brought up|Brought up .* CPUs' || true)"
publish_seconds "boot-kernel-smp-brought-up-timestamp" "$SMP_TS" || true
publish_seconds "boot-kernel-rootfs-mounted-timestamp" "$ROOTFS_TS" || true
publish_seconds "boot-kernel-freeing-unused-memory-timestamp" "$FREEING_TS" || true
publish_seconds "boot-kernel-init-process-timestamp" "$INIT_TS" || true

# Derived kernel spans. Computed in awk because these are decimal seconds.
dur_seconds() {
  awk -v a="${1:-}" -v b="${2:-}" 'BEGIN {
    if (a == "" || b == "") { exit 1 }
    if (a !~ /^[0-9.]+$/ || b !~ /^[0-9.]+$/) { exit 1 }
    if (b + 0 <= a + 0) { exit 1 }
    printf "%.6f\n", (b + 0) - (a + 0)
  }' 2>/dev/null
}

publish_seconds "boot-kernel-rootfs-mounted-to-init-duration" \
  "$(dur_seconds "$ROOTFS_TS" "$INIT_TS" || true)" || true

# PID 1 exists at INIT_TS and systemd records UserspaceTimestampMonotonic when
# it starts up; the gap is the pre-systemd part of userspace (initramfs work,
# or just exec overhead when there is none).
if [ -n "$INIT_TS" ] && is_uint "$USERSPACE_TS_US"; then
  USERSPACE_TS_S="$(us_to_s "$USERSPACE_TS_US" || true)"
  publish_seconds "boot-init-to-systemd-duration" \
    "$(dur_seconds "$INIT_TS" "$USERSPACE_TS_S" || true)" || true
else
  bench_metric "boot-init-to-systemd-duration" "skip"
fi

# ------------------------------------------------- per-unit markers

log_info "$TESTNAME: --- per-unit timestamps and durations ---"

if [ "$HAVE_SYSTEMCTL" = "1" ]; then
  for u in $UNITS; do
    id="boot-unit-$(sanitize_id "$u")"

    load_state="$(sd_unit_prop "$u" LoadState)"

    if [ -z "$load_state" ] || [ "$load_state" = "not-found" ]; then
      # Not an error: images differ in which targets and udev helpers exist.
      # systemd-udev-settle.service in particular is deprecated and absent on
      # many current images.
      log_info "$TESTNAME: unit $u not present on this image (LoadState=${load_state:-unknown})"
      bench_metric "${id}-start-timestamp" "skip"
      bench_metric "${id}-active-timestamp" "skip"
      bench_metric "${id}-startup-duration" "skip"
      continue
    fi

    # InactiveExit = the job started; ActiveEnter = it reached active;
    # InactiveEnter = it went away again, which is how a Type=oneshot unit
    # such as systemd-udev-trigger.service finishes.
    start_us="$(sd_unit_prop "$u" InactiveExitTimestampMonotonic)"
    active_us="$(sd_unit_prop "$u" ActiveEnterTimestampMonotonic)"
    inactive_us="$(sd_unit_prop "$u" InactiveEnterTimestampMonotonic)"

    publish_ts "${id}-start-timestamp" "$start_us" || true
    publish_ts "${id}-active-timestamp" "$active_us" || true
    publish_dur_us "${id}-startup-duration" "$start_us" "$active_us" || true

    # Only meaningful for units that completed and left. For a long-running
    # service this would be a shutdown, not a boot measurement, so it is
    # published only when it falls inside the boot window.
    if is_uint "$inactive_us" && is_uint "$active_us" &&
       [ "$inactive_us" -gt "$active_us" ]; then
      publish_ts "${id}-finish-timestamp" "$inactive_us" || true
      publish_dur_us "${id}-run-duration" "$start_us" "$inactive_us" || true
    fi

    # systemd-analyze blame's own figure for the same unit. Kept as a separate
    # case id rather than reconciled: blame measures what systemd attributes to
    # the unit, which for a oneshot is its whole run and for a service with
    # Type=notify ends at the notification. Where the two disagree, the
    # difference is the interesting part.
    b="$(blame_duration_s "$u" || true)"
    if [ -n "$b" ]; then
      publish_seconds "${id}-blame-duration" "$b" || true
    fi
  done
else
  log_warn "$TESTNAME: systemctl unavailable; per-unit markers skipped"
fi

# ------------------------------------------------- targets reached

log_info "$TESTNAME: --- targets ---"

t_reached="$(analyze_target_reached_s "$TARGET" || true)"

if [ -n "$t_reached" ]; then
  publish_seconds "boot-target-$(sanitize_id "$TARGET")-reached-after" "$t_reached" || true
else
  # systemd-analyze only volunteers the default target. For any other target,
  # its ActiveEnterTimestamp is the same information.
  if [ "$HAVE_SYSTEMCTL" = "1" ]; then
    ae_us="$(sd_unit_prop "$TARGET" ActiveEnterTimestampMonotonic)"

    if is_uint "$ae_us" && [ "$ae_us" -gt 0 ] && is_uint "$USERSPACE_TS_US"; then
      log_info "$TESTNAME: $TARGET not in systemd-analyze output; using its ActiveEnterTimestamp"
      publish_dur_us "boot-target-$(sanitize_id "$TARGET")-reached-after" \
        "$USERSPACE_TS_US" "$ae_us" || true
    else
      log_warn "$TESTNAME: $TARGET was not reached on this boot (default is ${DEFAULT_TARGET:-unknown})"
      bench_metric "boot-target-$(sanitize_id "$TARGET")-reached-after" "skip"
    fi
  fi
fi

if [ -n "$DEFAULT_TARGET" ] && [ "$DEFAULT_TARGET" != "$TARGET" ]; then
  d_reached="$(analyze_target_reached_s "$DEFAULT_TARGET" || true)"
  publish_seconds "boot-default-target-reached-after" "$d_reached" || true
fi

# ------------------------------------------------- slowest units

if [ "$BLAME_TOP" -gt 0 ] && [ -s "$ABLAME" ]; then
  log_info "$TESTNAME: --- $BLAME_TOP slowest units ---"

  rank=0
  # Only unit-looking lines; blame also prints notes on some versions.
  while read -r line; do
    [ -n "$line" ] || continue

    unit="$(printf '%s' "$line" | awk '{ print $NF }')"
    case "$unit" in
      *.service|*.target|*.mount|*.socket|*.timer|*.path|*.swap|*.device) ;;
      *) continue ;;
    esac

    rank=$((rank + 1))
    [ "$rank" -le "$BLAME_TOP" ] || break

    d="$(blame_duration_s "$unit" || true)"
    publish_seconds "boot-blame-$(sanitize_id "$unit")-duration" "$d" || true
  done < "$ABLAME"
fi

# ------------------------------------------------- summary

summary="$OUT_DIR/summary.txt"
{
  echo "# $TESTNAME summary (lower is better for every figure)"
  echo "boot finished per systemd-analyze : $BOOT_FINISHED"
  echo "headline target                   : $TARGET"
  echo "default target                    : ${DEFAULT_TARGET:-unknown}"
  echo "systemd-analyze available          : $HAVE_ANALYZE"
  echo
  echo "# systemd-analyze time"
  head -5 "$ATIME" 2>/dev/null || echo "(none)"
  echo
  echo "# kernel markers (monotonic seconds from kernel start)"
  echo "smp brought up         : ${SMP_TS:-unavailable}"
  echo "rootfs mounted         : ${ROOTFS_TS:-unavailable}"
  echo "unused memory freed    : ${FREEING_TS:-unavailable}"
  echo "init process started   : ${INIT_TS:-unavailable}"
  echo
  echo "# note: firmware and loader durations come from UEFI variables. A board"
  echo "# that does not boot through UEFI has no such figure, and those cases"
  echo "# are reported SKIP rather than 0 - absent data, not a fast firmware."
  echo
  echo "# note: dmesg timestamps and systemd's *TimestampMonotonic properties"
  echo "# share one clock (CLOCK_MONOTONIC, zero at kernel start), which is why"
  echo "# the kernel markers above can be differenced against the systemd ones."
} > "$summary"

log_info "$TESTNAME: summary written to $summary"
cat "$summary" 2>/dev/null || true

bench_finish
exit 0

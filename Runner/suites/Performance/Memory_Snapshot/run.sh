#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Device + memory snapshot collector for qcom-linux-testkit (performance)
#
# This is the deterministic, device-side half of the qcom-perf-skills
# memory-analysis skill (memory-skills/skills/memory-analysis). That skill is a
# HOST-side orchestrator: it reaches a device over ADB or SSH, reads a fixed set
# of read-only kernel files, normalises them, and only then runs the analysis
# and report stages. The reading stage is pure shell-equivalent work - every
# device command it issues is a cat/ls/uname/getprop - so it reproduces exactly
# here, inside LAVA, with no host, no adbd and no DUT networking.
#
# What this suite does
# --------------------
# 1. Identifies the device (serial, model, kernel, SoC id) and logs it.
# 2. Copies each source file into $OUT_DIR/raw/ so a figure can be re-derived
#    later, or diffed against another build, without another board booking.
# 3. Publishes the counters worth trending to LAVA as measurements.
# 4. Writes $OUT_DIR/snapshot.json conforming to the skill's own contract,
#    MemorySnapshot schema_version 1.0.0
#    (memory-skills/common/schema/memory-snapshot.schema.json): required keys
#    schema_version, snapshot_id, timestamp, device, dump_dir, sources; each
#    source an object with a required "available" boolean plus "path" and
#    "parsed". That makes the artifact consumable by the skill's OFFLINE
#    comparison, which needs two snapshots and no device at all - so a baseline
#    captured by one LAVA job can be compared against a later one in CI.
#
# What it deliberately does NOT do
# --------------------------------
# - It does not run the skill's anomaly/RCA or HTML report stages. Those are
#   non-deterministic and host-side; this suite stops where determinism does.
# - It does not reimplement the skill's full per-source parsers. "parsed" holds
#   the headline numbers this suite also publishes, which is what the contract
#   needs (the schema leaves "parsed" an open object); the raw file is archived
#   beside it so a richer parse never requires another run.
# - It allocates nothing, frees nothing, writes nothing outside $OUT_DIR, and
#   starts and stops no service. Every source is a read.
#
# Notes
# -----
# - Always exits 0 (LAVA-friendly). Use Memory_Snapshot.res for gating.
# - Run it EARLY, and run it twice if you are bracketing a workload: pass
#   --label baseline before and --label after_test afterwards. Cached, dma-buf
#   and PSS all describe whatever last ran.
# - A missing source is a SKIP for its cases and "available": false in the
#   JSON. It is never reported as 0 - a kernel without CONFIG_CMA and a kernel
#   with an empty CMA region are different findings.
# - Process cases are keyed on the process NAME with PSS summed across all
#   instances, never on a PID. A PID-keyed case id changes every boot, which
#   makes the trend useless and the case set unbounded.

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

TESTNAME="Memory_Snapshot"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"

# Free-text tag recorded as "label" in the JSON. The skill's comparison stage
# uses it to say which snapshot is which; "baseline" / "after_test" is the
# convention it documents.
LABEL="${LABEL:-baseline}"

# Per-process PSS. Walking every /proc/<pid>/smaps_rollup is cheap but it is
# still a few hundred reads, so it can be turned off.
COLLECT_PSS="${COLLECT_PSS:-1}"
PSS_TOP="${PSS_TOP:-10}"

# debugfs sources (dma-buf, CMA, KGSL). Absent or unmounted is a SKIP.
COLLECT_DEBUGFS="${COLLECT_DEBUGFS:-1}"

# Archive the kernel ring buffer alongside the counters. Published as no
# measurement; it is there so a carveout or OOM message can be read later.
COLLECT_DMESG="${COLLECT_DMESG:-1}"

# Additional /proc/meminfo field names to publish, space separated, spelled
# exactly as in the file.
EXTRA_MEMINFO_FIELDS="${EXTRA_MEMINFO_FIELDS:-}"

# Delay before collecting. Worth raising when this runs straight after boot,
# while services are still settling.
SETTLE_SECS="${SETTLE_SECS:-0}"

# The contract this suite writes. Not a flag: changing it would claim
# conformance to a schema the file does not match.
SCHEMA_VERSION="1.0.0"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR               output directory (default: $OUT_DIR)
  --label TEXT                snapshot label, e.g. baseline / after_test (default: $LABEL)
  --collect-pss 0|1           walk /proc/*/smaps_rollup for PSS (default: $COLLECT_PSS)
  --pss-top N                 publish the N largest processes by PSS (default: $PSS_TOP)
  --collect-debugfs 0|1       read dma-buf, CMA and KGSL under debugfs (default: $COLLECT_DEBUGFS)
  --collect-dmesg 0|1         archive the kernel ring buffer (default: $COLLECT_DMESG)
  --extra-meminfo-fields "A B"  additional /proc/meminfo fields to publish
  --settle-secs N             delay before collecting (default: $SETTLE_SECS)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --collect-pss) COLLECT_PSS="$2"; shift 2 ;;
    --pss-top) PSS_TOP="$2"; shift 2 ;;
    --collect-debugfs) COLLECT_DEBUGFS="$2"; shift 2 ;;
    --collect-dmesg) COLLECT_DMESG="$2"; shift 2 ;;
    --extra-meminfo-fields) EXTRA_MEMINFO_FIELDS="$2"; shift 2 ;;
    --settle-secs) SETTLE_SECS="$2"; shift 2 ;;
    *)
      echo "[WARN] Unknown option: $1" >&2
      usage
      echo "$TESTNAME FAIL" > "$test_path/${TESTNAME}.res"
      exit 0
      ;;
  esac
done

case "$PSS_TOP" in ''|*[!0-9]*) PSS_TOP=10 ;; esac
case "$SETTLE_SECS" in ''|*[!0-9]*) SETTLE_SECS=0 ;; esac
case "$COLLECT_PSS" in 0|1) ;; *) COLLECT_PSS=1 ;; esac
case "$COLLECT_DEBUGFS" in 0|1) ;; *) COLLECT_DEBUGFS=1 ;; esac
case "$COLLECT_DMESG" in 0|1) ;; *) COLLECT_DMESG=1 ;; esac
[ -n "$LABEL" ] || LABEL="baseline"

bench_init "$TESTNAME" "$OUT_DIR" "$test_path" || exit 0
bench_log_env

if ! bench_require_cmds awk; then
  bench_skip_exit "awk missing"
  exit 0
fi

RAW_DIR="$OUT_DIR/raw"
PARSED_DIR="$OUT_DIR/parsed"
AVAIL_DIR="$OUT_DIR/avail"
mkdir -p "$RAW_DIR" "$PARSED_DIR" "$AVAIL_DIR" 2>/dev/null || true

ERRORS="$OUT_DIR/collection-errors.tsv"
SNAPSHOT="$OUT_DIR/snapshot.json"
SUMMARY="$OUT_DIR/summary.txt"
: > "$ERRORS"

# ---------------------------------------------------------------- helpers

# sanitize_id <text> - a LAVA-safe case id fragment
sanitize_id() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    tr -c 'a-z0-9_-' '-' |
    sed 's/--*/-/g; s/^-//; s/-$//'
}

# read_sysfs_line <path> - first line, NULs stripped (device-tree strings are
# NUL-terminated, and a NUL in a LAVA signal or in JSON is not recoverable)
read_sysfs_line() {
  [ -r "$1" ] || return 1
  tr -d '\000' < "$1" 2>/dev/null | sed -n '1p'
}

# json_escape <text>
json_escape() {
  printf '%s' "$1" |
    tr -d '\000' |
    sed 's/\\/\\\\/g; s/"/\\"/g' |
    tr '\t\r' '  '
}

# record_error <source> <message> - becomes an entry in collection_errors[]
record_error() {
  printf '%s\t%s\n' "$1" "$2" >> "$ERRORS"
  log_warn "$TESTNAME: $1: $2"
}

# src_mark <key> <available 0|1> <path>
src_mark() {
  printf '%s\t%s\n' "$2" "$3" > "$AVAIL_DIR/$1"
}

# parsed_add <key> <name> <value> - one entry in that source's "parsed" object
parsed_add() {
  [ -n "$3" ] || return 0
  printf '%s\t%s\n' "$2" "$3" >> "$PARSED_DIR/$1.kv"
}

# archive <key> <path> - copy a readable source into raw/, mark availability
#
# Returns 0 when the file was archived with content. /proc files report size 0,
# so emptiness is judged on the copy, not on the original.
archive() {
  _key=$1
  _path=$2
  _dest="$RAW_DIR/$_key.txt"

  if [ ! -e "$_path" ]; then
    src_mark "$_key" 0 "$_path"
    record_error "$_key" "not present: $_path"
    return 1
  fi

  if [ ! -r "$_path" ]; then
    src_mark "$_key" 0 "$_path"
    record_error "$_key" "not readable: $_path"
    return 1
  fi

  if ! cat "$_path" > "$_dest" 2>/dev/null || [ ! -s "$_dest" ]; then
    src_mark "$_key" 0 "$_path"
    record_error "$_key" "read returned nothing: $_path"
    rm -f "$_dest" 2>/dev/null || true
    return 1
  fi

  src_mark "$_key" 1 "$_path"
  return 0
}

# meminfo_field <file> <FieldName>
#
# Anchored on the field name WITH its colon, which is what keeps Cached from
# also matching SwapCached - a different counter.
meminfo_field() {
  awk -v k="$2:" '$1 == k { print $2; exit }' "$1" 2>/dev/null
}

# vmstat_field <file> <name>
vmstat_field() {
  awk -v k="$2" '$1 == k { print $2; exit }' "$1" 2>/dev/null
}

# publish <case_id> <value> [units] - pass with a measurement, or SKIP
#
# The single rule this suite follows everywhere: a value that could not be read
# is a SKIP, not a zero.
publish() {
  if [ -n "$2" ] && bench_is_number "$2"; then
    bench_metric "$1" "pass" "$2" "$3"
    return 0
  fi
  bench_metric "$1" "skip"
  return 1
}

# gen_uuid - a RFC 4122 v4 UUID, as the schema's snapshot_id requires
gen_uuid() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    _u="$(tr -d '\000' < /proc/sys/kernel/random/uuid 2>/dev/null | sed -n '1p')"
    if [ -n "$_u" ]; then
      printf '%s' "$_u"
      return 0
    fi
  fi

  # Fallback: 16 random bytes with the version and variant nibbles forced, so
  # the result is a valid v4 and not merely UUID-shaped.
  if [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
    od -An -tx1 -N16 /dev/urandom 2>/dev/null | awk '
      { for (i = 1; i <= NF; i++) { b[++n] = $i } }
      END {
          if (n < 16) { exit 1 }
          hex = "0123456789abcdef"
          b[7] = "4" substr(b[7], 2)
          v = index(hex, substr(b[9], 1, 1)) - 1
          if (v < 0) { v = 0 }
          v = 8 + (v % 4)
          b[9] = substr(hex, v + 1, 1) substr(b[9], 2)
          s = ""
          for (i = 1; i <= 16; i++) {
              s = s b[i]
              if (i == 4 || i == 6 || i == 8 || i == 10) { s = s "-" }
          }
          print s
      }'
    return $?
  fi

  return 1
}

# ---------------------------------------------------------------- settle

if [ "$SETTLE_SECS" -gt 0 ] 2>/dev/null; then
  log_info "$TESTNAME: settling for ${SETTLE_SECS}s before collecting"
  sleep "$SETTLE_SECS"
fi

SNAPSHOT_ID="$(gen_uuid || true)"
TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
[ -n "$TIMESTAMP" ] || TIMESTAMP="1970-01-01T00:00:00Z"

# ---------------------------------------------------------------- device

log_info "$TESTNAME: --- device ---"

DEV_SERIAL="$(read_sysfs_line /sys/devices/soc0/serial_num || true)"
if [ -z "$DEV_SERIAL" ]; then
  DEV_SERIAL="$(read_sysfs_line /etc/machine-id || true)"
fi
if [ -z "$DEV_SERIAL" ] && command -v hostname >/dev/null 2>&1; then
  DEV_SERIAL="$(hostname 2>/dev/null || true)"
fi

DEV_MODEL="$(read_sysfs_line /proc/device-tree/model || true)"
[ -n "$DEV_MODEL" ] || DEV_MODEL="$(read_sysfs_line /sys/devices/soc0/machine || true)"
if [ -z "$DEV_MODEL" ] && command -v getprop >/dev/null 2>&1; then
  DEV_MODEL="$(getprop ro.product.model 2>/dev/null || true)"
fi

DEV_KERNEL="$(uname -r 2>/dev/null || true)"
DEV_SOC_ID="$(read_sysfs_line /sys/devices/soc0/soc_id || true)"

DEV_ANDROID=""
if command -v getprop >/dev/null 2>&1; then
  DEV_ANDROID="$(getprop ro.build.version.release 2>/dev/null || true)"
fi

SOC_FAMILY="$(read_sysfs_line /sys/devices/soc0/family || true)"
SOC_REVISION="$(read_sysfs_line /sys/devices/soc0/revision || true)"
OS_PRETTY=""
if [ -r /etc/os-release ]; then
  OS_PRETTY="$(
    awk -F= '$1 == "PRETTY_NAME" { gsub(/^"|"$/, "", $2); print $2; exit }' \
      /etc/os-release 2>/dev/null || true
  )"
fi

{
  echo "serial        : ${DEV_SERIAL:-unavailable}"
  echo "model         : ${DEV_MODEL:-unavailable}"
  echo "kernel        : ${DEV_KERNEL:-unavailable}"
  echo "soc_id        : ${DEV_SOC_ID:-unavailable}"
  echo "soc_family    : ${SOC_FAMILY:-unavailable}"
  echo "soc_revision  : ${SOC_REVISION:-unavailable}"
  echo "os            : ${OS_PRETTY:-unavailable}"
  echo "android       : ${DEV_ANDROID:-n/a}"
  echo "nproc         : $(bench_nproc 2>/dev/null || echo unavailable)"
} > "$RAW_DIR/device-info.txt"

cat "$RAW_DIR/device-info.txt" 2>/dev/null || true

for _f in /proc/cmdline /proc/version; do
  _k="$(sanitize_id "$(basename "$_f")")"
  cat "$_f" > "$RAW_DIR/proc-$_k.txt" 2>/dev/null || true
done

# A verdict, not a number: the schema requires a serial, and a snapshot with no
# device identity cannot be compared against another one with any confidence.
if [ -n "$DEV_SERIAL" ] && [ -n "$DEV_KERNEL" ]; then
  bench_metric "snapshot-device-identified" "pass"
else
  record_error "device" "serial and/or kernel version unavailable"
  bench_metric "snapshot-device-identified" "fail"
fi

# ---------------------------------------------------------------- /proc sources

log_info "$TESTNAME: --- /proc/meminfo ---"

MEMINFO_FIELDS="MemTotal MemFree MemAvailable Buffers Cached SwapCached
                Active Inactive Unevictable Mlocked SwapTotal SwapFree
                Dirty Writeback AnonPages Mapped Shmem KReclaimable Slab
                SReclaimable SUnreclaim KernelStack PageTables VmallocUsed
                CmaTotal CmaFree $EXTRA_MEMINFO_FIELDS"

if archive meminfo /proc/meminfo; then
  for f in $MEMINFO_FIELDS; do
    v="$(meminfo_field "$RAW_DIR/meminfo.txt" "$f")"
    id="snapshot-meminfo-$(sanitize_id "$f")"
    if publish "$id" "$v" "kB"; then
      parsed_add meminfo "$f" "$v"
    fi
  done
else
  for f in $MEMINFO_FIELDS; do
    bench_metric "snapshot-meminfo-$(sanitize_id "$f")" "skip"
  done
fi

log_info "$TESTNAME: --- /proc/slabinfo ---"

if archive slabinfo /proc/slabinfo; then
  # "slabinfo - version: 2.1" and the "# name ..." header are both excluded.
  # Total held = num_objs * objsize, summed; that is the figure a slab leak
  # moves, and it is not visible in MemInfo's Slab line at cache granularity.
  set -- $(
    awk '
      $1 == "slabinfo" { next }
      $1 ~ /^#/ { next }
      NF >= 4 {
          n = $3 + 0
          s = $4 + 0
          if (n > 0 && s > 0) { tot += n * s; c++ }
      }
      END { if (c > 0) { printf "%d %d\n", tot / 1024, c } }
    ' "$RAW_DIR/slabinfo.txt" 2>/dev/null
  )
  SLAB_KB="${1:-}"
  SLAB_CACHES="${2:-}"

  if publish "snapshot-slab-total" "$SLAB_KB" "kB"; then
    parsed_add slabinfo "total_kb" "$SLAB_KB"
  fi
  if publish "snapshot-slab-cache-count" "$SLAB_CACHES"; then
    parsed_add slabinfo "cache_count" "$SLAB_CACHES"
  fi
else
  bench_metric "snapshot-slab-total" "skip"
  bench_metric "snapshot-slab-cache-count" "skip"
fi

log_info "$TESTNAME: --- /proc/vmstat ---"

VMSTAT_FIELDS="nr_free_pages nr_anon_pages nr_file_pages nr_shmem
               nr_slab_reclaimable nr_slab_unreclaimable nr_kernel_stack
               nr_page_table_pages nr_writeback nr_dirty"

if archive vmstat /proc/vmstat; then
  for f in $VMSTAT_FIELDS; do
    v="$(vmstat_field "$RAW_DIR/vmstat.txt" "$f")"
    id="snapshot-vmstat-$(sanitize_id "$f")"
    # nr_kernel_stack is in kB on some kernels and in pages on others; it is
    # published under its own name so the unit mismatch stays visible rather
    # than being folded into a "pages" total that would be wrong.
    if publish "$id" "$v" "pages"; then
      parsed_add vmstat "$f" "$v"
    fi
  done
else
  for f in $VMSTAT_FIELDS; do
    bench_metric "snapshot-vmstat-$(sanitize_id "$f")" "skip"
  done
fi

# Archived for the skill's own parsers and for fragmentation analysis; no
# single number off these is worth trending on its own.
log_info "$TESTNAME: --- buddyinfo / zoneinfo / pagetypeinfo / iomem ---"

archive buddyinfo /proc/buddyinfo || true
archive zoneinfo /proc/zoneinfo || true
archive pagetypeinfo /proc/pagetypeinfo || true
archive iomem /proc/iomem || true

# Extra context the schema has no slot for, archived only.
for _extra in /proc/modules /proc/vmallocinfo /proc/swaps; do
  _n="$(sanitize_id "$(basename "$_extra")")"
  if [ -r "$_extra" ]; then
    cat "$_extra" > "$RAW_DIR/extra-$_n.txt" 2>/dev/null || true
  fi
done

# ---------------------------------------------------------------- reserved memory

log_info "$TESTNAME: --- reserved memory ---"

# memblock's debugfs view is text and carries both halves of every range, so
# the reserved total can be summed exactly. The device-tree reserved-memory
# node encodes its ranges as big-endian cells whose width depends on
# #address-cells/#size-cells, so the region NAMES are recorded and the sizes
# are taken from memblock instead of being guessed from the binary blob.
MEMBLOCK_RESERVED="/sys/kernel/debug/memblock/reserved"
MEMBLOCK_MEMORY="/sys/kernel/debug/memblock/memory"
DT_RESERVED="/proc/device-tree/reserved-memory"

AWK_MEMBLOCK='
function h2d(s,    i, c, v, d) {
    v = 0
    for (i = 1; i <= length(s); i++) {
        c = tolower(substr(s, i, 1))
        d = index("0123456789abcdef", c) - 1
        if (d < 0) { return -1 }
        v = v * 16 + d
    }
    return v
}
{
    if (match($0, /0x[0-9a-fA-F]+\.\.0x[0-9a-fA-F]+/)) {
        r = substr($0, RSTART, RLENGTH)
        p = index(r, "..")
        a = substr(r, 3, p - 3)
        b = substr(r, p + 4)
        s = h2d(a)
        e = h2d(b)
        if (s >= 0 && e >= s) { tot += (e - s + 1); n++ }
    }
}
END { if (n > 0) { printf "%d %d\n", tot / 1024, n } }
'

RM_AVAILABLE=0

if [ -r "$MEMBLOCK_RESERVED" ] && cat "$MEMBLOCK_RESERVED" \
     > "$RAW_DIR/memblock-reserved.txt" 2>/dev/null \
     && [ -s "$RAW_DIR/memblock-reserved.txt" ]; then
  RM_AVAILABLE=1
  set -- $(awk "$AWK_MEMBLOCK" "$RAW_DIR/memblock-reserved.txt" 2>/dev/null)
  if publish "snapshot-memblock-reserved-total" "${1:-}" "kB"; then
    parsed_add reserved_memory "memblock_reserved_total_kb" "${1:-}"
  fi
  if publish "snapshot-memblock-reserved-range-count" "${2:-}"; then
    parsed_add reserved_memory "memblock_reserved_ranges" "${2:-}"
  fi
else
  record_error "reserved_memory" "not readable: $MEMBLOCK_RESERVED (debugfs mounted? CONFIG_DEBUG_FS?)"
  bench_metric "snapshot-memblock-reserved-total" "skip"
  bench_metric "snapshot-memblock-reserved-range-count" "skip"
fi

if [ -r "$MEMBLOCK_MEMORY" ] && cat "$MEMBLOCK_MEMORY" \
     > "$RAW_DIR/memblock-memory.txt" 2>/dev/null \
     && [ -s "$RAW_DIR/memblock-memory.txt" ]; then
  RM_AVAILABLE=1
  set -- $(awk "$AWK_MEMBLOCK" "$RAW_DIR/memblock-memory.txt" 2>/dev/null)
  if publish "snapshot-memblock-memory-total" "${1:-}" "kB"; then
    parsed_add reserved_memory "memblock_memory_total_kb" "${1:-}"
  fi
else
  bench_metric "snapshot-memblock-memory-total" "skip"
fi

DT_COUNT=""
if [ -d "$DT_RESERVED" ]; then
  : > "$RAW_DIR/dt-reserved-memory.txt"
  DT_COUNT=0
  for d in "$DT_RESERVED"/*; do
    [ -d "$d" ] || continue
    DT_COUNT=$((DT_COUNT + 1))
    basename "$d" >> "$RAW_DIR/dt-reserved-memory.txt"
  done
  RM_AVAILABLE=1
fi

if publish "snapshot-dt-reserved-region-count" "$DT_COUNT"; then
  parsed_add reserved_memory "dt_region_count" "$DT_COUNT"
fi

if [ "$RM_AVAILABLE" -eq 1 ]; then
  src_mark reserved_memory 1 "$MEMBLOCK_RESERVED"
else
  src_mark reserved_memory 0 "$MEMBLOCK_RESERVED"
fi

# ---------------------------------------------------------------- debugfs

DMABUF="/sys/kernel/debug/dma_buf/bufinfo"
CMA_DIR="/sys/kernel/debug/cma"
KGSL_CLASS="/sys/class/kgsl/kgsl"
KGSL_DEBUG="/sys/kernel/debug/kgsl"

if [ "$COLLECT_DEBUGFS" -eq 1 ]; then
  log_info "$TESTNAME: --- debugfs: dma-buf ---"

  if archive dmabuf "$DMABUF"; then
    # Newer kernels print a "Total N objects, M bytes" summary; older ones do
    # not, so fall back to summing the per-buffer size column. Both paths are
    # tried rather than assuming a kernel version.
    set -- $(
      awk '
        /^Total[ \t]+[0-9]+[ \t]*objects/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "bytes") { bytes = $(i - 1) + 0; objs = $2 + 0; found = 1 }
            }
        }
        NF >= 5 && $1 ~ /^[0-9]+$/ { sb += $1 + 0; so++ }
        END {
            if (found) { printf "%d %d\n", bytes / 1024, objs }
            else if (so > 0) { printf "%d %d\n", sb / 1024, so }
        }
      ' "$RAW_DIR/dmabuf.txt" 2>/dev/null
    )
    if publish "snapshot-dmabuf-total" "${1:-}" "kB"; then
      parsed_add dmabuf "total_kb" "${1:-}"
    fi
    if publish "snapshot-dmabuf-object-count" "${2:-}"; then
      parsed_add dmabuf "object_count" "${2:-}"
    fi
  else
    bench_metric "snapshot-dmabuf-total" "skip"
    bench_metric "snapshot-dmabuf-object-count" "skip"
  fi

  log_info "$TESTNAME: --- debugfs: CMA ---"

  CMA_REGIONS=0
  if [ -d "$CMA_DIR" ]; then
    : > "$RAW_DIR/cma.txt"
    for d in "$CMA_DIR"/*; do
      [ -d "$d" ] || continue
      r="$(basename "$d")"
      rid="$(sanitize_id "$r")"
      total="$(read_sysfs_line "$d/count" || true)"
      used="$(read_sysfs_line "$d/used" || true)"
      printf '%s total_pages=%s used_pages=%s\n' "$r" "${total:-?}" "${used:-?}" \
        >> "$RAW_DIR/cma.txt"

      if publish "snapshot-cma-$rid-total" "$total" "pages"; then
        parsed_add cma "${r}_total_pages" "$total"
      fi
      if publish "snapshot-cma-$rid-used" "$used" "pages"; then
        parsed_add cma "${r}_used_pages" "$used"
      fi
      CMA_REGIONS=$((CMA_REGIONS + 1))
    done
  fi

  if [ "$CMA_REGIONS" -gt 0 ]; then
    src_mark cma 1 "$CMA_DIR"
    publish "snapshot-cma-region-count" "$CMA_REGIONS" || true
    parsed_add cma "region_count" "$CMA_REGIONS"
  else
    src_mark cma 0 "$CMA_DIR"
    record_error "cma" "no CMA regions under $CMA_DIR (CONFIG_CMA / CONFIG_CMA_DEBUGFS?)"
    bench_metric "snapshot-cma-region-count" "skip"
  fi

  log_info "$TESTNAME: --- debugfs: KGSL ---"

  KGSL_AVAILABLE=0

  for f in page_alloc page_alloc_max; do
    v="$(read_sysfs_line "$KGSL_CLASS/$f" || true)"
    id="snapshot-kgsl-$(sanitize_id "$f")"
    # These are bytes; published in kB to match everything else here.
    kb="$(
      awk -v b="${v:-}" 'BEGIN { if (b == "" || b + 0 < 0) { exit 1 } printf "%d\n", b / 1024 }' \
        2>/dev/null || true
    )"
    if publish "$id" "$kb" "kB"; then
      parsed_add kgsl "${f}_kb" "$kb"
      KGSL_AVAILABLE=1
    fi
  done

  KGSL_PROCS=""
  if [ -d "$KGSL_DEBUG/proc" ]; then
    KGSL_PROCS=0
    for d in "$KGSL_DEBUG/proc"/*; do
      [ -d "$d" ] || continue
      KGSL_PROCS=$((KGSL_PROCS + 1))
    done
    KGSL_AVAILABLE=1
  fi

  if publish "snapshot-kgsl-proc-count" "$KGSL_PROCS"; then
    parsed_add kgsl "proc_count" "$KGSL_PROCS"
  fi

  if [ "$KGSL_AVAILABLE" -eq 1 ]; then
    src_mark kgsl 1 "$KGSL_CLASS"
  else
    src_mark kgsl 0 "$KGSL_CLASS"
    record_error "kgsl" "no KGSL counters at $KGSL_CLASS or $KGSL_DEBUG"
  fi
else
  log_info "$TESTNAME: debugfs collection disabled (--collect-debugfs 0)"
  src_mark dmabuf 0 "$DMABUF"
  src_mark cma 0 "$CMA_DIR"
  src_mark kgsl 0 "$KGSL_CLASS"
  for id in snapshot-dmabuf-total snapshot-dmabuf-object-count \
            snapshot-cma-region-count snapshot-kgsl-page-alloc \
            snapshot-kgsl-page-alloc-max snapshot-kgsl-proc-count; do
    bench_metric "$id" "skip"
  done
fi

# ---------------------------------------------------------------- zram

log_info "$TESTNAME: --- zram ---"

ZRAM_FOUND=0
for d in /sys/block/zram*; do
  [ -d "$d" ] || continue
  [ -r "$d/mm_stat" ] || continue
  n="$(sanitize_id "$(basename "$d")")"
  cat "$d/mm_stat" > "$RAW_DIR/$n-mm_stat.txt" 2>/dev/null || continue
  ZRAM_FOUND=1

  # mm_stat: orig_data_size compr_data_size mem_used_total ...  (bytes)
  set -- $(
    awk '{ printf "%d %d %d\n", $1 / 1024, $2 / 1024, $3 / 1024; exit }' \
      "$RAW_DIR/$n-mm_stat.txt" 2>/dev/null
  )
  publish "snapshot-$n-orig-data" "${1:-}" "kB" || true
  publish "snapshot-$n-compressed-data" "${2:-}" "kB" || true
  publish "snapshot-$n-mem-used-total" "${3:-}" "kB" || true
done

[ "$ZRAM_FOUND" -eq 1 ] || log_info "$TESTNAME: no zram device with mm_stat; nothing published"

# ---------------------------------------------------------------- process PSS

log_info "$TESTNAME: --- per-process PSS ---"

PSS_RAW="$OUT_DIR/pss-by-pid.tsv"
PSS_AGG="$OUT_DIR/pss-by-name.tsv"

if [ "$COLLECT_PSS" -eq 1 ]; then
  : > "$PSS_RAW"
  PROC_COUNT=0

  for p in /proc/[0-9]*; do
    [ -d "$p" ] || continue
    [ -r "$p/smaps_rollup" ] || continue

    pss="$(awk '$1 == "Pss:" { print $2; exit }' "$p/smaps_rollup" 2>/dev/null || true)"
    [ -n "$pss" ] || continue

    comm="$(tr -d '\000' < "$p/comm" 2>/dev/null | sed -n '1p' || true)"
    [ -n "$comm" ] || comm="unknown"

    printf '%s\t%s\t%s\n' "$pss" "$comm" "$(basename "$p")" >> "$PSS_RAW"
    PROC_COUNT=$((PROC_COUNT + 1))
  done

  if [ "$PROC_COUNT" -gt 0 ]; then
    src_mark process_stats 1 "/proc/<pid>/smaps_rollup"

    PSS_TOTAL="$(awk -F'\t' '{ t += $1 } END { if (NR > 0) printf "%d\n", t }' "$PSS_RAW" 2>/dev/null || true)"

    if publish "snapshot-pss-total" "$PSS_TOTAL" "kB"; then
      parsed_add process_stats "pss_total_kb" "$PSS_TOTAL"
    fi
    if publish "snapshot-process-count" "$PROC_COUNT"; then
      parsed_add process_stats "process_count" "$PROC_COUNT"
    fi

    # Summed per process NAME, so the case ids are stable across boots and two
    # instances of the same binary do not collide on one id. Emitted space
    # separated rather than tab separated: "read -r kb name" then gives the
    # whole remainder to name, which a tab in IFS would not survive on every
    # shell.
    awk -F'\t' '{ s[$2] += $1 } END { for (k in s) { printf "%d %s\n", s[k], k } }' \
      "$PSS_RAW" 2>/dev/null | sort -rn > "$PSS_AGG" 2>/dev/null ||
      awk -F'\t' '{ s[$2] += $1 } END { for (k in s) { printf "%d %s\n", s[k], k } }' \
        "$PSS_RAW" > "$PSS_AGG" 2>/dev/null

    rank=0
    while read -r kb name; do
      [ -n "$kb" ] || continue
      rank=$((rank + 1))
      [ "$rank" -le "$PSS_TOP" ] || break
      nid="$(sanitize_id "$name")"
      [ -n "$nid" ] || nid="unknown"
      if publish "snapshot-pss-$nid" "$kb" "kB"; then
        parsed_add process_stats "pss_${name}_kb" "$kb"
      fi
    done < "$PSS_AGG"
  else
    src_mark process_stats 0 "/proc/<pid>/smaps_rollup"
    record_error "process_stats" "no process exposed a readable smaps_rollup (kernel < 4.14?)"
    bench_metric "snapshot-pss-total" "skip"
    bench_metric "snapshot-process-count" "skip"
  fi
else
  log_info "$TESTNAME: PSS collection disabled (--collect-pss 0)"
  src_mark process_stats 0 "/proc/<pid>/smaps_rollup"
  bench_metric "snapshot-pss-total" "skip"
  bench_metric "snapshot-process-count" "skip"
fi

# ---------------------------------------------------------------- dmesg

if [ "$COLLECT_DMESG" -eq 1 ]; then
  if command -v dmesg >/dev/null 2>&1; then
    dmesg > "$RAW_DIR/dmesg.txt" 2>/dev/null || true
  fi
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -k --no-pager > "$RAW_DIR/journal-kernel.txt" 2>/dev/null || true
  fi
fi

# ---------------------------------------------------------------- snapshot.json

log_info "$TESTNAME: --- snapshot.json ---"

DUMP_DIR_ABS="$(cd "$RAW_DIR" 2>/dev/null && pwd || echo "$RAW_DIR")"

# emit_parsed <key> <indent>
#
# The whole "parsed" object for one source. Numeric values are emitted bare and
# everything else is quoted, because a measurement that reached LAVA as a
# number must not become a string here.
emit_parsed() {
  _kv="$PARSED_DIR/$1.kv"
  if [ ! -s "$_kv" ]; then
    printf '{}'
    return 0
  fi
  awk -F'\t' -v ind="$2" '
    BEGIN { printf "{" }
    {
        gsub(/\\/, "\\\\", $1); gsub(/"/, "\\\"", $1)
        gsub(/\\/, "\\\\", $2); gsub(/"/, "\\\"", $2)
        if (n++) { printf "," }
        if ($2 ~ /^-?[0-9]+(\.[0-9]+)?$/) {
            printf "\n%s  \"%s\": %s", ind, $1, $2
        } else {
            printf "\n%s  \"%s\": \"%s\"", ind, $1, $2
        }
    }
    END { if (n) { printf "\n%s}", ind } else { printf "}" } }
  ' "$_kv"
}

# emit_source <key> <indent>
emit_source() {
  _a="$AVAIL_DIR/$1"
  _av="false"
  _pa=""
  if [ -s "$_a" ]; then
    _av="$(awk -F'\t' '{ if ($1 == "1") print "true"; else print "false"; exit }' "$_a")"
    _pa="$(awk -F'\t' '{ print $2; exit }' "$_a")"
  fi

  printf '{\n%s  "available": %s,\n' "$2" "$_av"
  printf '%s  "path": "%s",\n' "$2" "$(json_escape "$_pa")"
  printf '%s  "parsed": ' "$2"
  emit_parsed "$1" "$2  "
  printf '\n%s}' "$2"
}

{
  printf '{\n'
  printf '  "schema_version": "%s",\n' "$SCHEMA_VERSION"
  if [ -n "$SNAPSHOT_ID" ]; then
    printf '  "snapshot_id": "%s",\n' "$(json_escape "$SNAPSHOT_ID")"
  else
    # snapshot_id is required by the schema. Emitting null rather than an
    # invented value keeps the failure visible to a validator instead of
    # hiding it behind a plausible-looking UUID.
    printf '  "snapshot_id": null,\n'
  fi
  printf '  "timestamp": "%s",\n' "$TIMESTAMP"
  printf '  "label": "%s",\n' "$(json_escape "$LABEL")"
  printf '  "dump_dir": "%s",\n' "$(json_escape "$DUMP_DIR_ABS")"

  printf '  "device": {\n'
  printf '    "serial": "%s"' "$(json_escape "$DEV_SERIAL")"
  [ -n "$DEV_MODEL" ] && printf ',\n    "model": "%s"' "$(json_escape "$DEV_MODEL")"
  [ -n "$DEV_KERNEL" ] && printf ',\n    "kernel_version": "%s"' "$(json_escape "$DEV_KERNEL")"
  [ -n "$DEV_SOC_ID" ] && printf ',\n    "soc_id": "%s"' "$(json_escape "$DEV_SOC_ID")"
  [ -n "$DEV_ANDROID" ] && printf ',\n    "android_version": "%s"' "$(json_escape "$DEV_ANDROID")"
  printf '\n  },\n'

  printf '  "sources": {\n'
  first=1
  for key in meminfo slabinfo vmstat buddyinfo zoneinfo pagetypeinfo \
             process_stats reserved_memory iomem; do
    [ "$first" -eq 1 ] || printf ',\n'
    first=0
    printf '    "%s": ' "$key"
    emit_source "$key" "    "
  done

  printf ',\n    "debugfs": {\n'
  dfirst=1
  for key in dmabuf cma kgsl; do
    [ "$dfirst" -eq 1 ] || printf ',\n'
    dfirst=0
    printf '      "%s": ' "$key"
    emit_source "$key" "      "
  done
  printf '\n    }\n'
  printf '  },\n'

  printf '  "collection_errors": ['
  if [ -s "$ERRORS" ]; then
    awk -F'\t' '
      {
          gsub(/\\/, "\\\\", $1); gsub(/"/, "\\\"", $1)
          gsub(/\\/, "\\\\", $2); gsub(/"/, "\\\"", $2)
          if (n++) { printf "," }
          printf "\n    { \"source\": \"%s\", \"error\": \"%s\" }", $1, $2
      }
      END { if (n) { printf "\n  " } }
    ' "$ERRORS"
  fi
  printf ']\n'
  printf '}\n'
} > "$SNAPSHOT"

# Validity is checked rather than asserted: this artifact exists to be consumed
# by another tool, and a truncated JSON is worse than none.
JSON_OK=0
if [ -s "$SNAPSHOT" ]; then
  if command -v python3 >/dev/null 2>&1; then
    if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$SNAPSHOT" 2>/dev/null; then
      JSON_OK=1
    fi
  elif command -v jq >/dev/null 2>&1; then
    jq -e . "$SNAPSHOT" >/dev/null 2>&1 && JSON_OK=1
  else
    # No parser on the image. Fall back to a structural check: balanced braces
    # and a closing brace at the end. Reported as a pass only because the
    # alternative is reporting a failure we cannot actually establish.
    if awk '
        { for (i = 1; i <= length($0); i++) {
              c = substr($0, i, 1)
              if (c == "{") { d++ } else if (c == "}") { d-- }
          } }
        END { exit (d == 0 ? 0 : 1) }
      ' "$SNAPSHOT" 2>/dev/null; then
      JSON_OK=1
      log_warn "$TESTNAME: no python3/jq on the image; snapshot.json checked for brace balance only"
    fi
  fi
fi

if [ "$JSON_OK" -eq 1 ]; then
  bench_metric "snapshot-json-valid" "pass"
else
  record_error "snapshot" "snapshot.json did not parse"
  bench_metric "snapshot-json-valid" "fail"
fi

# How much of the source list this image actually exposes. Worth a number: it
# changes when a kernel config changes, and it explains a sudden gap in the
# other cases without having to read the log.
AVAIL_COUNT=0
SRC_TOTAL=0
for key in meminfo slabinfo vmstat buddyinfo zoneinfo pagetypeinfo \
           process_stats reserved_memory iomem dmabuf cma kgsl; do
  SRC_TOTAL=$((SRC_TOTAL + 1))
  if [ -s "$AVAIL_DIR/$key" ] &&
     awk -F'\t' '{ exit ($1 == "1" ? 0 : 1) }' "$AVAIL_DIR/$key" 2>/dev/null; then
    AVAIL_COUNT=$((AVAIL_COUNT + 1))
  fi
done

bench_metric "snapshot-sources-available" "pass" "$AVAIL_COUNT" "count"
bench_metric "snapshot-sources-total" "pass" "$SRC_TOTAL" "count"

# ---------------------------------------------------------------- summary

# mi <FieldName> - a meminfo value for the summary, or the word "unavailable"
mi() {
  _v="$(meminfo_field "$RAW_DIR/meminfo.txt" "$1" 2>/dev/null || true)"
  printf '%s' "${_v:-unavailable}"
}

{
  echo "# $TESTNAME summary"
  echo "label                  : $LABEL"
  echo "snapshot_id            : ${SNAPSHOT_ID:-unavailable}"
  echo "timestamp              : $TIMESTAMP"
  echo "schema_version         : $SCHEMA_VERSION"
  echo "sources available      : $AVAIL_COUNT of $SRC_TOTAL"
  echo "snapshot.json          : $SNAPSHOT (valid=$JSON_OK)"
  echo "raw sources            : $DUMP_DIR_ABS"
  echo
  cat "$RAW_DIR/device-info.txt" 2>/dev/null || true
  echo
  echo "# headline counters (kB unless stated)"
  echo "MemTotal               : $(mi MemTotal)"
  echo "MemFree                : $(mi MemFree)"
  echo "MemAvailable           : $(mi MemAvailable)"
  echo "Cached                 : $(mi Cached)"
  echo "Slab (held, slabinfo)  : ${SLAB_KB:-unavailable}"
  echo "PSS total              : ${PSS_TOTAL:-unavailable}"
  echo
  if [ -s "$PSS_AGG" ]; then
    echo "# top processes by PSS (summed per process name)"
    head -n "$PSS_TOP" "$PSS_AGG" 2>/dev/null || true
    echo
  fi
  if [ -s "$ERRORS" ]; then
    echo "# collection errors (a missing source is a SKIP, not a zero)"
    cat "$ERRORS"
    echo
  fi
  echo "# This snapshot is a read of kernel counters at one instant. Cached,"
  echo "# dma-buf and PSS all describe whatever last ran on the board, so a"
  echo "# single snapshot is a fact about a moment, not about the image. To"
  echo "# attribute a change to a workload, take two - --label baseline before"
  echo "# and --label after_test after - and compare them off the board."
} > "$SUMMARY"

log_info "$TESTNAME: summary written to $SUMMARY"
cat "$SUMMARY" 2>/dev/null || true

bench_finish
exit 0

#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# /proc/meminfo reader for qcom-linux-testkit (performance)
# - Publishes MemTotal, MemFree, Cached and the available/used figures to LAVA
#   as measurements, in kB (the unit /proc/meminfo itself uses)
# - Archives the whole of /proc/meminfo so a figure can be re-derived later
#   without another run
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use Memory_Info.res for gating.
# - Nothing here allocates or frees memory; it is a read of kernel counters.
#   Run it EARLY in a job: once a benchmark has touched the filesystem, Cached
#   reflects that benchmark's working set rather than the booted system.
# - This is not Memory_Map. That suite walks per-process smaps for PSS
#   attribution; this one reports the system-wide totals.
#
# Two different "available" numbers
# ---------------------------------
# MemAvailable is a kernel estimate of how much can be allocated without
# swapping, and it accounts for the fact that part of the page cache is NOT
# reclaimable (mapped pages, dirty pages, the low watermark).
#
# MemTotal - (MemFree + Cached) is a different quantity: it is closer to
# "memory the kernel and anonymous pages are actually holding", i.e. used
# memory, and it is systematically SMALLER than the memory truly available
# because it treats all of Cached as free-on-demand.
#
# Both are published, under names that say which is which, because they answer
# different questions and the gap between them is itself diagnostic. Nothing is
# reported under a bare "available" id, which would be ambiguous.

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

TESTNAME="Memory_Info"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
MEMINFO="${MEMINFO:-/proc/meminfo}"

# One sample by default. With more than one, the point values below come from
# the last sample and mean/min/max are published alongside them, so the case
# ids do not change shape with the sample count.
ITERATIONS="${ITERATIONS:-1}"
INTERVAL_SECS="${INTERVAL_SECS:-1}"

# Seconds to wait before the first sample. Useful right after boot, when
# services are still settling and the counters are still moving.
SETTLE_SECS="${SETTLE_SECS:-0}"

# Extra /proc/meminfo field names to publish, space separated, spelled exactly
# as in the file (e.g. "SwapTotal SwapFree Buffers Shmem Slab").
EXTRA_FIELDS="${EXTRA_FIELDS:-}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR        output directory (default: $OUT_DIR)
  --meminfo PATH       file to read (default: $MEMINFO)
  --iterations N       samples to take (default: $ITERATIONS)
  --interval-secs N    delay between samples (default: $INTERVAL_SECS)
  --settle-secs N      delay before the first sample (default: $SETTLE_SECS)
  --extra-fields "A B" additional /proc/meminfo fields to publish
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --meminfo) MEMINFO="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --interval-secs) INTERVAL_SECS="$2"; shift 2 ;;
    --settle-secs) SETTLE_SECS="$2"; shift 2 ;;
    --extra-fields) EXTRA_FIELDS="$2"; shift 2 ;;
    *)
      echo "[WARN] Unknown option: $1" >&2
      usage
      echo "$TESTNAME FAIL" > "$test_path/${TESTNAME}.res"
      exit 0
      ;;
  esac
done

case "$ITERATIONS" in ''|*[!0-9]*|0) ITERATIONS=1 ;; esac
case "$INTERVAL_SECS" in ''|*[!0-9]*) INTERVAL_SECS=1 ;; esac
case "$SETTLE_SECS" in ''|*[!0-9]*) SETTLE_SECS=0 ;; esac

bench_init "$TESTNAME" "$OUT_DIR" "$test_path" || exit 0
bench_log_env

if ! bench_require_cmds awk; then
  bench_skip_exit "awk missing"
  exit 0
fi

if [ ! -r "$MEMINFO" ]; then
  bench_skip_exit "$MEMINFO is not readable"
  exit 0
fi

# ---------------------------------------------------------------- helpers

# The field names requested by this suite. MemAvailable is listed because the
# kernel's own estimate is the number most people mean by "available"; it is
# absent on kernels older than 3.14, which is handled as a SKIP.
BASE_FIELDS="MemTotal MemFree Cached MemAvailable"
ALL_FIELDS="$BASE_FIELDS $EXTRA_FIELDS"

# meminfo_field <file> <FieldName>
#
# /proc/meminfo lines are "MemTotal:       36331692 kB". Matching on the
# field name WITH its colon is what keeps Cached from also matching
# SwapCached, which is a different counter.
meminfo_field() {
  awk -v k="$2:" '$1 == k { print $2; exit }' "$1" 2>/dev/null
}

# Case id from a field name: MemTotal -> meminfo-memtotal
field_id() {
  printf 'meminfo-%s' "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
}

# ---------------------------------------------------------------- sample

if [ "$SETTLE_SECS" -gt 0 ] 2>/dev/null; then
  log_info "$TESTNAME: settling for ${SETTLE_SECS}s before the first sample"
  sleep "$SETTLE_SECS"
fi

log_info "$TESTNAME: reading $MEMINFO, iterations=$ITERATIONS interval=${INTERVAL_SECS}s"

LAST_SAMPLE="$OUT_DIR/meminfo-last.txt"
SERIES="$OUT_DIR/series.tsv"
: > "$SERIES"

printf '# sample' > "$SERIES"
for f in $ALL_FIELDS; do
  printf '\t%s' "$f" >> "$SERIES"
done
printf '\tMemTotalMinusFreeAndCached\n' >> "$SERIES"

i=1
while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
  snap="$OUT_DIR/meminfo-sample${i}.txt"

  if ! cat "$MEMINFO" > "$snap" 2>/dev/null; then
    log_warn "$TESTNAME: sample $i could not read $MEMINFO"
    i=$((i + 1))
    continue
  fi

  cp "$snap" "$LAST_SAMPLE" 2>/dev/null || true

  printf '%s' "$i" >> "$SERIES"

  for f in $ALL_FIELDS; do
    v="$(meminfo_field "$snap" "$f")"
    printf '\t%s' "${v:-}" >> "$SERIES"

    if [ -n "$v" ]; then
      bench_values_add "$OUT_DIR/${f}.values" "$v" >/dev/null 2>&1 || true
    fi
  done

  # The requested derived figure, computed per sample so that its mean is a
  # mean of consistent snapshots rather than a combination of means taken at
  # different moments.
  mt="$(meminfo_field "$snap" MemTotal)"
  mf="$(meminfo_field "$snap" MemFree)"
  mc="$(meminfo_field "$snap" Cached)"

  derived="$(
    awk -v t="${mt:-}" -v fr="${mf:-}" -v c="${mc:-}" 'BEGIN {
      if (t == "" || fr == "" || c == "") { exit 1 }
      printf "%d\n", t - (fr + c)
    }' 2>/dev/null || true
  )"

  printf '\t%s\n' "${derived:-}" >> "$SERIES"

  if [ -n "$derived" ]; then
    bench_values_add "$OUT_DIR/derived.values" "$derived" >/dev/null 2>&1 || true
  fi

  if [ "$i" -lt "$ITERATIONS" ] && [ "$INTERVAL_SECS" -gt 0 ] 2>/dev/null; then
    sleep "$INTERVAL_SECS"
  fi

  i=$((i + 1))
done

if [ ! -s "$LAST_SAMPLE" ]; then
  bench_skip_exit "no sample of $MEMINFO could be read"
  exit 0
fi

# ---------------------------------------------------------------- publish

log_info "$TESTNAME: --- /proc/meminfo fields ---"

for f in $ALL_FIELDS; do
  id="$(field_id "$f")"
  v="$(meminfo_field "$LAST_SAMPLE" "$f")"

  if [ -n "$v" ] && bench_is_number "$v"; then
    bench_metric "$id" "pass" "$v" "kB"
  else
    # MemAvailable predates nothing older than 3.14; other requested fields may
    # simply not exist on this kernel. Absent is a SKIP, not a zero.
    log_warn "$TESTNAME: $f not present in $MEMINFO"
    bench_metric "$id" "skip"
  fi

  if [ "$ITERATIONS" -gt 1 ] && [ -s "$OUT_DIR/${f}.values" ]; then
    bench_metric_from_values "$id" "$OUT_DIR/${f}.values" "kB" "mean min max" || true
  fi
done

log_info "$TESTNAME: --- derived ---"

MT="$(meminfo_field "$LAST_SAMPLE" MemTotal)"
MF="$(meminfo_field "$LAST_SAMPLE" MemFree)"
MC="$(meminfo_field "$LAST_SAMPLE" Cached)"

DERIVED="$(
  awk -v t="${MT:-}" -v fr="${MF:-}" -v c="${MC:-}" 'BEGIN {
    if (t == "" || fr == "" || c == "") { exit 1 }
    printf "%d\n", t - (fr + c)
  }' 2>/dev/null || true
)"

if [ -n "$DERIVED" ]; then
  # Named for what it computes, not "available": MemTotal - (MemFree + Cached)
  # is used memory, and calling it available would overstate the free memory
  # by the whole of the page cache. The kernel's MemAvailable is published
  # above under meminfo-memavailable.
  bench_metric "meminfo-memtotal-minus-free-and-cached" "pass" "$DERIVED" "kB"

  if [ "$ITERATIONS" -gt 1 ] && [ -s "$OUT_DIR/derived.values" ]; then
    bench_metric_from_values "meminfo-memtotal-minus-free-and-cached" \
      "$OUT_DIR/derived.values" "kB" "mean min max" || true
  fi
else
  log_warn "$TESTNAME: cannot derive MemTotal - (MemFree + Cached); a field is missing"
  bench_metric "meminfo-memtotal-minus-free-and-cached" "skip"
fi

# Percentage used, which is what a threshold is usually written against.
USED_PCT="$(
  awk -v t="${MT:-}" -v d="${DERIVED:-}" 'BEGIN {
    if (t == "" || d == "" || t + 0 <= 0) { exit 1 }
    printf "%.3f\n", (d / t) * 100
  }' 2>/dev/null || true
)"

if [ -n "$USED_PCT" ]; then
  bench_metric "meminfo-used-percent" "pass" "$USED_PCT" "%"
else
  bench_metric "meminfo-used-percent" "skip"
fi

# ---------------------------------------------------------------- summary

summary="$OUT_DIR/summary.txt"
{
  echo "# $TESTNAME summary (all values in kB unless stated)"
  echo "source                             : $MEMINFO"
  echo "samples                            : $ITERATIONS"
  echo
  echo "MemTotal                           : ${MT:-unavailable}"
  echo "MemFree                            : ${MF:-unavailable}"
  echo "Cached                             : ${MC:-unavailable}"
  echo "MemAvailable (kernel estimate)     : $(meminfo_field "$LAST_SAMPLE" MemAvailable 2>/dev/null || echo unavailable)"
  echo "MemTotal - (MemFree + Cached)      : ${DERIVED:-unavailable}"
  echo "used percent                       : ${USED_PCT:-unavailable}"
  echo
  echo "# MemAvailable and MemTotal - (MemFree + Cached) are NOT the same"
  echo "# quantity. MemAvailable is how much can be allocated without"
  echo "# swapping, and it excludes the part of Cached that cannot be"
  echo "# reclaimed. The subtraction above counts all of Cached as free and so"
  echo "# describes memory currently held, i.e. used memory. Expect the"
  echo "# subtraction to be the smaller number; the gap is non-reclaimable"
  echo "# page cache plus the low watermark."
  echo
  echo "# Cached is sensitive to whatever ran before this suite. For a figure"
  echo "# that describes the booted system, run Memory_Info before the"
  echo "# benchmarks that do I/O."
} > "$summary"

log_info "$TESTNAME: summary written to $summary"
cat "$summary" 2>/dev/null || true

bench_finish
exit 0

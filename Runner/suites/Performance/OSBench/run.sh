#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# OSBench wrapper for qcom-linux-testkit
# - Runs the OSBench 1.0.2 micro-benchmarks that exercise the kernel/OS layer:
#   thread creation, memory allocation, file creation, process creation,
#   program launch and context switching
# - Publishes each sub-benchmark's average operation cost to LAVA, normalised
#   to microseconds so the cases are comparable with each other
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use OSBench.res for gating.
# - OSBench ships as a set of small separate binaries rather than one driver,
#   so each requested test is resolved independently. A test whose binary is
#   absent is reported as skip, and the rest still run; the suite only SKIPs
#   outright when none of the requested binaries exist.
# - OSBench prints a human-readable summary rather than a machine format, so
#   the parser is deliberately tolerant: it takes the number following
#   "average" on any line and normalises by whichever time unit follows it.

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

if [ -f "$TOOLS/lib_performance.sh" ]; then
  # shellcheck disable=SC1091
  . "$TOOLS/lib_performance.sh"
fi

TESTNAME="OSBench"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
# The three layers called out for platform bring-up: thread, memory, file.
TESTS="${TESTS:-create_threads mem_alloc create_files}"
ITERATIONS="${ITERATIONS:-3}"
OSBENCH_DIR="${OSBENCH_DIR:-}"
WORK_DIR="${WORK_DIR:-}"
SET_PERF_GOV="${SET_PERF_GOV:-1}"
TIMEOUT_SEC="${TIMEOUT_SEC:-300}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR        output directory (default: $OUT_DIR)
  --tests "LIST"       OSBench binaries to run (default: $TESTS)
                       known: create_threads mem_alloc create_files
                              create_processes launch_programs context_switch
  --iterations N       repeats per sub-benchmark (default: $ITERATIONS)
  --osbench-dir DIR    directory holding the OSBench binaries
  --work-dir DIR       writable scratch dir for create_files (default: auto)
  --set-perf-gov 0|1   pin CPU governor to performance (default: $SET_PERF_GOV)
  --timeout-sec N      per-run timeout (default: $TIMEOUT_SEC)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --tests) TESTS="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --osbench-dir) OSBENCH_DIR="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --set-perf-gov) SET_PERF_GOV="$2"; shift 2 ;;
    --timeout-sec) TIMEOUT_SEC="$2"; shift 2 ;;
    *)
      echo "[WARN] Unknown option: $1" >&2
      usage
      echo "$TESTNAME FAIL" > "$test_path/${TESTNAME}.res"
      exit 0
      ;;
  esac
done

bench_init "$TESTNAME" "$OUT_DIR" "$test_path" || exit 0
bench_log_env

if ! bench_require_cmds awk grep sed tr; then
  bench_skip_exit "core utilities missing"
  exit 0
fi

# ---------------------------------------------------------------- helpers

# osbench_extract_avg_us <logfile>
#
# Prints the average cost per operation in microseconds, or nothing.
# Accepts any line containing "average" followed by a number and a time unit,
# which covers OSBench's "Average time: 12.34 us" as well as the variants
# that spell it "average: 12.34us per thread".
osbench_extract_avg_us() {
    awk '
        BEGIN { IGNORECASE = 1 }
        /average/ {
            line = tolower($0)
            # Find the first number after the word "average".
            idx = index(line, "average")
            rest = substr(line, idx)
            # Strip everything up to the first digit.
            if (match(rest, /[0-9]/) == 0) { next }
            rest = substr(rest, RSTART)
            if (match(rest, /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?/) == 0) { next }
            val = substr(rest, 1, RLENGTH) + 0
            unit = substr(rest, RLENGTH + 1)
            sub(/^[ \t]+/, "", unit)

            # Normalise to microseconds.
            if (unit ~ /^ns/)                 { val = val / 1000 }
            else if (unit ~ /^us/ ||
                     unit ~ /^microsec/)      { val = val }
            else if (unit ~ /^ms/)            { val = val * 1000 }
            else if (unit ~ /^s/)             { val = val * 1000000 }
            # No recognisable unit: assume the tool already reported us.

            printf "%.6f\n", val
            exit 0
        }
    ' "$1" 2>/dev/null
}

if [ "$SET_PERF_GOV" = "1" ]; then
  bench_set_governor performance
fi

# Scratch directory for the file-creation test. tmpfs would measure page cache
# rather than the filesystem, so prefer a real writable location.
if [ -z "$WORK_DIR" ]; then
  if [ -d /var/tmp ] && [ -w /var/tmp ]; then
    WORK_DIR="/var/tmp/osbench_work"
  else
    WORK_DIR="/tmp/osbench_work"
  fi
fi
mkdir -p "$WORK_DIR" 2>/dev/null || true

if command -v perf_is_tmpfs_path >/dev/null 2>&1; then
  if perf_is_tmpfs_path "$WORK_DIR" 2>/dev/null; then
    log_warn "$TESTNAME: $WORK_DIR is tmpfs; create_files will measure RAM, not storage"
  fi
fi

log_info "$TESTNAME: tests='$TESTS' iterations=$ITERATIONS work_dir=$WORK_DIR"

BENCH_CMD_TIMEOUT="$TIMEOUT_SEC"
resolved_any=0

for t in $TESTS; do
  tbin="$(bench_resolve_bin "$t" "" "$OSBENCH_DIR" "$SCRIPT_DIR" "$SCRIPT_DIR/bin" || true)"

  if [ -z "$tbin" ] || [ ! -x "$tbin" ]; then
    log_warn "$TESTNAME: binary for '$t' not found; skipping that sub-benchmark"
    bench_metric "osbench-${t}" "skip"
    continue
  fi

  resolved_any=1
  log_info "$TESTNAME: $t -> $tbin"

  vals="$OUT_DIR/${t}.values"
  : > "$vals"

  i=1
  while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
    runlog="$OUT_DIR/${t}_run${i}.log"

    # create_files needs somewhere to write; the others ignore extra args, so
    # the working directory is set rather than passed as an argument.
    if [ "$t" = "create_files" ]; then
      ( cd "$WORK_DIR" 2>/dev/null || exit 1; exec "$tbin" ) > "$runlog" 2>&1
      rc=$?
    else
      bench_run_logged "$runlog" "$tbin"
      rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
      log_warn "$TESTNAME: $t iteration $i exited rc=$rc"
    fi

    avg="$(osbench_extract_avg_us "$runlog")"

    if [ -n "$avg" ]; then
      bench_values_add "$vals" "$avg" || true
    else
      log_warn "$TESTNAME: $t iteration $i - could not parse an average from output"
      head -10 "$runlog" 2>/dev/null || true
    fi

    i=$((i + 1))
  done

  if [ -s "$vals" ]; then
    bench_metric_from_values "osbench-${t}" "$vals" "us" "mean min max"
  else
    log_fail "$TESTNAME: $t produced no parsable results"
    bench_metric "osbench-${t}" "fail"
  fi
done

# Clean up the scratch files create_files leaves behind.
if [ -d "$WORK_DIR" ]; then
  rm -rf "$WORK_DIR" 2>/dev/null || true
fi

if [ "$resolved_any" -eq 0 ]; then
  bench_skip_exit "no OSBench binaries found (use --osbench-dir, or add osbench to the image)"
  exit 0
fi

summary="$OUT_DIR/summary.txt"
{
  echo "# $TESTNAME summary (average cost per operation, microseconds)"
  for t in $TESTS; do
    vf="$OUT_DIR/${t}.values"
    if [ -s "$vf" ]; then
      printf '%-18s mean=%s min=%s max=%s\n' "$t" \
        "$(bench_values_stat "$vf" mean)" \
        "$(bench_values_stat "$vf" min)" \
        "$(bench_values_stat "$vf" max)"
    else
      printf '%-18s no data\n' "$t"
    fi
  done
} > "$summary"

log_info "$TESTNAME: summary written to $summary"
cat "$summary" 2>/dev/null || true

bench_finish
exit 0

#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Threadbench wrapper for qcom-linux-testkit
# - Scheduler benchmark: thread creation and switching cost as the thread
#   count scales, reported per thread count so the scaling curve is visible
# - Publishes every figure to LAVA as a measurement
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use Threadbench.res for gating.
# - Two modes, and the distinction matters:
#     binary      - run a real threadbench binary from the image
#     perf-sched  - run "perf bench sched" instead
#   perf-sched is the closest in-tree equivalent, but it is NOT the same
#   benchmark, so its case ids are prefixed differently
#   (threadbench-perf-sched-*). Mode auto prefers a threadbench binary and
#   SKIPs if there is none: it will not quietly substitute perf and let the
#   numbers be filed as if threadbench had run.
# - Companion to the existing Kernel/Hackbench suite, which covers the
#   process/group side of scheduler load. Run both; they stress different
#   paths.

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

TESTNAME="Threadbench"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
MODE="${MODE:-auto}"
THREADS="${THREADS:-1 2 4 8 NPROC}"
LOOPS="${LOOPS:-}"
ITERATIONS="${ITERATIONS:-3}"
THREAD_ARG="${THREAD_ARG:--t}"
BINARY="${BINARY:-}"
THREADBENCH_DIR="${THREADBENCH_DIR:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
METRIC_KEY="${METRIC_KEY:-}"
METRIC_UNITS="${METRIC_UNITS:-}"
PERF_SCHED_TESTS="${PERF_SCHED_TESTS:-messaging pipe}"
SET_PERF_GOV="${SET_PERF_GOV:-1}"
TIMEOUT_SEC="${TIMEOUT_SEC:-600}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR         output directory (default: $OUT_DIR)
  --mode MODE           auto|binary|perf-sched (default: $MODE)
  --threads "LIST"      thread counts to sweep; NPROC means all online CPUs
                        (default: $THREADS)
  --loops N             loops/iterations passed to the tool (default: tool's own)
  --iterations N        repeats per thread count (default: $ITERATIONS)
  --thread-arg FLAG     flag the binary uses for thread count (default: $THREAD_ARG)
                        use "" for tools that take a bare positional count
  --binary PATH         explicit threadbench binary
  --threadbench-dir DIR directory holding the binary
  --extra-args "ARGS"   extra arguments appended verbatim
  --metric-key "TEXT"   report the last number on lines containing TEXT
                        (default: try a list of common labels)
  --metric-units STR    units for that metric (default: inferred)
  --perf-sched-tests L  perf bench sched sub-tests (default: $PERF_SCHED_TESTS)
  --set-perf-gov 0|1    pin CPU governor to performance (default: $SET_PERF_GOV)
  --timeout-sec N       per-run timeout (default: $TIMEOUT_SEC)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --loops) LOOPS="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --thread-arg) THREAD_ARG="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --threadbench-dir) THREADBENCH_DIR="$2"; shift 2 ;;
    --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
    --metric-key) METRIC_KEY="$2"; shift 2 ;;
    --metric-units) METRIC_UNITS="$2"; shift 2 ;;
    --perf-sched-tests) PERF_SCHED_TESTS="$2"; shift 2 ;;
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

# tb_last_number_on_key <logfile> <key text>
# Prints the last number on the first line containing <key text>.
tb_last_number_on_key() {
  awk -v key="$2" '
    index($0, key) > 0 {
      val = ""
      for (i = 1; i <= NF; i++) {
        tok = $i
        gsub(/[^0-9.eE+-]/, "", tok)
        if (tok ~ /^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/) {
          val = tok
        }
      }
      if (val != "") { print val; exit 0 }
    }
  ' "$1" 2>/dev/null
}

# tb_autoparse <logfile>
# Prints "<label> <value> <units>" for whichever well-known label is present.
# Deliberately ordered: a throughput figure is preferred over a raw duration,
# because throughput is comparable across thread counts without further work.
tb_autoparse() {
  _f="$1"

  for spec in \
    "threads/sec:throughput:threads/s" \
    "ops/sec:throughput:ops/s" \
    "operations/sec:throughput:ops/s" \
    "Throughput:throughput:ops/s" \
    "usecs/op:latency:us" \
    "usec/op:latency:us" \
    "nsecs/op:latency:ns" \
    "Average:latency:us" \
    "Total time:total-time:s" \
    "Elapsed:total-time:s" \
    "Time:total-time:s"
  do
    _key="$(printf '%s' "$spec" | cut -d: -f1)"
    _lbl="$(printf '%s' "$spec" | cut -d: -f2)"
    _un="$(printf '%s' "$spec" | cut -d: -f3)"

    _v="$(tb_last_number_on_key "$_f" "$_key")"
    if [ -n "$_v" ]; then
      printf '%s %s %s\n' "$_lbl" "$_v" "$_un"
      return 0
    fi
  done

  return 1
}

# ---------------------------------------------------------------- mode

BIN=""
if [ "$MODE" = "auto" ] || [ "$MODE" = "binary" ]; then
  for cand in threadbench thread_bench threadbench.sh; do
    BIN="$(bench_resolve_bin "$cand" "$BINARY" "$THREADBENCH_DIR" \
           "$SCRIPT_DIR" "$SCRIPT_DIR/bin" || true)"
    [ -n "$BIN" ] && break
    [ -n "$BINARY" ] && break
  done
fi

PERF_BIN=""
if [ "$MODE" = "perf-sched" ]; then
  PERF_BIN="$(bench_resolve_bin perf "" "" || true)"
fi

if [ "$MODE" = "binary" ] && [ -z "$BIN" ]; then
  bench_skip_exit "threadbench binary not found (use --binary or --threadbench-dir)"
  exit 0
fi

if [ "$MODE" = "perf-sched" ] && [ -z "$PERF_BIN" ]; then
  bench_skip_exit "perf not found; cannot run mode perf-sched"
  exit 0
fi

if [ "$MODE" = "auto" ] && [ -z "$BIN" ]; then
  # Intentionally a SKIP, not a silent fallback to perf. Ask for perf-sched
  # explicitly if that is the number you want.
  bench_skip_exit "threadbench binary not found; set --mode perf-sched to use 'perf bench sched' instead"
  exit 0
fi

if [ "$SET_PERF_GOV" = "1" ]; then
  bench_set_governor performance
fi

NPROC="$(bench_nproc)"
BENCH_CMD_TIMEOUT="$TIMEOUT_SEC"
produced_any=0

# ---------------------------------------------------------------- threadbench

if [ -n "$BIN" ]; then
  log_info "$TESTNAME: binary=$BIN threads='$THREADS' iterations=$ITERATIONS"

  for tspec in $THREADS; do
    nthr="$(bench_resolve_threads "$tspec")"
    [ -n "$nthr" ] || continue

    # Case ids carry the requested spelling so "nproc" stays readable, but the
    # resolved count is logged for anyone reading the results later.
    tag="$(printf '%s' "$tspec" | tr '[:upper:]' '[:lower:]' | tr -dc '[:alnum:]')"
    [ -n "$tag" ] || tag="$nthr"
    log_info "$TESTNAME: thread count $tspec -> $nthr"

    vals="$OUT_DIR/threads_${tag}.values"
    : > "$vals"
    units=""
    label=""

    i=1
    while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
      runlog="$OUT_DIR/threads_${tag}_run${i}.log"

      set -- "$BIN"
      if [ -n "$THREAD_ARG" ]; then
        set -- "$@" "$THREAD_ARG" "$nthr"
      else
        set -- "$@" "$nthr"
      fi
      [ -n "$LOOPS" ] && set -- "$@" -l "$LOOPS"
      # Word splitting is intended: EXTRA_ARGS is a flag string.
      # shellcheck disable=SC2086
      [ -n "$EXTRA_ARGS" ] && set -- "$@" $EXTRA_ARGS

      bench_run_logged "$runlog" "$@" || true

      if [ -n "$METRIC_KEY" ]; then
        v="$(tb_last_number_on_key "$runlog" "$METRIC_KEY")"
        label="metric"
        units="$METRIC_UNITS"
      else
        parsed="$(tb_autoparse "$runlog" || true)"
        label="$(printf '%s' "$parsed" | awk '{ print $1 }')"
        v="$(printf '%s' "$parsed" | awk '{ print $2 }')"
        units="$(printf '%s' "$parsed" | awk '{ print $3 }')"
      fi

      if [ -n "$v" ]; then
        bench_values_add "$vals" "$v" || true
      else
        log_warn "$TESTNAME: threads=$nthr iteration $i - no parsable figure"
        head -15 "$runlog" 2>/dev/null || true
      fi

      i=$((i + 1))
    done

    [ -n "$label" ] || label="metric"

    if [ -s "$vals" ]; then
      produced_any=1
      bench_metric_from_values "threadbench-${label}-threads-${tag}" \
        "$vals" "$units" "mean min max"
    else
      log_fail "$TESTNAME: no results at threads=$nthr"
      bench_metric "threadbench-threads-${tag}" "fail"
    fi
  done
fi

# ---------------------------------------------------------------- perf bench

if [ -n "$PERF_BIN" ]; then
  log_info "$TESTNAME: mode perf-sched, tests='$PERF_SCHED_TESTS'"
  log_warn "$TESTNAME: 'perf bench sched' is not threadbench; its numbers are reported under threadbench-perf-sched-* and are not comparable with a threadbench run"

  for st in $PERF_SCHED_TESTS; do
    vals="$OUT_DIR/perf_sched_${st}.values"
    : > "$vals"
    units=""
    label=""

    i=1
    while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
      runlog="$OUT_DIR/perf_sched_${st}_run${i}.log"

      set -- "$PERF_BIN" bench sched "$st"
      [ -n "$LOOPS" ] && set -- "$@" -l "$LOOPS"
      # shellcheck disable=SC2086
      [ -n "$EXTRA_ARGS" ] && set -- "$@" $EXTRA_ARGS

      bench_run_logged "$runlog" "$@" || true

      parsed="$(tb_autoparse "$runlog" || true)"
      label="$(printf '%s' "$parsed" | awk '{ print $1 }')"
      v="$(printf '%s' "$parsed" | awk '{ print $2 }')"
      units="$(printf '%s' "$parsed" | awk '{ print $3 }')"

      if [ -n "$v" ]; then
        bench_values_add "$vals" "$v" || true
      else
        log_warn "$TESTNAME: perf bench sched $st iteration $i - no parsable figure"
        head -15 "$runlog" 2>/dev/null || true
      fi

      i=$((i + 1))
    done

    [ -n "$label" ] || label="metric"

    if [ -s "$vals" ]; then
      produced_any=1
      bench_metric_from_values "threadbench-perf-sched-${st}-${label}" \
        "$vals" "$units" "mean min max"
    else
      log_fail "$TESTNAME: perf bench sched $st produced no results"
      bench_metric "threadbench-perf-sched-${st}" "fail"
    fi
  done
fi

if [ "$produced_any" -eq 0 ]; then
  log_fail "$TESTNAME: no figures parsed from any run"
  bench_finish FAIL
  exit 0
fi

summary="$OUT_DIR/summary.txt"
{
  echo "# $TESTNAME summary"
  echo "mode    : $MODE"
  echo "binary  : ${BIN:-${PERF_BIN:-none}}"
  echo "nproc   : $NPROC"
  for vf in "$OUT_DIR"/*.values; do
    [ -f "$vf" ] || continue
    printf '  %-24s mean=%s min=%s max=%s\n' "$(basename "$vf" .values)" \
      "$(bench_values_stat "$vf" mean)" \
      "$(bench_values_stat "$vf" min)" \
      "$(bench_values_stat "$vf" max)"
  done
} > "$summary"

log_info "$TESTNAME: summary written to $summary"
cat "$summary" 2>/dev/null || true

bench_finish
exit 0

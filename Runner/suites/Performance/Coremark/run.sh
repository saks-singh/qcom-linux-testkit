#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# CoreMark wrapper for qcom-linux-testkit
# - Runs EEMBC CoreMark ITERATIONS times and reports Iterations/Sec
# - Publishes each number to LAVA as a measurement via send-metrics-to-lava.sh
# - Checks CoreMark's own run-reporting rules (validation + >=10s runtime)
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use Coremark.res for gating.
# - The binary is never downloaded or built here. If CoreMark is not in the
#   image the suite SKIPs, because a binary built with different compiler
#   flags produces a score that cannot be compared with other runs.

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

TESTNAME="Coremark"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
ITERATIONS="${ITERATIONS:-3}"
BINARY="${BINARY:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
SET_PERF_GOV="${SET_PERF_GOV:-1}"
MIN_RUNTIME_SEC="${MIN_RUNTIME_SEC:-10}"
STRICT_RUNTIME="${STRICT_RUNTIME:-0}"
TIMEOUT_SEC="${TIMEOUT_SEC:-600}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR         output directory (default: $OUT_DIR)
  --iterations N         number of CoreMark runs (default: $ITERATIONS)
  --binary PATH          explicit coremark binary
  --extra-args "ARGS"    extra positional args passed to coremark
  --set-perf-gov 0|1     pin CPU governor to performance (default: $SET_PERF_GOV)
  --min-runtime-sec N    CoreMark reporting rules require >=10s (default: $MIN_RUNTIME_SEC)
  --strict-runtime 0|1   fail (not warn) when a run is shorter (default: $STRICT_RUNTIME)
  --timeout-sec N        per-run timeout (default: $TIMEOUT_SEC)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
    --set-perf-gov) SET_PERF_GOV="$2"; shift 2 ;;
    --min-runtime-sec) MIN_RUNTIME_SEC="$2"; shift 2 ;;
    --strict-runtime) STRICT_RUNTIME="$2"; shift 2 ;;
    --timeout-sec) TIMEOUT_SEC="$2"; shift 2 ;;
    *)
      # Report a failure rather than exiting silently: an unparsed option
      # means the job asked for something this runner did not do, and a
      # missing .res file makes that invisible in LAVA.
      echo "[WARN] Unknown option: $1" >&2
      usage
      echo "$TESTNAME FAIL" > "$test_path/${TESTNAME}.res"
      exit 0
      ;;
  esac
done

bench_init "$TESTNAME" "$OUT_DIR" "$test_path" || exit 0
bench_log_env

if ! bench_require_cmds awk grep sed; then
  bench_skip_exit "core utilities missing"
  exit 0
fi

COREMARK_BIN="$(bench_resolve_bin coremark "$BINARY" "$SCRIPT_DIR" || true)"

if [ -z "$COREMARK_BIN" ]; then
  # coremark.exe is the stock Makefile's output name even on Linux.
  COREMARK_BIN="$(bench_resolve_bin coremark.exe "" "$SCRIPT_DIR" || true)"
fi

if [ -z "$COREMARK_BIN" ] || [ ! -x "$COREMARK_BIN" ]; then
  bench_skip_exit "coremark binary not found (set BINARY= or add coremark to the image)"
  exit 0
fi

log_info "$TESTNAME: binary=$COREMARK_BIN iterations=$ITERATIONS extra_args=${EXTRA_ARGS:-none}"

if [ "$SET_PERF_GOV" = "1" ]; then
  bench_set_governor performance
fi

IPS_VALUES="$OUT_DIR/iterations_per_sec.values"
TIME_VALUES="$OUT_DIR/total_time.values"
: > "$IPS_VALUES"
: > "$TIME_VALUES"

validation_seen=0
validation_ok=1
short_runs=0
run_failures=0
last_iterations=""
last_score_line=""

BENCH_CMD_TIMEOUT="$TIMEOUT_SEC"

i=1
while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
  log_info "$TESTNAME: iteration $i/$ITERATIONS"
  runlog="$OUT_DIR/coremark_run${i}.log"

  # EXTRA_ARGS is intentionally word-split: CoreMark takes positional args.
  # shellcheck disable=SC2086
  if ! bench_run_logged "$runlog" "$COREMARK_BIN" $EXTRA_ARGS; then
    log_warn "$TESTNAME: iteration $i exited non-zero"
    run_failures=$((run_failures + 1))
  fi

  if [ ! -s "$runlog" ]; then
    log_warn "$TESTNAME: iteration $i produced no output"
    run_failures=$((run_failures + 1))
    i=$((i + 1))
    continue
  fi

  # "Iterations/Sec   : 11666.666667"
  ips="$(awk -F':' '/Iterations\/Sec/ { gsub(/[ \t]/, "", $2); print $2; exit }' "$runlog" 2>/dev/null || true)"
  # "Total time (secs): 12.000000"
  ttime="$(awk -F':' '/Total time \(secs\)/ { gsub(/[ \t]/, "", $2); print $2; exit }' "$runlog" 2>/dev/null || true)"
  # "Iterations       : 140000"
  iters="$(awk -F':' '/^Iterations[ \t]*:/ { gsub(/[ \t]/, "", $2); print $2; exit }' "$runlog" 2>/dev/null || true)"

  if [ -n "$ips" ]; then
    bench_values_add "$IPS_VALUES" "$ips" || true
  else
    log_warn "$TESTNAME: iteration $i - could not parse Iterations/Sec"
    run_failures=$((run_failures + 1))
  fi

  if [ -n "$ttime" ]; then
    bench_values_add "$TIME_VALUES" "$ttime" || true

    # CoreMark's reporting rules require a run of at least 10 seconds for a
    # score to be quotable. Shorter runs are dominated by timer granularity.
    if awk -v t="$ttime" -v m="$MIN_RUNTIME_SEC" 'BEGIN { exit !((t + 0) < (m + 0)) }'; then
      log_warn "$TESTNAME: iteration $i ran only ${ttime}s (< ${MIN_RUNTIME_SEC}s); score is not quotable"
      short_runs=$((short_runs + 1))
    fi
  fi

  [ -n "$iters" ] && last_iterations="$iters"

  if grep -q "Correct operation validated" "$runlog" 2>/dev/null; then
    validation_seen=1
  else
    validation_ok=0
    log_warn "$TESTNAME: iteration $i did not print 'Correct operation validated'"
  fi

  sl="$(grep -m 1 '^CoreMark 1\.0' "$runlog" 2>/dev/null || true)"
  [ -n "$sl" ] && last_score_line="$sl"

  i=$((i + 1))
done

# ---------------------------------------------------------------- metrics

bench_metric_from_values "coremark-iterations-per-sec" "$IPS_VALUES" "iter/s" "mean min max"

if [ -s "$TIME_VALUES" ]; then
  tmean="$(bench_values_stat "$TIME_VALUES" mean)"
  [ -n "$tmean" ] && bench_metric "coremark-total-time-mean" "pass" "$tmean" "s"
fi

if [ -s "$IPS_VALUES" ] && [ "$ITERATIONS" -gt 1 ] 2>/dev/null; then
  sd="$(bench_values_stat "$IPS_VALUES" stddev)"
  [ -n "$sd" ] && bench_metric "coremark-iterations-per-sec-stddev" "pass" "$sd" "iter/s"
fi

if [ -n "$last_iterations" ]; then
  bench_metric "coremark-iterations" "pass" "$last_iterations" "iterations"
fi

# Correctness is a real verdict, not a measurement: a CoreMark score from a
# run that failed its own CRC check is meaningless.
if [ "$validation_seen" -eq 1 ] && [ "$validation_ok" -eq 1 ]; then
  bench_metric "coremark-validation" "pass"
else
  bench_metric "coremark-validation" "fail"
fi

if [ "$short_runs" -gt 0 ]; then
  if [ "$STRICT_RUNTIME" = "1" ]; then
    bench_metric "coremark-runtime-compliant" "fail"
  else
    log_warn "$TESTNAME: $short_runs run(s) below ${MIN_RUNTIME_SEC}s; reporting as skip (set STRICT_RUNTIME=1 to fail)"
    bench_metric "coremark-runtime-compliant" "skip"
  fi
else
  bench_metric "coremark-runtime-compliant" "pass"
fi

if [ -n "$last_score_line" ]; then
  log_info "$TESTNAME: $last_score_line"
  echo "$last_score_line" > "$OUT_DIR/coremark_score_line.txt"
fi

summary="$OUT_DIR/summary.txt"
{
  echo "# $TESTNAME summary"
  echo "binary          : $COREMARK_BIN"
  echo "iterations_run  : $ITERATIONS"
  echo "run_failures    : $run_failures"
  echo "iterations_per_sec_mean : $(bench_values_stat "$IPS_VALUES" mean 2>/dev/null || echo NA)"
  echo "iterations_per_sec_min  : $(bench_values_stat "$IPS_VALUES" min 2>/dev/null || echo NA)"
  echo "iterations_per_sec_max  : $(bench_values_stat "$IPS_VALUES" max 2>/dev/null || echo NA)"
  echo "validated       : $validation_ok"
  echo "short_runs      : $short_runs"
  [ -n "$last_score_line" ] && echo "score_line      : $last_score_line"
} > "$summary"

log_info "$TESTNAME: summary written to $summary"
cat "$summary" 2>/dev/null || true

bench_finish
exit 0

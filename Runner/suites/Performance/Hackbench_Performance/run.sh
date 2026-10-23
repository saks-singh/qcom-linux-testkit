#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Hackbench wrapper for qcom-linux-testkit (performance)
# - Scheduler / IPC benchmark: groups of tasks pass messages over sockets or
#   pipes, and the figure of merit is the wall time to complete the exchange
# - Publishes the per-iteration times to LAVA as measurements
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use Hackbench_Performance.res for gating.
# - This is the performance counterpart to Kernel/RT-tests/Hackbench. That
#   suite resolves the binary with a plain PATH lookup, which is why it SKIPped
#   on an image that has the workload available but not as /usr/bin/hackbench.
#   Two things are different here:
#     1. rt-tests' own install locations are searched, not just PATH;
#     2. if there is no hackbench binary at all, "perf bench sched messaging"
#        is used instead - it IS hackbench, imported into perf's bench suite,
#        so the workload is the same even though the binary is not.
# - The engine is part of the case id (hackbench- vs hackbench-perf-bench-),
#   because the two implementations are not interchangeable to the decimal
#   point and averaging them into one series would hide which ran.

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

TESTNAME="Hackbench_Performance"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
ITERATIONS="${ITERATIONS:-10}"
GRPS="${GRPS:-10}"
LOOPS="${LOOPS:-100}"
FDS="${FDS:-20}"
DATASIZE="${DATASIZE:-100}"
PIPE="${PIPE:-0}"
THREADS="${THREADS:-0}"
BINARY="${BINARY:-}"
HACKBENCH_DIR="${HACKBENCH_DIR:-}"
ALLOW_PERF_BENCH="${ALLOW_PERF_BENCH:-1}"
SET_PERF_GOV="${SET_PERF_GOV:-1}"
TIMEOUT_SEC="${TIMEOUT_SEC:-900}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR          output directory (default: $OUT_DIR)
  --iterations N         repeats (default: $ITERATIONS)
  --grps N               process/thread groups, hackbench -g (default: $GRPS)
  --loops N              messages per pair, hackbench -l (default: $LOOPS)
  --fds N                file descriptors per group, hackbench -f (default: $FDS)
  --datasize BYTES       message size, hackbench -s (default: $DATASIZE)
  --pipe 0|1             use pipes instead of sockets (default: $PIPE)
  --threads 0|1          use threads instead of processes (default: $THREADS)
  --binary PATH          explicit hackbench binary
  --hackbench-dir DIR    directory holding the binary
  --allow-perf-bench 0|1 fall back to "perf bench sched messaging" when no
                         hackbench binary exists (default: $ALLOW_PERF_BENCH)
  --set-perf-gov 0|1     pin CPUs to the performance governor (default: $SET_PERF_GOV)
  --timeout-sec N        per-run timeout (default: $TIMEOUT_SEC)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --grps) GRPS="$2"; shift 2 ;;
    --loops) LOOPS="$2"; shift 2 ;;
    --fds) FDS="$2"; shift 2 ;;
    --datasize) DATASIZE="$2"; shift 2 ;;
    --pipe) PIPE="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --hackbench-dir) HACKBENCH_DIR="$2"; shift 2 ;;
    --allow-perf-bench) ALLOW_PERF_BENCH="$2"; shift 2 ;;
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

case "$ITERATIONS" in ''|*[!0-9]*|0) ITERATIONS=10 ;; esac

bench_init "$TESTNAME" "$OUT_DIR" "$test_path" || exit 0
bench_log_env

if ! bench_require_cmds awk grep sed; then
  bench_skip_exit "core utilities missing"
  exit 0
fi

# ---------------------------------------------------------------- resolve

# rt-tests is packaged in several different places depending on the
# distribution, and on an image built without the package the workload may
# still be reachable through perf. Probe all of it before giving up, and log
# what was tried so a SKIP is diagnosable from the job log alone.
HB_DIRS="$HACKBENCH_DIR /usr/bin /bin /usr/sbin /sbin /usr/local/bin
         /usr/lib/rt-tests /usr/libexec/rt-tests /usr/share/rt-tests
         /opt/rt-tests /opt/rt-tests/bin /home/root /data /usr/lib/perf-core"

# shellcheck disable=SC2086
BIN="$(bench_resolve_bin hackbench "$BINARY" $HB_DIRS || true)"

ENGINE=""
if [ -n "$BIN" ] && [ -x "$BIN" ]; then
  ENGINE="hackbench"
  log_info "$TESTNAME: using hackbench binary $BIN"
else
  log_warn "$TESTNAME: no hackbench binary found (searched PATH and: $(echo $HB_DIRS | tr -s ' '))"

  if [ "$ALLOW_PERF_BENCH" = "1" ]; then
    PERF_BIN="$(bench_resolve_bin perf "" /usr/bin /bin /usr/local/bin || true)"

    if [ -n "$PERF_BIN" ] && [ -x "$PERF_BIN" ]; then
      # Presence of perf is not enough: the bench subcommand is a build-time
      # option, and on a stripped perf it is absent. Ask before relying on it.
      if "$PERF_BIN" bench sched --help >/dev/null 2>&1 ||
         "$PERF_BIN" bench sched messaging --help >/dev/null 2>&1; then
        ENGINE="perf-bench"
        BIN="$PERF_BIN"
        log_info "$TESTNAME: no hackbench binary; using '$PERF_BIN bench sched messaging' (same workload)"
      else
        log_warn "$TESTNAME: $PERF_BIN has no usable 'bench sched messaging'"
      fi
    fi
  fi
fi

if [ -z "$ENGINE" ]; then
  bench_skip_exit "no hackbench binary and no usable 'perf bench sched messaging' (use --binary/--hackbench-dir, or add rt-tests or perf to the image)"
  exit 0
fi

# ---------------------------------------------------------------- run

[ "$SET_PERF_GOV" = "1" ] && bench_set_governor performance

BENCH_CMD_TIMEOUT="$TIMEOUT_SEC"
vals="$OUT_DIR/time.values"
: > "$vals"

log_info "$TESTNAME: engine=$ENGINE iterations=$ITERATIONS grps=$GRPS loops=$LOOPS fds=$FDS datasize=$DATASIZE pipe=$PIPE threads=$THREADS"

i=1
while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
  runlog="$OUT_DIR/${ENGINE}_run${i}.log"

  if [ "$ENGINE" = "hackbench" ]; then
    set -- "$BIN" -s "$DATASIZE" -l "$LOOPS" -g "$GRPS" -f "$FDS"
    [ "$PIPE" = "1" ] && set -- "$@" -p
    [ "$THREADS" = "1" ] && set -- "$@" -T
  else
    # perf's port takes groups and loops; it has no -f/-s equivalent, so those
    # are not silently pretended to apply.
    set -- "$BIN" bench sched messaging -g "$GRPS" -l "$LOOPS"
    [ "$PIPE" = "1" ] && set -- "$@" -p
    [ "$THREADS" = "1" ] && set -- "$@" -t
  fi

  bench_run_logged "$runlog" "$@" || true

  # hackbench:  "Time: 0.123"
  # perf bench: "Total time: 0.123 [sec]"
  t="$(
    awk '
      /[Tt]ime:/ {
        for (j = 1; j <= NF; j++) {
          if ($j ~ /[Tt]ime:/ && (j + 1) <= NF) {
            v = $(j+1)
            gsub(/[^0-9.]/, "", v)
            if (v ~ /^[0-9]+([.][0-9]+)?$/) { print v; exit }
          }
        }
      }
    ' "$runlog" 2>/dev/null || true
  )"

  if [ -n "$t" ]; then
    bench_values_add "$vals" "$t" || true
  else
    log_warn "$TESTNAME: iteration $i - no time parsed"
    tail -10 "$runlog" 2>/dev/null || true
  fi

  i=$((i + 1))
done

[ "$SET_PERF_GOV" = "1" ] && bench_restore_governor

case "$ENGINE" in
  hackbench)  ID_PREFIX="hackbench-time" ;;
  perf-bench) ID_PREFIX="hackbench-perf-bench-sched-messaging-time" ;;
esac

if [ -s "$vals" ]; then
  bench_metric_from_values "$ID_PREFIX" "$vals" "s" "mean min max"
else
  log_fail "$TESTNAME: no times parsed from any iteration"
  bench_metric "$ID_PREFIX" "fail"
fi

summary="$OUT_DIR/summary.txt"
{
  echo "# $TESTNAME summary (lower is better)"
  echo "engine      : $ENGINE"
  echo "binary      : $BIN"
  echo "grps        : $GRPS"
  echo "loops       : $LOOPS"
  if [ "$ENGINE" = "hackbench" ]; then
    echo "fds         : $FDS"
    echo "datasize    : $DATASIZE"
  else
    echo "# perf bench sched messaging has no -f/-s equivalent; fds and"
    echo "# datasize above do not apply to this engine"
  fi
  echo "pipe        : $PIPE"
  echo "threads     : $THREADS"
  echo "iterations  : $ITERATIONS"
  if [ -s "$vals" ]; then
    echo "time mean   : $(bench_values_stat "$vals" mean) s"
    echo "time min    : $(bench_values_stat "$vals" min) s"
    echo "time max    : $(bench_values_stat "$vals" max) s"
  fi
  echo "# a hackbench time is only comparable against a run with the same"
  echo "# engine, group count, loop count and transport as recorded above"
} > "$summary"

log_info "$TESTNAME: summary written to $summary"
cat "$summary" 2>/dev/null || true

bench_finish
exit 0

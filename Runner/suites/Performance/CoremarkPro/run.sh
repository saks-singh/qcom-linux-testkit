#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# CoreMark-PRO wrapper for qcom-linux-testkit
# - Drives EEMBC CoreMark-PRO's certify-all run
# - Publishes the MARK RESULTS TABLE (MultiCore / SingleCore / Scaling) and,
#   optionally, every row of the WORKLOAD RESULTS TABLE, as LAVA measurements
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use CoremarkPro.res for gating.
# - qcom-distro images ship the nine CoreMark-PRO workload binaries in
#   /usr/bin (meta-oe coremark-pro, via packagegroup-qcom-benchmark). By
#   default they are found there (or anywhere on PATH) and run by certify.sh,
#   which follows upstream's certify-all procedure and prints the same tables.
# - --bin-dir points at another directory of workload binaries; --dir at an
#   EEMBC source tree (driven by make certify-all when make and perl exist,
#   otherwise its prebuilt builds/<target>/<toolchain>/bin is used); --run-cmd
#   supplies a completely custom invocation; --from-log parses a run someone
#   else produced.
# - Scaling is MultiCore/SingleCore, so it is the headline number for how well
#   the platform uses its cores. A scaling figure well below the core count
#   usually means memory bandwidth or thermal limits, not a CoreMark-PRO fault.

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

TESTNAME="CoremarkPro"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
CMP_DIR="${CMP_DIR:-}"
CMP_BIN_DIR="${CMP_BIN_DIR:-}"
TARGET="${TARGET:-linux64}"
CORES="${CORES:-NPROC}"
CONTEXTS="${CONTEXTS:-}"
RUN_CMD="${RUN_CMD:-}"
FROM_LOG="${FROM_LOG:-}"
PER_WORKLOAD="${PER_WORKLOAD:-1}"
SET_PERF_GOV="${SET_PERF_GOV:-1}"
TIMEOUT_SEC="${TIMEOUT_SEC:-3600}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR        output directory (default: $OUT_DIR)
  --bin-dir DIR        directory holding the workload binaries
                       (default: found in /usr/bin or on PATH)
  --dir DIR            CoreMark-PRO source tree (containing builds/ and util/)
  --target NAME        EEMBC TARGET passed to make (default: $TARGET)
  --cores N|NPROC      worker count for the multicore pass (default: $CORES)
  --contexts N         override contexts; default is derived from --cores
  --run-cmd CMD        run this instead of the built-in make invocation
  --from-log FILE      skip running; parse an existing CoreMark-PRO log
  --per-workload 0|1   emit every WORKLOAD RESULTS TABLE row (default: $PER_WORKLOAD)
  --set-perf-gov 0|1   pin CPU governor to performance (default: $SET_PERF_GOV)
  --timeout-sec N      timeout for the whole run (default: $TIMEOUT_SEC)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --bin-dir) CMP_BIN_DIR="$2"; shift 2 ;;
    --dir) CMP_DIR="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --contexts) CONTEXTS="$2"; shift 2 ;;
    --run-cmd) RUN_CMD="$2"; shift 2 ;;
    --from-log) FROM_LOG="$2"; shift 2 ;;
    --per-workload) PER_WORKLOAD="$2"; shift 2 ;;
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

if ! bench_require_cmds awk grep sed; then
  bench_skip_exit "core utilities missing"
  exit 0
fi

RUNLOG="$OUT_DIR/coremark_pro_run.log"

# ---------------------------------------------------------------- obtain a log

if [ -n "$FROM_LOG" ]; then
  if [ ! -f "$FROM_LOG" ]; then
    bench_skip_exit "--from-log file not found: $FROM_LOG"
    exit 0
  fi
  log_info "$TESTNAME: parsing existing log $FROM_LOG (no run performed)"
  cp "$FROM_LOG" "$RUNLOG" 2>/dev/null || RUNLOG="$FROM_LOG"
else
  NCORES="$(bench_resolve_threads "$CORES")"
  [ -n "$CONTEXTS" ] || CONTEXTS="$NCORES"

  # Workloads certify.sh runs; a directory holding all of them, named
  # <workload> or <workload>.exe, is a usable binary directory.
  CMP_WORKLOADS="cjpeg-rose7-preset core linear_alg-mid-100x100-sp loops-all-mid-10k-sp nnet_test parser-125k radix2-big-64k sha-test zip-test"

  has_workloads() {
    for w in $CMP_WORKLOADS; do
      if [ ! -x "$1/$w" ] && [ ! -x "$1/$w.exe" ]; then
        return 1
      fi
    done
    return 0
  }

  if [ -z "$RUN_CMD" ]; then
    if [ -n "$CMP_BIN_DIR" ]; then
      if ! has_workloads "$CMP_BIN_DIR"; then
        bench_skip_exit "CoreMark-PRO workload binaries not all present in --bin-dir $CMP_BIN_DIR"
        exit 0
      fi
    elif [ -z "$CMP_DIR" ]; then
      # Binaries shipped in the image: /usr/bin first, then wherever PATH
      # finds them.
      for d in /usr/bin /usr/local/bin; do
        if has_workloads "$d"; then
          CMP_BIN_DIR="$d"
          break
        fi
      done
      if [ -z "$CMP_BIN_DIR" ]; then
        p="$(command -v loops-all-mid-10k-sp 2>/dev/null || true)"
        if [ -n "$p" ] && has_workloads "$(dirname "$p")"; then
          CMP_BIN_DIR="$(dirname "$p")"
        fi
      fi
      # Otherwise fall back to a CoreMark-PRO source tree.
      if [ -z "$CMP_BIN_DIR" ]; then
        for d in "$SCRIPT_DIR/coremark-pro" "/opt/coremark-pro" \
                 "/usr/share/coremark-pro" "$HOME/coremark-pro"; do
          if [ -d "$d" ] && [ -d "$d/builds" ]; then
            CMP_DIR="$d"
            break
          fi
        done
      fi
    fi

    if [ -z "$CMP_BIN_DIR" ]; then
      if [ -z "$CMP_DIR" ] || [ ! -d "$CMP_DIR" ]; then
        bench_skip_exit "CoreMark-PRO binaries not found in the image (use --bin-dir, --dir, --run-cmd or --from-log)"
        exit 0
      fi

      if command -v make >/dev/null 2>&1 && command -v perl >/dev/null 2>&1 \
         && [ -f "$CMP_DIR/Makefile" ]; then
        log_info "$TESTNAME: tree=$CMP_DIR target=$TARGET cores=$NCORES contexts=$CONTEXTS"
        RUN_CMD="cd '$CMP_DIR' && make TARGET=$TARGET XCMD='-c$CONTEXTS' certify-all"
      else
        # No make/perl: run the tree's prebuilt workloads with certify.sh.
        for d in "$CMP_DIR"/builds/"$TARGET"/*/bin; do
          if has_workloads "$d"; then
            CMP_BIN_DIR="$d"
            break
          fi
        done
        if [ -z "$CMP_BIN_DIR" ]; then
          bench_skip_exit "make/perl not available and no prebuilt binaries under $CMP_DIR/builds/$TARGET"
          exit 0
        fi
      fi
    fi

    if [ -z "$RUN_CMD" ]; then
      log_info "$TESTNAME: running workload binaries in $CMP_BIN_DIR cores=$NCORES contexts=$CONTEXTS"
      RUN_CMD="sh '$SCRIPT_DIR/certify.sh' --bin-dir '$CMP_BIN_DIR' --contexts $CONTEXTS"
    fi
  else
    log_info "$TESTNAME: using custom run command"
  fi

  if [ "$SET_PERF_GOV" = "1" ]; then
    bench_set_governor performance
  fi

  log_info "$TESTNAME: running: $RUN_CMD"
  log_info "$TESTNAME: this takes a while; output is captured to $RUNLOG"

  if command -v run_with_timeout >/dev/null 2>&1; then
    run_with_timeout "$TIMEOUT_SEC" sh -c "$RUN_CMD" > "$RUNLOG" 2>&1
    rc=$?
  else
    sh -c "$RUN_CMD" > "$RUNLOG" 2>&1
    rc=$?
  fi

  if [ "$rc" -ne 0 ]; then
    log_warn "$TESTNAME: run command exited rc=$rc; attempting to parse output anyway"
    tail -30 "$RUNLOG" 2>/dev/null || true
  fi
fi

if [ ! -s "$RUNLOG" ]; then
  log_fail "$TESTNAME: no output produced"
  bench_metric "coremarkpro-run" "fail"
  bench_finish FAIL
  exit 0
fi

# ---------------------------------------------------------------- parse

# MARK RESULTS TABLE
#
# Mark Name                                   MultiCore SingleCore    Scaling
# CoreMark-PRO                                  7271.65    2568.72       2.83
MARK_LINE="$(
  awk '
    /MARK RESULTS TABLE/ { inmark = 1; next }
    inmark && /^CoreMark-PRO/ { print; exit }
  ' "$RUNLOG" 2>/dev/null || true
)"

if [ -z "$MARK_LINE" ]; then
  log_warn "$TESTNAME: could not find the CoreMark-PRO row of the MARK RESULTS TABLE"
  log_info "$TESTNAME: last 30 lines of output follow"
  tail -30 "$RUNLOG" 2>/dev/null || true
  bench_metric "coremarkpro-mark-parsed" "fail"
  bench_finish FAIL
  exit 0
fi

log_info "$TESTNAME: mark row: $MARK_LINE"
bench_metric "coremarkpro-mark-parsed" "pass"

mc="$(printf '%s\n' "$MARK_LINE" | awk '{ print $(NF-2) }')"
sc="$(printf '%s\n' "$MARK_LINE" | awk '{ print $(NF-1) }')"
sg="$(printf '%s\n' "$MARK_LINE" | awk '{ print $NF }')"

if bench_is_number "$mc"; then
  bench_metric "coremarkpro-multicore" "pass" "$mc" "iter/s"
else
  bench_metric "coremarkpro-multicore" "fail"
fi

if bench_is_number "$sc"; then
  bench_metric "coremarkpro-singlecore" "pass" "$sc" "iter/s"
else
  bench_metric "coremarkpro-singlecore" "fail"
fi

if bench_is_number "$sg"; then
  bench_metric "coremarkpro-scaling" "pass" "$sg" "ratio"
else
  bench_metric "coremarkpro-scaling" "fail"
fi

# ---------------------------------------------------------------- per workload

if [ "$PER_WORKLOAD" = "1" ]; then
  WL_TABLE="$OUT_DIR/workload_table.txt"

  # Rows between the two table headers that carry three trailing numbers.
  awk '
    /WORKLOAD RESULTS TABLE/ { inwl = 1; next }
    /MARK RESULTS TABLE/     { inwl = 0 }
    inwl && NF >= 4 {
      mc = $(NF-2); sc = $(NF-1); sg = $NF
      numre = "^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)$"
      if (mc ~ numre && sc ~ numre && sg ~ numre) {
        print $1, mc, sc, sg
      }
    }
  ' "$RUNLOG" > "$WL_TABLE" 2>/dev/null || true

  if [ -s "$WL_TABLE" ]; then
    log_info "$TESTNAME: per-workload rows parsed: $(wc -l < "$WL_TABLE" 2>/dev/null || echo 0)"

    while IFS= read -r row; do
      [ -n "$row" ] || continue

      wname="$(printf '%s\n' "$row" | awk '{ print $1 }')"
      wmc="$(printf '%s\n' "$row" | awk '{ print $2 }')"
      wsc="$(printf '%s\n' "$row" | awk '{ print $3 }')"
      wsg="$(printf '%s\n' "$row" | awk '{ print $4 }')"

      # Case ids must be token-safe for LAVA; workload names contain dots.
      wid="$(printf '%s' "$wname" | tr -c '[:alnum:]_.:-' '-')"

      bench_metric "coremarkpro-workload-${wid}-multicore" "pass" "$wmc" "iter/s"
      bench_metric "coremarkpro-workload-${wid}-singlecore" "pass" "$wsc" "iter/s"
      bench_metric "coremarkpro-workload-${wid}-scaling" "pass" "$wsg" "ratio"
    done < "$WL_TABLE"
  else
    log_warn "$TESTNAME: WORKLOAD RESULTS TABLE not parsed (mark results still reported)"
  fi
fi

summary="$OUT_DIR/summary.txt"
{
  echo "# $TESTNAME summary"
  echo "log        : $RUNLOG"
  echo "mark_row   : $MARK_LINE"
  echo "multicore  : ${mc:-NA} iter/s"
  echo "singlecore : ${sc:-NA} iter/s"
  echo "scaling    : ${sg:-NA}"
} > "$summary"

log_info "$TESTNAME: summary written to $summary"
cat "$summary" 2>/dev/null || true

bench_finish
exit 0

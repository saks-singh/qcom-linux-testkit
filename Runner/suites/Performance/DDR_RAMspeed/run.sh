#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# RAMspeed / RAMsmp wrapper for qcom-linux-testkit
# - Measures DDR speed with RAMspeed's Copy / Scale / Add / Triad kernels
# - Publishes every reported figure to LAVA as a measurement in MB/s
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use DDR_RAMspeed.res for gating.
# - RAMspeed and lmbench measure different things and will not agree. lmbench's
#   bw_mem times one simple loop; RAMspeed's *mem benchmarks run the four
#   STREAM-style kernels and report their average. Track both, compare neither.
# - The binary is called ramspeed on uniprocessor builds and ramsmp on the SMP
#   build; ramsmp additionally takes -p for the process count. Both are
#   accepted and -p is only passed when the binary is ramsmp.
# - Benchmark indices are RAMspeed's own -b values. The defaults are the two
#   *mem benchmarks, which are the ones that produce Copy/Scale/Add/Triad and
#   an AVERAGE; the *mark benchmarks instead sweep block sizes and are
#   reported per block when requested.

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

TESTNAME="DDR_RAMspeed"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
# 3 = INTmem, 6 = FLOATmem in RAMspeed's -b numbering.
BENCHMARKS="${BENCHMARKS:-3 6}"
GB_PER_PASS="${GB_PER_PASS:-1}"
LOOPS="${LOOPS:-1}"
BLOCK_KB="${BLOCK_KB:-}"
PROCESSES="${PROCESSES:-}"
ITERATIONS="${ITERATIONS:-1}"
RAMSPEED_BIN="${RAMSPEED_BIN:-}"
RAMSPEED_DIR="${RAMSPEED_DIR:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
SET_PERF_GOV="${SET_PERF_GOV:-1}"
TIMEOUT_SEC="${TIMEOUT_SEC:-1800}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR        output directory (default: $OUT_DIR)
  --benchmarks "LIST"  RAMspeed -b indices (default: $BENCHMARKS)
                       1 INTmark-write 2 INTmark-read 3 INTmem
                       4 FLOATmark-write 5 FLOATmark-read 6 FLOATmem
  --gb-per-pass N      RAMspeed -g, Gbytes moved per pass (default: $GB_PER_PASS)
  --loops N            RAMspeed -l, loops per pass (default: $LOOPS)
  --block-kb N         RAMspeed -m, block size for the *mark benchmarks
  --processes N        ramsmp -p, process count (ramsmp only)
  --iterations N       repeats per benchmark (default: $ITERATIONS)
  --binary PATH        explicit ramspeed/ramsmp binary
  --ramspeed-dir DIR   directory holding the binary
  --extra-args "ARGS"  extra arguments appended verbatim
  --set-perf-gov 0|1   pin CPU governor to performance (default: $SET_PERF_GOV)
  --timeout-sec N      per-run timeout (default: $TIMEOUT_SEC)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --benchmarks) BENCHMARKS="$2"; shift 2 ;;
    --gb-per-pass) GB_PER_PASS="$2"; shift 2 ;;
    --loops) LOOPS="$2"; shift 2 ;;
    --block-kb) BLOCK_KB="$2"; shift 2 ;;
    --processes) PROCESSES="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --binary) RAMSPEED_BIN="$2"; shift 2 ;;
    --ramspeed-dir) RAMSPEED_DIR="$2"; shift 2 ;;
    --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
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

# ---------------------------------------------------------------- binary

BIN=""
for cand in ramspeed ramsmp; do
  BIN="$(bench_resolve_bin "$cand" "$RAMSPEED_BIN" "$RAMSPEED_DIR" \
         "$SCRIPT_DIR" "$SCRIPT_DIR/bin" || true)"
  [ -n "$BIN" ] && break
  # An explicit --binary that did not resolve is a hard miss, not a reason to
  # go looking for the other name.
  [ -n "$RAMSPEED_BIN" ] && break
done

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  bench_skip_exit "ramspeed/ramsmp not found (use --binary or --ramspeed-dir, or add ramspeed to the image)"
  exit 0
fi

BIN_BASE="$(basename "$BIN")"
log_info "$TESTNAME: binary=$BIN"

if [ -n "$PROCESSES" ] && [ "$BIN_BASE" != "ramsmp" ]; then
  log_warn "$TESTNAME: --processes is a ramsmp option; ignoring it for $BIN_BASE"
  PROCESSES=""
fi

# ---------------------------------------------------------------- helpers

# bench_label <index> - RAMspeed's own name for a -b index, for readable ids.
bench_label() {
  case "$1" in
    1) echo "intmark-writing" ;;
    2) echo "intmark-reading" ;;
    3) echo "intmem" ;;
    4) echo "floatmark-writing" ;;
    5) echo "floatmark-reading" ;;
    6) echo "floatmem" ;;
    7) echo "mmxmark-writing" ;;
    8) echo "mmxmark-reading" ;;
    9) echo "mmxmem" ;;
    *) echo "bench$1" ;;
  esac
}

# ramspeed_parse <logfile>
#
# Emits "<key> <value>" lines. Handles both output shapes RAMspeed produces:
#   INTmem   Copy:      5000.00 MB/s                  -> "copy 5000.00"
#   INTmem   AVERAGE:   5012.50 MB/s                  -> "average 5012.50"
#   1 Kb block: 23456.78 MB/s                         -> "block-1kb 23456.78"
#   INTEGER  Writing:   4 Kb block: 33210.50 MB/s     -> "block-4kb 33210.50"
#
# The value is always the number immediately preceding the MB/s token, never
# "the first number after the colon": the *mark rows carry a block size in
# between, and reading that as the bandwidth yields a plausible-looking but
# completely wrong measurement. Block rows are detected before kernel rows for
# the same reason - they contain a colon too.
ramspeed_parse() {
  awk '
    $0 ~ /MB\/s/ {
      # Value: the last number appearing before the MB/s token.
      val = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /MB\/s/) { break }
        if ($i ~ /^[0-9]+([.][0-9]+)?$/) { val = $i }
        # Also catch a value glued to the unit, e.g. "5000.00MB/s".
        else if ($i ~ /^[0-9]+([.][0-9]+)?MB\/s$/) {
          sub(/MB\/s$/, "", $i); val = $i; break
        }
      }
      if (val == "") { next }

      line = tolower($0)

      # Block-size rows: "<n> <K|M>b block:". Take the size token pair that
      # sits immediately before the word "block".
      if (index(line, "block") > 0) {
        key = ""
        for (i = 1; i <= NF; i++) {
          if (tolower($i) ~ /^block/) {
            if (i >= 3 && $(i-2) ~ /^[0-9]+$/ && tolower($(i-1)) ~ /^[kmg]b?$/) {
              key = "block-" $(i-2) tolower(substr($(i-1), 1, 1)) "b"
            } else if (i >= 2 && tolower($(i-1)) ~ /^[0-9]+[kmg]b?$/) {
              key = "block-" tolower($(i-1))
              if (key !~ /b$/) { key = key "b" }
            }
            break
          }
        }
        if (key != "") { printf "%s %s\n", key, val; next }
        # Fall through: a line mentioning "block" we could not size.
      }

      # Kernel rows: "<label> <Op>: <value> MB/s". The operation name is the
      # last word before the first colon.
      if (index($0, ":") > 0) {
        split($0, f, ":")
        head = f[1]
        gsub(/[ \t]+$/, "", head)
        nh = split(head, hw, /[ \t]+/)
        op = tolower(hw[nh])
        gsub(/[^a-z0-9]/, "", op)
        if (op != "") { printf "%s %s\n", op, val }
      }
    }
  ' "$1" 2>/dev/null
}

if [ "$SET_PERF_GOV" = "1" ]; then
  bench_set_governor performance
fi

log_info "$TESTNAME: benchmarks='$BENCHMARKS' gb_per_pass=$GB_PER_PASS loops=$LOOPS iterations=$ITERATIONS"

BENCH_CMD_TIMEOUT="$TIMEOUT_SEC"
produced_any=0

for b in $BENCHMARKS; do
  label="$(bench_label "$b")"
  # Accumulate per-operation samples across iterations in separate files.
  opdir="$OUT_DIR/$label"
  mkdir -p "$opdir" 2>/dev/null || true

  i=1
  while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
    runlog="$OUT_DIR/${label}_run${i}.log"

    set -- "$BIN" -b "$b" -g "$GB_PER_PASS" -l "$LOOPS"
    [ -n "$BLOCK_KB" ] && set -- "$@" -m "$BLOCK_KB"
    [ -n "$PROCESSES" ] && set -- "$@" -p "$PROCESSES"
    # Word splitting is intended here: EXTRA_ARGS is a flag string.
    # shellcheck disable=SC2086
    [ -n "$EXTRA_ARGS" ] && set -- "$@" $EXTRA_ARGS

    bench_run_logged "$runlog" "$@" || true

    parsed="$(ramspeed_parse "$runlog")"

    if [ -z "$parsed" ]; then
      log_warn "$TESTNAME: $label iteration $i - no parsable MB/s rows"
      head -20 "$runlog" 2>/dev/null || true
      i=$((i + 1))
      continue
    fi

    printf '%s\n' "$parsed" | while IFS=' ' read -r op val; do
      [ -n "$op" ] || continue
      bench_values_add "$opdir/${op}.values" "$val" >/dev/null 2>&1 || true
    done

    i=$((i + 1))
  done

  # Report whatever operations this benchmark actually produced.
  found=0
  for vf in "$opdir"/*.values; do
    [ -f "$vf" ] || continue
    op="$(basename "$vf" .values)"
    found=1
    produced_any=1

    if [ "$ITERATIONS" -gt 1 ] 2>/dev/null; then
      bench_metric_from_values "ramspeed-${label}-${op}" "$vf" "MB/s" "mean min max"
    else
      bench_metric_from_values "ramspeed-${label}-${op}" "$vf" "MB/s" "mean"
    fi
  done

  if [ "$found" -eq 0 ]; then
    log_fail "$TESTNAME: $label produced no results"
    bench_metric "ramspeed-${label}" "fail"
  fi
done

if [ "$produced_any" -eq 0 ]; then
  log_fail "$TESTNAME: no RAMspeed figures were parsed from any benchmark"
  bench_finish FAIL
  exit 0
fi

summary="$OUT_DIR/summary.txt"
{
  echo "# $TESTNAME summary (MB/s)"
  echo "binary      : $BIN"
  echo "gb_per_pass : $GB_PER_PASS"
  for b in $BENCHMARKS; do
    label="$(bench_label "$b")"
    echo "[$label]"
    for vf in "$OUT_DIR/$label"/*.values; do
      [ -f "$vf" ] || continue
      printf '  %-12s %s\n' "$(basename "$vf" .values)" \
        "$(bench_values_stat "$vf" mean)"
    done
  done
} > "$summary"

log_info "$TESTNAME: summary written to $summary"
cat "$summary" 2>/dev/null || true

bench_finish
exit 0

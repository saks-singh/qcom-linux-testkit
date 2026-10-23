#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# DDR bandwidth and latency via lmbench, for qcom-linux-testkit
# - bw_mem for each requested operation (rd frd wr fwr bzero cp bcopy ...)
# - lat_mem_rd for cache and main-memory read latency
# - Publishes every number to LAVA as a measurement
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use DDR_Lmbench.res for gating.
# - lmbench's bw_mem and lat_mem_rd write their results to stderr, not stdout,
#   so output is captured with 2>&1 throughout. Parsing stdout alone yields
#   nothing, which is an easy and silent way to get an empty result set.
# - bw_mem reports MB/s where MB is 10^6 bytes, matching lmbench's own
#   convention. It is not MiB/s; do not compare directly against tools that
#   report powers of two without converting.
# - The working-set size matters more than any other parameter here: too small
#   and the test measures cache rather than DDR. 128M is the default because
#   it exceeds the last-level cache on current Qualcomm platforms.

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

TESTNAME="DDR_Lmbench"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
SIZE="${SIZE:-128M}"
BW_OPS="${BW_OPS:-rd frd wr fwr bzero cp bcopy}"
RUN_BW="${RUN_BW:-1}"
RUN_LAT="${RUN_LAT:-1}"
LAT_SIZE="${LAT_SIZE:-256M}"
LAT_STRIDE="${LAT_STRIDE:-128}"
# Run a second, randomised latency sweep (lat_mem_rd -t). A fixed stride is
# perfectly predictable to the hardware prefetcher, so the strided sweep above
# reports prefetched streaming latency - the first lab run produced 7.3 ns for
# "main memory", which is a cache-line-ahead prefetch, not a DRAM access. The
# randomised pointer chase defeats the prefetcher and is the figure to quote
# as unloaded memory latency. Both are published, under separate case ids, so
# the strided series stays comparable with earlier runs.
LAT_RANDOM="${LAT_RANDOM:-1}"
L1_SIZE="${L1_SIZE:-0.00098}"
L2_SIZE="${L2_SIZE:-0.125}"
ITERATIONS="${ITERATIONS:-3}"
PARALLELISM="${PARALLELISM:-1}"
WARMUPS="${WARMUPS:-}"
REPETITIONS="${REPETITIONS:-}"
BW_MEM_BIN="${BW_MEM_BIN:-}"
LAT_MEM_RD_BIN="${LAT_MEM_RD_BIN:-}"
LMBENCH_DIR="${LMBENCH_DIR:-}"
SET_PERF_GOV="${SET_PERF_GOV:-1}"
TIMEOUT_SEC="${TIMEOUT_SEC:-900}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR          output directory (default: $OUT_DIR)
  --size SIZE            bw_mem working set, e.g. 128M (default: $SIZE)
  --bw-ops "LIST"        bw_mem operations (default: $BW_OPS)
                         known: rd wr rdwr cp frd fwr fcp bzero bcopy
  --run-bw 0|1           run the bandwidth tests (default: $RUN_BW)
  --run-lat 0|1          run the latency test (default: $RUN_LAT)
  --lat-size SIZE        lat_mem_rd working set (default: $LAT_SIZE)
  --lat-stride N         lat_mem_rd stride (default: $LAT_STRIDE)
  --lat-random 0|1       also run a randomised sweep (lat_mem_rd -t), which is
                         the one that measures real DRAM latency rather than
                         prefetched streaming latency (default: $LAT_RANDOM)
  --l1-size MB           array size reported as L1, in MB (default: $L1_SIZE)
  --l2-size MB           array size reported as L2, in MB (default: $L2_SIZE)
  --iterations N         repeats per measurement (default: $ITERATIONS)
  --parallelism N        bw_mem -P value (default: $PARALLELISM)
  --warmups N            bw_mem -W value (default: none)
  --repetitions N        bw_mem -N value (default: none)
  --bw-mem-bin PATH      explicit bw_mem binary
  --lat-mem-rd-bin PATH  explicit lat_mem_rd binary
  --lmbench-dir DIR      directory holding the lmbench binaries
  --set-perf-gov 0|1     pin CPU governor to performance (default: $SET_PERF_GOV)
  --timeout-sec N        per-run timeout (default: $TIMEOUT_SEC)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --bw-ops) BW_OPS="$2"; shift 2 ;;
    --run-bw) RUN_BW="$2"; shift 2 ;;
    --run-lat) RUN_LAT="$2"; shift 2 ;;
    --lat-size) LAT_SIZE="$2"; shift 2 ;;
    --lat-stride) LAT_STRIDE="$2"; shift 2 ;;
    --lat-random) LAT_RANDOM="$2"; shift 2 ;;
    --l1-size) L1_SIZE="$2"; shift 2 ;;
    --l2-size) L2_SIZE="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --parallelism) PARALLELISM="$2"; shift 2 ;;
    --warmups) WARMUPS="$2"; shift 2 ;;
    --repetitions) REPETITIONS="$2"; shift 2 ;;
    --bw-mem-bin) BW_MEM_BIN="$2"; shift 2 ;;
    --lat-mem-rd-bin) LAT_MEM_RD_BIN="$2"; shift 2 ;;
    --lmbench-dir) LMBENCH_DIR="$2"; shift 2 ;;
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

# lmbench size arguments are lowercase-suffixed (128m, 4k). Accept either.
size_norm() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Token-safe size for LAVA case ids: 128M -> 128m
size_tag() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -dc '[:alnum:]'
}

SIZE_ARG="$(size_norm "$SIZE")"
SIZE_TAG="$(size_tag "$SIZE")"
LAT_SIZE_ARG="$(size_norm "$LAT_SIZE")"

BW_BIN=""
LAT_BIN=""

if [ "$RUN_BW" = "1" ]; then
  BW_BIN="$(bench_resolve_bin bw_mem "$BW_MEM_BIN" "$LMBENCH_DIR" "$SCRIPT_DIR" "$SCRIPT_DIR/bin" || true)"
fi

if [ "$RUN_LAT" = "1" ]; then
  LAT_BIN="$(bench_resolve_bin lat_mem_rd "$LAT_MEM_RD_BIN" "$LMBENCH_DIR" "$SCRIPT_DIR" "$SCRIPT_DIR/bin" || true)"
fi

if [ -z "$BW_BIN" ] && [ -z "$LAT_BIN" ]; then
  bench_skip_exit "neither bw_mem nor lat_mem_rd found (use --lmbench-dir, or add lmbench to the image)"
  exit 0
fi

if [ "$SET_PERF_GOV" = "1" ]; then
  bench_set_governor performance
fi

log_info "$TESTNAME: size=$SIZE_ARG ops='$BW_OPS' iterations=$ITERATIONS parallelism=$PARALLELISM"
log_info "$TESTNAME: bw_mem=${BW_BIN:-absent} lat_mem_rd=${LAT_BIN:-absent}"

BENCH_CMD_TIMEOUT="$TIMEOUT_SEC"

# ---------------------------------------------------------------- bandwidth

if [ -n "$BW_BIN" ]; then
  for op in $BW_OPS; do
    vals="$OUT_DIR/bw_${op}.values"
    : > "$vals"

    i=1
    while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
      runlog="$OUT_DIR/bw_${op}_${SIZE_TAG}_run${i}.log"

      # Assemble: bw_mem [-P n] [-W n] [-N n] <size> <what>
      set -- "$BW_BIN"
      if [ -n "$PARALLELISM" ] && [ "$PARALLELISM" != "1" ]; then
        set -- "$@" -P "$PARALLELISM"
      fi
      [ -n "$WARMUPS" ] && set -- "$@" -W "$WARMUPS"
      [ -n "$REPETITIONS" ] && set -- "$@" -N "$REPETITIONS"
      set -- "$@" "$SIZE_ARG" "$op"

      # lmbench writes results to stderr; bench_run_logged captures both.
      bench_run_logged "$runlog" "$@" || true

      # Output is "<size in MB> <bandwidth in MB/s>", e.g. "128.00 10240.50".
      bw="$(
        awk '
          NF >= 2 && $1 ~ /^[0-9]+([.][0-9]+)?$/ && $2 ~ /^[0-9]+([.][0-9]+)?$/ {
            print $2
            exit
          }
        ' "$runlog" 2>/dev/null || true
      )"

      if [ -n "$bw" ]; then
        bench_values_add "$vals" "$bw" || true
      else
        log_warn "$TESTNAME: bw_mem $op iteration $i - no parsable result"
        head -5 "$runlog" 2>/dev/null || true
      fi

      i=$((i + 1))
    done

    if [ -s "$vals" ]; then
      bench_metric_from_values "ddr-bw-${op}-${SIZE_TAG}" "$vals" "MB/s" "mean min max"
    else
      log_fail "$TESTNAME: bw_mem $op produced no results"
      bench_metric "ddr-bw-${op}-${SIZE_TAG}" "fail"
    fi
  done
else
  log_info "$TESTNAME: bandwidth tests not run"
fi

# ---------------------------------------------------------------- latency

if [ -n "$LAT_BIN" ]; then
  latlog="$OUT_DIR/lat_mem_rd.log"

  log_info "$TESTNAME: lat_mem_rd $LAT_SIZE_ARG stride $LAT_STRIDE"
  bench_run_logged "$latlog" "$LAT_BIN" "$LAT_SIZE_ARG" "$LAT_STRIDE" || true

  # Output is "<array size in MB> <latency in ns>" per line, ascending, with a
  # "stride=N" header. Only data accesses are measured.
  if [ -s "$latlog" ]; then
    # Main memory is the largest array size measured, i.e. the last data row.
    main_lat="$(
      awk '
        NF == 2 && $1 ~ /^[0-9]+([.][0-9]+)?$/ && $2 ~ /^[0-9]+([.][0-9]+)?$/ {
          last = $2
        }
        END { if (last != "") print last }
      ' "$latlog" 2>/dev/null || true
    )"

    if [ -n "$main_lat" ]; then
      bench_metric "ddr-latency-main-memory-read" "pass" "$main_lat" "ns"
    else
      log_warn "$TESTNAME: could not parse a main-memory latency from lat_mem_rd"
      bench_metric "ddr-latency-main-memory-read" "fail"
    fi

    # Cache levels, per the lmbench manual's suggested probe points.
    for lvl in l1 l2; do
      case "$lvl" in
        l1) probe="$L1_SIZE" ;;
        l2) probe="$L2_SIZE" ;;
      esac

      lat="$(
        awk -v p="$probe" '
          NF == 2 && $1 ~ /^[0-9]+([.][0-9]+)?$/ {
            if (($1 + 0) == (p + 0)) { print $2; exit }
          }
        ' "$latlog" 2>/dev/null || true
      )"

      if [ -n "$lat" ]; then
        bench_metric "ddr-latency-${lvl}-read" "pass" "$lat" "ns"
      else
        # Not an error: the requested probe point may not be in the sweep.
        log_warn "$TESTNAME: no lat_mem_rd row at ${probe}MB for $lvl; skipping"
        bench_metric "ddr-latency-${lvl}-read" "skip"
      fi
    done
  else
    log_fail "$TESTNAME: lat_mem_rd produced no output"
    bench_metric "ddr-latency-main-memory-read" "fail"
  fi

  # ------------------------------------------------- randomised latency sweep
  #
  # lat_mem_rd -t walks a random permutation instead of a constant stride, so
  # each load depends on the previous one and the prefetcher cannot run ahead.
  # This is the measurement that answers "what does a DRAM access cost"; the
  # strided sweep above answers "what does a streamed read cost", which is a
  # different and much smaller number. Reported under its own case ids rather
  # than replacing the strided ones, so neither series is reinterpreted.
  if [ "$LAT_RANDOM" = "1" ]; then
    rlatlog="$OUT_DIR/lat_mem_rd_random.log"

    log_info "$TESTNAME: lat_mem_rd -t (random) $LAT_SIZE_ARG stride $LAT_STRIDE"
    bench_run_logged "$rlatlog" "$LAT_BIN" -t "$LAT_SIZE_ARG" "$LAT_STRIDE" || true

    if [ -s "$rlatlog" ]; then
      rmain_lat="$(
        awk '
          NF == 2 && $1 ~ /^[0-9]+([.][0-9]+)?$/ && $2 ~ /^[0-9]+([.][0-9]+)?$/ {
            last = $2
          }
          END { if (last != "") print last }
        ' "$rlatlog" 2>/dev/null || true
      )"

      if [ -n "$rmain_lat" ]; then
        bench_metric "ddr-latency-main-memory-read-random" "pass" "$rmain_lat" "ns"
      else
        # Not every lmbench build accepts -t; say so rather than failing the
        # suite over a measurement the binary cannot make.
        log_warn "$TESTNAME: no randomised latency parsed (does this lat_mem_rd support -t?)"
        bench_metric "ddr-latency-main-memory-read-random" "skip"
      fi
    else
      log_warn "$TESTNAME: randomised lat_mem_rd produced no output (-t unsupported?)"
      bench_metric "ddr-latency-main-memory-read-random" "skip"
    fi
  fi
else
  log_info "$TESTNAME: latency test not run"
fi

summary="$OUT_DIR/summary.txt"
{
  echo "# $TESTNAME summary"
  echo "size            : $SIZE_ARG"
  echo "parallelism     : $PARALLELISM"
  echo "# bandwidth (MB/s, lmbench 10^6 convention)"
  for op in $BW_OPS; do
    vf="$OUT_DIR/bw_${op}.values"
    if [ -s "$vf" ]; then
      printf '  %-8s mean=%s min=%s max=%s\n' "$op" \
        "$(bench_values_stat "$vf" mean)" \
        "$(bench_values_stat "$vf" min)" \
        "$(bench_values_stat "$vf" max)"
    else
      printf '  %-8s no data\n' "$op"
    fi
  done
  echo "# latency (ns)"
  echo "  see $OUT_DIR/lat_mem_rd.log"
  if [ "$LAT_RANDOM" = "1" ]; then
    echo "  randomised sweep: $OUT_DIR/lat_mem_rd_random.log"
    echo "  # quote the randomised figure as DRAM latency; the strided one is"
    echo "  # prefetched streaming latency and is several times smaller"
  fi
} > "$summary"

log_info "$TESTNAME: summary written to $summary"
cat "$summary" 2>/dev/null || true

bench_finish
exit 0

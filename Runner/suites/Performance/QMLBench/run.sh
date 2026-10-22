#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# qmlbench wrapper for qcom-linux-testkit
# - Qt Quick benchmark: loads GPU and CPU together, which is the point of it -
#   the scene graph renders on the GPU while QML/JS runs on the CPU, so a
#   regression in either shows up here
# - Publishes each benchmark's average and the overall score to LAVA as
#   measurements
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use QMLBench.res for gating.
# - qmlbench is a Qt application, so it needs a QPA platform. The default,
#   auto, picks wayland when a Wayland session is present and eglfs otherwise,
#   which is what a headless board wants. Set --qpa to override.
# - Units depend on the shell: the default frame-count shell reports
#   frames/second, while static-count reports operations/second. The parser
#   takes the unit from qmlbench's own output rather than assuming, so the
#   measurement in LAVA is never mislabelled.

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

if [ -r "$TOOLS/lib_display.sh" ]; then
  # shellcheck disable=SC1090,SC1091
  . "$TOOLS/lib_display.sh"
fi

LC_ALL=C
export LC_ALL

TESTNAME="QMLBench"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
BENCHMARKS="${BENCHMARKS:-}"
BENCH_DIR="${BENCH_DIR:-}"
SHELL_MODE="${SHELL_MODE:-}"
SAMPLES="${SAMPLES:-}"
FULLSCREEN="${FULLSCREEN:-0}"
QPA="${QPA:-auto}"
BINARY="${BINARY:-}"
QMLBENCH_DIR="${QMLBENCH_DIR:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
ITERATIONS="${ITERATIONS:-1}"
TIMEOUT_SEC="${TIMEOUT_SEC:-1800}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR         output directory (default: $OUT_DIR)
  --benchmarks "LIST"   .qml files or directories to run; empty uses
                        --bench-dir, else qmlbench's installed benchmarks
  --bench-dir DIR       directory of qmlbench benchmarks
  --shell MODE          qmlbench --shell value, e.g. frame-count, static-count
  --samples N           qmlbench --count/samples value
  --fullscreen 0|1      run fullscreen (default: $FULLSCREEN)
  --qpa PLATFORM        QT_QPA_PLATFORM: auto|wayland|eglfs|xcb|... (default: $QPA)
  --binary PATH         explicit qmlbench binary
  --qmlbench-dir DIR    directory holding the binary
  --extra-args "ARGS"   extra arguments appended verbatim
  --iterations N        repeats of the whole run (default: $ITERATIONS)
  --timeout-sec N       per-run timeout (default: $TIMEOUT_SEC)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --benchmarks) BENCHMARKS="$2"; shift 2 ;;
    --bench-dir) BENCH_DIR="$2"; shift 2 ;;
    --shell) SHELL_MODE="$2"; shift 2 ;;
    --samples) SAMPLES="$2"; shift 2 ;;
    --fullscreen) FULLSCREEN="$2"; shift 2 ;;
    --qpa) QPA="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --qmlbench-dir) QMLBENCH_DIR="$2"; shift 2 ;;
    --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
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

BIN="$(bench_resolve_bin qmlbench "$BINARY" "$QMLBENCH_DIR" "$SCRIPT_DIR" "$SCRIPT_DIR/bin" || true)"

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  bench_skip_exit "qmlbench not found (use --binary or --qmlbench-dir, or add qmlbench to the image)"
  exit 0
fi

have_render_node=0
for n in /dev/dri/renderD* /dev/dri/card*; do
  if [ -e "$n" ]; then
    have_render_node=1
    break
  fi
done

if [ "$have_render_node" -eq 0 ]; then
  bench_skip_exit "no DRM device under /dev/dri; qmlbench needs a GPU to render on"
  exit 0
fi

# ---------------------------------------------------------------- QPA platform

if [ "$QPA" = "auto" ]; then
  if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    QPA="wayland"
  elif command -v discover_wayland_socket_anywhere >/dev/null 2>&1 &&
       [ -n "$(discover_wayland_socket_anywhere 2>/dev/null || true)" ]; then
    sock="$(discover_wayland_socket_anywhere 2>/dev/null || true)"
    if command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
      adopt_wayland_env_from_socket "$sock" >/dev/null 2>&1 || true
    fi
    QPA="wayland"
  elif [ -n "${DISPLAY:-}" ]; then
    QPA="xcb"
  else
    # eglfs talks to KMS directly, so it works with nothing on the display.
    QPA="eglfs"
  fi
fi

QT_QPA_PLATFORM="$QPA"
export QT_QPA_PLATFORM
log_info "$TESTNAME: binary=$BIN QT_QPA_PLATFORM=$QT_QPA_PLATFORM"

if [ "$QPA" = "eglfs" ] && command -v weston_is_running >/dev/null 2>&1; then
  if weston_is_running; then
    log_warn "$TESTNAME: Weston is running and QPA is eglfs; qmlbench may fail to become DRM master"
  fi
fi

# ---------------------------------------------------------------- targets

# Resolve what to run. qmlbench with no arguments runs nothing useful, so a
# directory is located if one was not given.
TARGETS="$BENCHMARKS"

if [ -z "$TARGETS" ]; then
  if [ -n "$BENCH_DIR" ]; then
    TARGETS="$BENCH_DIR"
  else
    for d in "$SCRIPT_DIR/benchmarks" "/usr/share/qmlbench/benchmarks" \
             "/opt/qmlbench/benchmarks" "/usr/lib/qmlbench/benchmarks" \
             "$HOME/qmlbench/benchmarks"; do
      if [ -d "$d" ]; then
        TARGETS="$d"
        break
      fi
    done
  fi
fi

if [ -z "$TARGETS" ]; then
  bench_skip_exit "no qmlbench benchmarks found (use --benchmarks or --bench-dir)"
  exit 0
fi

log_info "$TESTNAME: targets='$TARGETS'"

# ---------------------------------------------------------------- parser

# qmlbench_parse <logfile>
#
# Emits "<benchmark> <value> <units>" lines.
#
# qmlbench prints a benchmark name on its own line and the result on a
# following line, so the parser carries the current name forward:
#
#   Benchmark: creation/delegates_item.qml
#       Average: 59.941 frames/second; using 6 samples; MedianAll=59.9; ...
#
# The unit is read from the output rather than assumed, because it changes
# with --shell (frames/second vs operations/second).
qmlbench_parse() {
  awk '
    # Name-bearing lines, in either spelling qmlbench uses.
    /^[ \t]*Benchmark[ \t]*:/ {
      n = $0
      sub(/^[ \t]*Benchmark[ \t]*:[ \t]*/, "", n)
      gsub(/[ \t]+$/, "", n)
      if (n != "") { cur = n }
      next
    }
    /^[ \t]*Running[ \t]+/ {
      n = $0
      sub(/^[ \t]*Running[ \t]+/, "", n)
      gsub(/^['"'"'"]|['"'"'"]$/, "", n)
      sub(/\.\.\.[ \t]*$/, "", n)
      gsub(/^['"'"'"]|['"'"'"]$/, "", n)
      gsub(/[ \t]+$/, "", n)
      if (n != "") { cur = n }
      next
    }

    # Result lines.
    /[Aa]verage[ \t]*:/ {
      rest = $0
      sub(/^.*[Aa]verage[ \t]*:[ \t]*/, "", rest)

      # Value: leading number of the remainder.
      if (match(rest, /^[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?/) == 0) { next }
      val = substr(rest, RSTART, RLENGTH)

      # Units: the token that follows it, up to the separating semicolon.
      u = substr(rest, RSTART + RLENGTH)
      sub(/^[ \t]+/, "", u)
      sub(/;.*$/, "", u)
      gsub(/[ \t]+$/, "", u)
      # Collapse the long spellings to something compact but still honest.
      if (u ~ /frames\/?second/ || u ~ /^fps$/) { u = "fps" }
      else if (u ~ /operations\/?second/ || u ~ /ops\/?second/) { u = "ops/s" }
      else if (u == "") { u = "-" }
      else { gsub(/[ \t]+/, "-", u) }

      name = (cur != "") ? cur : "unnamed"
      print name, val, u
      next
    }

    # An overall score, when the shell prints one.
    /[Tt]otal [Ss]core[ \t]*:/ {
      rest = $0
      sub(/^.*[Ss]core[ \t]*:[ \t]*/, "", rest)
      if (match(rest, /^[0-9]+([.][0-9]+)?/) > 0) {
        print "__total_score__", substr(rest, RSTART, RLENGTH), "points"
      }
    }
  ' "$1" 2>/dev/null
}

# ---------------------------------------------------------------- run

BENCH_CMD_TIMEOUT="$TIMEOUT_SEC"
PARSED_ALL="$OUT_DIR/parsed.txt"
: > "$PARSED_ALL"

i=1
while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
  runlog="$OUT_DIR/qmlbench_run${i}.log"

  set -- "$BIN"
  [ -n "$SHELL_MODE" ] && set -- "$@" --shell "$SHELL_MODE"
  [ -n "$SAMPLES" ] && set -- "$@" --count "$SAMPLES"
  [ "$FULLSCREEN" = "1" ] && set -- "$@" --fullscreen

  for t in $TARGETS; do
    set -- "$@" "$t"
  done

  # Word splitting is intended: EXTRA_ARGS is a flag string.
  # shellcheck disable=SC2086
  [ -n "$EXTRA_ARGS" ] && set -- "$@" $EXTRA_ARGS

  bench_run_logged "$runlog" "$@" || true

  qmlbench_parse "$runlog" >> "$PARSED_ALL" 2>/dev/null || true

  i=$((i + 1))
done

if [ ! -s "$PARSED_ALL" ]; then
  log_fail "$TESTNAME: no results parsed from qmlbench output"
  log_info "$TESTNAME: last 30 lines of the final run follow"
  tail -30 "$OUT_DIR/qmlbench_run1.log" 2>/dev/null || true
  bench_metric "qmlbench-run" "fail"
  bench_finish FAIL
  exit 0
fi

# One metric per benchmark, aggregated across iterations.
names="$(awk '{ print $1 }' "$PARSED_ALL" | sort -u 2>/dev/null || true)"

for nm in $names; do
  nid="$(printf '%s' "$nm" | sed 's/\.qml$//' | tr -c '[:alnum:]_.:-' '-' |
         sed 's/--*/-/g; s/^-//; s/-$//')"
  vf="$OUT_DIR/bench_${nid}.values"
  awk -v n="$nm" '$1 == n { print $2 }' "$PARSED_ALL" > "$vf" 2>/dev/null || true
  un="$(awk -v n="$nm" '$1 == n { print $3; exit }' "$PARSED_ALL" 2>/dev/null || true)"
  [ "$un" = "-" ] && un=""

  [ -s "$vf" ] || continue

  if [ "$nm" = "__total_score__" ]; then
    bench_metric_from_values "qmlbench-total-score" "$vf" "$un" "mean"
    continue
  fi

  if [ "$ITERATIONS" -gt 1 ] 2>/dev/null; then
    bench_metric_from_values "qmlbench-${nid}" "$vf" "$un" "mean min max"
  else
    bench_metric_from_values "qmlbench-${nid}" "$vf" "$un" "mean"
  fi
done

summary="$OUT_DIR/summary.txt"
{
  echo "# $TESTNAME summary"
  echo "binary     : $BIN"
  echo "qpa        : $QT_QPA_PLATFORM"
  echo "shell      : ${SHELL_MODE:-qmlbench default}"
  echo "targets    : $TARGETS"
  echo "iterations : $ITERATIONS"
  echo "# per-benchmark results"
  sort "$PARSED_ALL" 2>/dev/null | awk '{ printf "  %-50s %s %s\n", $1, $2, $3 }'
} > "$summary"

log_info "$TESTNAME: summary written to $summary"
cat "$summary" 2>/dev/null || true

bench_finish
exit 0

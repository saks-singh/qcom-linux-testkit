#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# vkmark wrapper for qcom-linux-testkit
# - Vulkan graphics benchmark: overall vkmark Score plus per-scene FPS
# - Publishes every figure to LAVA as a measurement
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use Vkmark.res for gating.
# - vkmark needs a present window system. Three are supported upstream and all
#   three are offered here: wayland, xcb and kms. The default, auto, adopts a
#   running Weston/Wayland session if there is one (reusing the testkit's own
#   display helpers) and otherwise falls back to kms, which needs no compositor
#   and is usually the right choice on a headless board.
# - A vkmark Score is only comparable against another run with the same scene
#   list, resolution and present mode. The run's parameters are recorded in
#   summary.txt for exactly that reason.
# - This is the Vulkan counterpart to Multimedia/Graphics/X11_Glmark2, which
#   validates OpenGL/GLES rendering. They are separate suites because they
#   exercise separate drivers.

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

TESTNAME="Vkmark"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
WINSYS="${WINSYS:-auto}"
SIZE="${SIZE:-}"
FULLSCREEN="${FULLSCREEN:-0}"
BENCHMARKS="${BENCHMARKS:-}"
ITERATIONS="${ITERATIONS:-1}"
PER_SCENE="${PER_SCENE:-1}"
BINARY="${BINARY:-}"
VKMARK_DIR="${VKMARK_DIR:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
START_WESTON="${START_WESTON:-0}"
TIMEOUT_SEC="${TIMEOUT_SEC:-600}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR        output directory (default: $OUT_DIR)
  --winsys MODE        present mode: auto|wayland|xcb|kms (default: $WINSYS)
  --size WxH           window size, e.g. 1920x1080 (default: vkmark's own)
  --fullscreen 0|1     run fullscreen (default: $FULLSCREEN)
  --benchmarks "LIST"  vkmark -b specs, space separated; empty runs the
                       default scene list
  --iterations N       repeats of the whole run (default: $ITERATIONS)
  --per-scene 0|1      emit a measurement per scene (default: $PER_SCENE)
  --binary PATH        explicit vkmark binary
  --vkmark-dir DIR     directory holding the binary
  --extra-args "ARGS"  extra arguments appended verbatim
  --start-weston 0|1   start Weston if no Wayland session is up (default: $START_WESTON)
  --timeout-sec N      per-run timeout (default: $TIMEOUT_SEC)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --winsys) WINSYS="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --fullscreen) FULLSCREEN="$2"; shift 2 ;;
    --benchmarks) BENCHMARKS="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --per-scene) PER_SCENE="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --vkmark-dir) VKMARK_DIR="$2"; shift 2 ;;
    --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
    --start-weston) START_WESTON="$2"; shift 2 ;;
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

BIN="$(bench_resolve_bin vkmark "$BINARY" "$VKMARK_DIR" "$SCRIPT_DIR" "$SCRIPT_DIR/bin" || true)"

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  bench_skip_exit "vkmark not found (use --binary or --vkmark-dir, or add vkmark to the image)"
  exit 0
fi

# A Vulkan-capable render node is the minimum requirement; without one vkmark
# fails at device creation and there is nothing to measure.
have_render_node=0
for n in /dev/dri/renderD* /dev/dri/card*; do
  if [ -e "$n" ]; then
    have_render_node=1
    break
  fi
done

if [ "$have_render_node" -eq 0 ]; then
  bench_skip_exit "no DRM device under /dev/dri; no Vulkan device to benchmark"
  exit 0
fi

# ---------------------------------------------------------------- window system

resolve_winsys() {
  if [ "$WINSYS" != "auto" ]; then
    echo "$WINSYS"
    return 0
  fi

  # Prefer an existing Wayland session: it is what the platform actually ships
  # with, so it is the more representative number.
  if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    echo "wayland"
    return 0
  fi

  if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
    _sock="$(discover_wayland_socket_anywhere 2>/dev/null || true)"
    if [ -n "$_sock" ]; then
      if command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
        adopt_wayland_env_from_socket "$_sock" >/dev/null 2>&1 || true
      fi
      if [ -n "${WAYLAND_DISPLAY:-}" ]; then
        echo "wayland"
        return 0
      fi
    fi
  fi

  if [ "$START_WESTON" = "1" ] && command -v weston_start >/dev/null 2>&1; then
    log_info "$TESTNAME: no Wayland session; starting Weston"
    if weston_start >/dev/null 2>&1 && [ -n "${WAYLAND_DISPLAY:-}" ]; then
      echo "wayland"
      return 0
    fi
    log_warn "$TESTNAME: could not start Weston; falling back"
  fi

  if [ -n "${DISPLAY:-}" ]; then
    echo "xcb"
    return 0
  fi

  # kms needs no compositor, which makes it the dependable choice on a board
  # with nothing running on the display.
  echo "kms"
}

WS="$(resolve_winsys)"
log_info "$TESTNAME: binary=$BIN present=$WS size=${SIZE:-default} fullscreen=$FULLSCREEN"

if [ "$WS" = "kms" ] && command -v weston_is_running >/dev/null 2>&1; then
  if weston_is_running; then
    # Two things cannot own the display at once; say so rather than letting
    # vkmark fail with an opaque DRM master error.
    log_warn "$TESTNAME: Weston is running and present mode is kms; vkmark may fail to become DRM master"
  fi
fi

# ---------------------------------------------------------------- run

BENCH_CMD_TIMEOUT="$TIMEOUT_SEC"
score_vals="$OUT_DIR/score.values"
: > "$score_vals"
SCENE_LIST="$OUT_DIR/scenes.txt"
: > "$SCENE_LIST"

i=1
while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
  runlog="$OUT_DIR/vkmark_run${i}.log"

  set -- "$BIN" -p "$WS"
  [ -n "$SIZE" ] && set -- "$@" -s "$SIZE"
  [ "$FULLSCREEN" = "1" ] && set -- "$@" --fullscreen

  for b in $BENCHMARKS; do
    set -- "$@" -b "$b"
  done

  # Word splitting is intended: EXTRA_ARGS is a flag string.
  # shellcheck disable=SC2086
  [ -n "$EXTRA_ARGS" ] && set -- "$@" $EXTRA_ARGS

  bench_run_logged "$runlog" "$@" || true

  # Overall score: "    vkmark Score: 1789"
  sc="$(
    awk '
      /[Vv]kmark Score/ {
        for (j = 1; j <= NF; j++) {
          t = $j
          gsub(/[^0-9.]/, "", t)
          if (t ~ /^[0-9]+([.][0-9]+)?$/) { v = t }
        }
        if (v != "") { print v; exit }
      }
    ' "$runlog" 2>/dev/null || true
  )"

  if [ -n "$sc" ]; then
    bench_values_add "$score_vals" "$sc" || true
  else
    log_warn "$TESTNAME: iteration $i - no vkmark Score line found"
    tail -20 "$runlog" 2>/dev/null || true
  fi

  # Per-scene rows: "[vertex] device-local=true: FPS: 1234 FrameTime: 0.810 ms"
  #
  # The scene's options are part of the identity, not decoration: [vertex]
  # device-local=true and device-local=false are different measurements, and
  # keying on the scene name alone would average them into one meaningless
  # figure.
  if [ "$PER_SCENE" = "1" ]; then
    awk '
      /^\[/ && /FPS:/ {
        fps = ""
        fpsidx = 0
        for (j = 1; j <= NF; j++) {
          if ($j == "FPS:" && (j + 1) <= NF) {
            t = $(j+1)
            gsub(/[^0-9.]/, "", t)
            if (t ~ /^[0-9]+([.][0-9]+)?$/) { fps = t; fpsidx = j }
          }
        }
        if (fps == "") { next }

        # Everything before "FPS:" identifies the scene and its options.
        name = ""
        for (j = 1; j < fpsidx; j++) {
          tok = $j
          gsub(/[\[\]]/, "", tok)
          # vkmark terminates the option list with a colon, and a scene with no
          # options prints a bare ":" field. Neither belongs in the case id.
          sub(/:$/, "", tok)
          if (tok == "" || tok == ":") { continue }
          name = (name == "") ? tok : name "-" tok
        }
        # Token-safe for a LAVA case id, and collapse the runs of separators
        # that option syntax leaves behind.
        gsub(/[^A-Za-z0-9._:-]/, "-", name)
        gsub(/-+/, "-", name)
        gsub(/^-+|-+$/, "", name)

        if (name != "") { print name, fps }
      }
    ' "$runlog" >> "$SCENE_LIST" 2>/dev/null || true
  fi

  i=$((i + 1))
done

if [ -s "$score_vals" ]; then
  if [ "$ITERATIONS" -gt 1 ] 2>/dev/null; then
    bench_metric_from_values "vkmark-score" "$score_vals" "points" "mean min max"
  else
    bench_metric_from_values "vkmark-score" "$score_vals" "points" "mean"
  fi
else
  log_fail "$TESTNAME: no vkmark Score produced"
  bench_metric "vkmark-score" "fail"
fi

# Per-scene FPS, aggregated across iterations so a scene appears once.
if [ "$PER_SCENE" = "1" ] && [ -s "$SCENE_LIST" ]; then
  scenes="$(awk '{ print $1 }' "$SCENE_LIST" | sort -u 2>/dev/null || true)"

  for s in $scenes; do
    sid="$(printf '%s' "$s" | tr -c '[:alnum:]_.:-' '-')"
    sfile="$OUT_DIR/scene_${sid}.values"
    awk -v s="$s" '$1 == s { print $2 }' "$SCENE_LIST" > "$sfile" 2>/dev/null || true

    if [ -s "$sfile" ]; then
      bench_metric_from_values "vkmark-scene-${sid}-fps" "$sfile" "fps" "mean"
    fi
  done
elif [ "$PER_SCENE" = "1" ]; then
  log_warn "$TESTNAME: no per-scene FPS rows parsed"
fi

summary="$OUT_DIR/summary.txt"
{
  echo "# $TESTNAME summary"
  echo "binary      : $BIN"
  echo "present     : $WS"
  echo "size        : ${SIZE:-default}"
  echo "fullscreen  : $FULLSCREEN"
  echo "benchmarks  : ${BENCHMARKS:-default scene list}"
  echo "iterations  : $ITERATIONS"
  if [ -s "$score_vals" ]; then
    echo "score mean  : $(bench_values_stat "$score_vals" mean)"
  fi
  echo "# a vkmark Score is only comparable against a run with the same"
  echo "# scenes, size and present mode as recorded above"
} > "$summary"

log_info "$TESTNAME: summary written to $summary"
cat "$summary" 2>/dev/null || true

bench_finish
exit 0

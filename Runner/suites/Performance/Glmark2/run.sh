#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# glmark2 wrapper for qcom-linux-testkit
# - OpenGL / OpenGL ES 2.0 graphics benchmark: overall glmark2 Score plus
#   per-scene FPS
# - Publishes every figure to LAVA as a measurement
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use Glmark2.res for gating.
# - This is the performance counterpart to Multimedia/Graphics/X11_Glmark2.
#   That suite *validates* rendering inside a real XFCE session and publishes
#   no measurement; it SKIPs on an image with no desktop session, which is the
#   usual case on a board. This one is after the score, and takes whichever
#   window system the board actually has.
# - glmark2 selects its window system by BINARY NAME, not by a flag: upstream
#   builds glmark2, glmark2-es2, glmark2-wayland, glmark2-es2-wayland,
#   glmark2-drm and glmark2-es2-drm from one tree. So --flavour picks the
#   family and the binary is resolved from it, rather than passing a -p flag
#   the way vkmark does.
# - A glmark2 Score is only comparable against another run with the same
#   binary flavour, scene list and size. Those are recorded in summary.txt for
#   exactly that reason - the score is a sum over the scenes that ran, so a
#   different scene list is a different scale, not a better board.

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

TESTNAME="Glmark2"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
FLAVOUR="${FLAVOUR:-auto}"
SIZE="${SIZE:-}"
FULLSCREEN="${FULLSCREEN:-0}"
OFFSCREEN="${OFFSCREEN:-0}"
BENCHMARKS="${BENCHMARKS:-}"
ITERATIONS="${ITERATIONS:-1}"
PER_SCENE="${PER_SCENE:-1}"
BINARY="${BINARY:-}"
GLMARK2_DIR="${GLMARK2_DIR:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
START_WESTON="${START_WESTON:-0}"
SET_PERF_GOV="${SET_PERF_GOV:-1}"
TIMEOUT_SEC="${TIMEOUT_SEC:-900}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR        output directory (default: $OUT_DIR)
  --flavour MODE       window system family: auto|wayland|x11|drm
                       (default: $FLAVOUR); glmark2 picks this by binary name
  --size WxH           window size, e.g. 1920x1080 (default: glmark2's own)
  --fullscreen 0|1     run fullscreen (default: $FULLSCREEN)
  --off-screen 0|1     render off-screen (default: $OFFSCREEN)
  --benchmarks "LIST"  glmark2 -b specs, space separated; empty runs the
                       default scene list
  --iterations N       repeats of the whole run (default: $ITERATIONS)
  --per-scene 0|1      emit a measurement per scene (default: $PER_SCENE)
  --binary PATH        explicit glmark2 binary (overrides --flavour)
  --glmark2-dir DIR    directory holding the binary
  --extra-args "ARGS"  extra arguments appended verbatim
  --start-weston 0|1   start Weston if no Wayland session is up (default: $START_WESTON)
  --set-perf-gov 0|1   pin CPUs to the performance governor (default: $SET_PERF_GOV)
  --timeout-sec N      per-run timeout (default: $TIMEOUT_SEC)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --flavour) FLAVOUR="$2"; shift 2 ;;
    --size) SIZE="$2"; shift 2 ;;
    --fullscreen) FULLSCREEN="$2"; shift 2 ;;
    --off-screen) OFFSCREEN="$2"; shift 2 ;;
    --benchmarks) BENCHMARKS="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --per-scene) PER_SCENE="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --glmark2-dir) GLMARK2_DIR="$2"; shift 2 ;;
    --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
    --start-weston) START_WESTON="$2"; shift 2 ;;
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

if ! bench_require_cmds awk grep sed tr sort; then
  bench_skip_exit "core utilities missing"
  exit 0
fi

# A DRM device is the minimum requirement: without one there is no GPU to
# benchmark and glmark2 fails at context creation.
have_render_node=0
for n in /dev/dri/renderD* /dev/dri/card*; do
  if [ -e "$n" ]; then
    have_render_node=1
    break
  fi
done

if [ "$have_render_node" -eq 0 ]; then
  bench_skip_exit "no DRM device under /dev/dri; no GPU to benchmark"
  exit 0
fi

# ---------------------------------------------------------------- window system

# Adopt a running Wayland session if there is one. The compositor the platform
# actually ships with is the more representative number, and lib_display.sh
# already knows where the lab's images put their socket.
adopt_wayland() {
  [ -n "${WAYLAND_DISPLAY:-}" ] && return 0

  if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
    _sock="$(discover_wayland_socket_anywhere 2>/dev/null || true)"
    if [ -n "$_sock" ] && command -v adopt_wayland_env_from_socket >/dev/null 2>&1; then
      adopt_wayland_env_from_socket "$_sock" >/dev/null 2>&1 || true
    fi
  fi

  [ -n "${WAYLAND_DISPLAY:-}" ]
}

resolve_flavour() {
  if [ "$FLAVOUR" != "auto" ]; then
    echo "$FLAVOUR"
    return 0
  fi

  if adopt_wayland; then
    echo "wayland"
    return 0
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
    echo "x11"
    return 0
  fi

  # drm needs no compositor, which makes it the dependable choice on a board
  # with nothing running on the display.
  echo "drm"
}

FL="$(resolve_flavour)"

# In the non-auto case the caller named a family, so still make the session
# usable for it rather than letting a wayland binary fail on a missing socket.
if [ "$FL" = "wayland" ]; then
  adopt_wayland || log_warn "$TESTNAME: flavour wayland but no WAYLAND_DISPLAY found"
fi

# ES2 first in every family: it is the variant Qualcomm boards ship and the
# one with working drivers, while the desktop-GL variant is often absent or
# falls back to software.
case "$FL" in
  wayland) CANDIDATES="glmark2-es2-wayland glmark2-wayland" ;;
  x11)     CANDIDATES="glmark2-es2 glmark2" ;;
  drm)     CANDIDATES="glmark2-es2-drm glmark2-drm" ;;
  *)
    log_warn "$TESTNAME: unknown flavour '$FL'; trying every known binary name"
    CANDIDATES="glmark2-es2-wayland glmark2-wayland glmark2-es2-drm glmark2-drm glmark2-es2 glmark2"
    ;;
esac

BIN=""
if [ -n "$BINARY" ]; then
  BIN="$(bench_resolve_bin "$(basename "$BINARY")" "$BINARY" "$GLMARK2_DIR" "$SCRIPT_DIR" "$SCRIPT_DIR/bin" || true)"
else
  for c in $CANDIDATES; do
    BIN="$(bench_resolve_bin "$c" "" "$GLMARK2_DIR" "$SCRIPT_DIR" "$SCRIPT_DIR/bin" || true)"
    [ -n "$BIN" ] && [ -x "$BIN" ] && break
    BIN=""
  done
fi

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  bench_skip_exit "no glmark2 binary for flavour '$FL' (tried: $CANDIDATES); use --binary or --glmark2-dir, or add glmark2 to the image"
  exit 0
fi

if [ "$FL" = "drm" ] && command -v weston_is_running >/dev/null 2>&1; then
  if weston_is_running; then
    # Two things cannot own the display at once; say so rather than letting
    # glmark2 fail with an opaque DRM master error.
    log_warn "$TESTNAME: Weston is running and flavour is drm; glmark2 may fail to become DRM master"
  fi
fi

log_info "$TESTNAME: binary=$BIN flavour=$FL size=${SIZE:-default} fullscreen=$FULLSCREEN"

# ---------------------------------------------------------------- run

[ "$SET_PERF_GOV" = "1" ] && bench_set_governor performance

BENCH_CMD_TIMEOUT="$TIMEOUT_SEC"
score_vals="$OUT_DIR/score.values"
: > "$score_vals"
SCENE_LIST="$OUT_DIR/scenes.txt"
: > "$SCENE_LIST"

i=1
while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
  runlog="$OUT_DIR/glmark2_run${i}.log"

  set -- "$BIN"
  [ -n "$SIZE" ] && set -- "$@" --size "$SIZE"
  [ "$FULLSCREEN" = "1" ] && set -- "$@" --fullscreen
  [ "$OFFSCREEN" = "1" ] && set -- "$@" --off-screen

  for b in $BENCHMARKS; do
    set -- "$@" -b "$b"
  done

  # Word splitting is intended: EXTRA_ARGS is a flag string.
  # shellcheck disable=SC2086
  [ -n "$EXTRA_ARGS" ] && set -- "$@" $EXTRA_ARGS

  bench_run_logged "$runlog" "$@" || true

  # Overall score: "                       glmark2 Score: 1789"
  sc="$(
    awk '
      /[Gg]lmark2 Score/ {
        v = ""
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
    log_warn "$TESTNAME: iteration $i - no glmark2 Score line found"
    tail -20 "$runlog" 2>/dev/null || true
  fi

  # Per-scene rows: "[build] use-vbo=true: FPS: 1234 FrameTime: 0.810 ms"
  #
  # The scene's options are part of the identity, not decoration: [build]
  # use-vbo=true and use-vbo=false are different measurements, and keying on
  # the scene name alone would average them into one meaningless figure.
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
          # glmark2 terminates the option list with a colon, and a scene with
          # no options prints a bare ":" field. Neither belongs in the case id.
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

[ "$SET_PERF_GOV" = "1" ] && bench_restore_governor

if [ -s "$score_vals" ]; then
  if [ "$ITERATIONS" -gt 1 ] 2>/dev/null; then
    bench_metric_from_values "glmark2-score" "$score_vals" "points" "mean min max"
  else
    bench_metric_from_values "glmark2-score" "$score_vals" "points" "mean"
  fi
else
  log_fail "$TESTNAME: no glmark2 Score produced"
  bench_metric "glmark2-score" "fail"
fi

# Per-scene FPS, aggregated across iterations so a scene appears once.
if [ "$PER_SCENE" = "1" ] && [ -s "$SCENE_LIST" ]; then
  scenes="$(awk '{ print $1 }' "$SCENE_LIST" | sort -u 2>/dev/null || true)"

  for s in $scenes; do
    sid="$(printf '%s' "$s" | tr -c '[:alnum:]_.:-' '-')"
    sfile="$OUT_DIR/scene_${sid}.values"
    awk -v s="$s" '$1 == s { print $2 }' "$SCENE_LIST" > "$sfile" 2>/dev/null || true

    if [ -s "$sfile" ]; then
      bench_metric_from_values "glmark2-scene-${sid}-fps" "$sfile" "fps" "mean"
    fi
  done
elif [ "$PER_SCENE" = "1" ]; then
  log_warn "$TESTNAME: no per-scene FPS rows parsed"
fi

summary="$OUT_DIR/summary.txt"
{
  echo "# $TESTNAME summary"
  echo "binary      : $BIN"
  echo "flavour     : $FL"
  echo "size        : ${SIZE:-default}"
  echo "fullscreen  : $FULLSCREEN"
  echo "off-screen  : $OFFSCREEN"
  echo "benchmarks  : ${BENCHMARKS:-default scene list}"
  echo "iterations  : $ITERATIONS"
  if [ -s "$score_vals" ]; then
    echo "score mean  : $(bench_values_stat "$score_vals" mean)"
  fi
  echo "# a glmark2 Score is the sum over the scenes that ran, so it is only"
  echo "# comparable against a run with the same binary flavour, scenes and"
  echo "# size as recorded above"
} > "$summary"

log_info "$TESTNAME: summary written to $summary"
cat "$summary" 2>/dev/null || true

bench_finish
exit 0

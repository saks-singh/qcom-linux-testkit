#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# sockperf wrapper for qcom-linux-testkit
# - Socket latency and throughput: ping-pong, under-load and throughput modes
# - Publishes average latency, the latency percentiles sockperf prints,
#   message rate and bandwidth to LAVA as measurements
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use Sockperf.res for gating.
# - By default this runs against a sockperf server started on the DUT itself
#   over loopback. That is reproducible and needs no lab topology, but it
#   measures the kernel network stack and the scheduler - NOT the NIC, the PHY
#   or any link. For a number that includes the interface, point --server-ip
#   at a real peer and start the server there; the suite will not start a
#   local one in that case.
# - The local server is started by this script and stopped on every exit path,
#   including signals, so a cancelled LAVA job does not leave a listener
#   holding the port.

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

TESTNAME="Sockperf"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
MODES="${MODES:-ping-pong throughput}"
SERVER_IP="${SERVER_IP:-127.0.0.1}"
PORT="${PORT:-11111}"
PROTOCOL="${PROTOCOL:-udp}"
MSG_SIZE="${MSG_SIZE:-64}"
TIME_SEC="${TIME_SEC:-10}"
MPS="${MPS:-}"
START_SERVER="${START_SERVER:-auto}"
SERVER_WAIT_SEC="${SERVER_WAIT_SEC:-5}"
ITERATIONS="${ITERATIONS:-1}"
BINARY="${BINARY:-}"
SOCKPERF_DIR="${SOCKPERF_DIR:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
SET_PERF_GOV="${SET_PERF_GOV:-1}"
TIMEOUT_SEC="${TIMEOUT_SEC:-300}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR        output directory (default: $OUT_DIR)
  --modes "LIST"       ping-pong under-load throughput (default: $MODES)
  --server-ip IP       server to talk to (default: $SERVER_IP, loopback)
  --port N             server port (default: $PORT)
  --protocol udp|tcp   transport (default: $PROTOCOL)
  --msg-size N         message size in bytes (default: $MSG_SIZE)
  --time-sec N         test duration per mode (default: $TIME_SEC)
  --mps N              messages per second, or "max" (default: sockperf's own)
  --start-server MODE  auto|1|0 - start a local server (default: $START_SERVER)
                       auto starts one only for a loopback server-ip
  --server-wait-sec N  seconds to wait for the local server (default: $SERVER_WAIT_SEC)
  --iterations N       repeats per mode (default: $ITERATIONS)
  --binary PATH        explicit sockperf binary
  --sockperf-dir DIR   directory holding the binary
  --extra-args "ARGS"  extra client arguments appended verbatim
  --set-perf-gov 0|1   pin CPU governor to performance (default: $SET_PERF_GOV)
  --timeout-sec N      per-run timeout (default: $TIMEOUT_SEC)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --modes) MODES="$2"; shift 2 ;;
    --server-ip) SERVER_IP="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --protocol) PROTOCOL="$2"; shift 2 ;;
    --msg-size) MSG_SIZE="$2"; shift 2 ;;
    --time-sec) TIME_SEC="$2"; shift 2 ;;
    --mps) MPS="$2"; shift 2 ;;
    --start-server) START_SERVER="$2"; shift 2 ;;
    --server-wait-sec) SERVER_WAIT_SEC="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --sockperf-dir) SOCKPERF_DIR="$2"; shift 2 ;;
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

BIN="$(bench_resolve_bin sockperf "$BINARY" "$SOCKPERF_DIR" "$SCRIPT_DIR" "$SCRIPT_DIR/bin" || true)"

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  bench_skip_exit "sockperf not found (use --binary or --sockperf-dir, or add sockperf to the image)"
  exit 0
fi

# ---------------------------------------------------------------- server

SERVER_PID=""
SERVER_LOG="$OUT_DIR/server.log"

is_loopback_ip() {
  case "$1" in
    127.*|::1|localhost) return 0 ;;
    *) return 1 ;;
  esac
}

stop_server() {
  [ -n "$SERVER_PID" ] || return 0

  if kill -0 "$SERVER_PID" 2>/dev/null; then
    log_info "$TESTNAME: stopping local sockperf server (pid $SERVER_PID)"
    kill -TERM "$SERVER_PID" 2>/dev/null || true

    _w=0
    while [ "$_w" -lt 5 ]; do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 1
      _w=$((_w + 1))
    done

    if kill -0 "$SERVER_PID" 2>/dev/null; then
      log_warn "$TESTNAME: server did not exit on TERM; sending KILL"
      kill -KILL "$SERVER_PID" 2>/dev/null || true
    fi
  fi

  SERVER_PID=""
}

# Every exit path tears the server down: an orphaned listener would hold the
# port and make the next job on this board fail for no visible reason.
cleanup() {
  stop_server
}
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM HUP

want_server=0
case "$START_SERVER" in
  1) want_server=1 ;;
  0) want_server=0 ;;
  auto)
    if is_loopback_ip "$SERVER_IP"; then
      want_server=1
    else
      log_info "$TESTNAME: server-ip $SERVER_IP is not loopback; expecting an external sockperf server"
    fi
    ;;
  *)
    log_warn "$TESTNAME: unrecognised --start-server '$START_SERVER'; treating as auto"
    is_loopback_ip "$SERVER_IP" && want_server=1
    ;;
esac

proto_flag=""
if [ "$PROTOCOL" = "tcp" ]; then
  proto_flag="--tcp"
elif [ "$PROTOCOL" != "udp" ]; then
  log_warn "$TESTNAME: unrecognised protocol '$PROTOCOL'; using udp"
  PROTOCOL="udp"
fi

if [ "$want_server" -eq 1 ]; then
  log_info "$TESTNAME: starting local sockperf server on $SERVER_IP:$PORT ($PROTOCOL)"

  if [ -n "$proto_flag" ]; then
    "$BIN" server -i "$SERVER_IP" -p "$PORT" "$proto_flag" > "$SERVER_LOG" 2>&1 &
  else
    "$BIN" server -i "$SERVER_IP" -p "$PORT" > "$SERVER_LOG" 2>&1 &
  fi
  SERVER_PID=$!

  # Give it a moment to bind. sockperf's own client error is unhelpful if the
  # server is not up yet, so check liveness rather than racing it.
  _w=0
  while [ "$_w" -lt "$SERVER_WAIT_SEC" ] 2>/dev/null; do
    sleep 1
    _w=$((_w + 1))
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      log_fail "$TESTNAME: local sockperf server exited immediately"
      tail -20 "$SERVER_LOG" 2>/dev/null || true
      SERVER_PID=""
      bench_metric "sockperf-server-start" "fail"
      bench_finish FAIL
      exit 0
    fi
    break
  done

  bench_metric "sockperf-server-start" "pass"
  log_info "$TESTNAME: server running as pid $SERVER_PID"
  log_warn "$TESTNAME: loopback run - this measures the kernel stack, not the NIC or the link"
fi

if [ "$SET_PERF_GOV" = "1" ]; then
  bench_set_governor performance
fi

# ---------------------------------------------------------------- parser

# sockperf_metrics <logfile> <mode-tag>
#
# Reads sockperf's summary block and emits "<case-suffix> <value> <units>"
# lines. All the shapes below come from sockperf's own output:
#   sockperf: Summary: Latency is 11.082 usec
#   sockperf: ====> avg-latency=11.082 (std-dev=2.123)
#   sockperf: Summary: Message Rate is 123456 [msg/sec]
#   sockperf: Summary: BandWidth is 115.432 MBps (923.456 Mbps)
#   sockperf: ---> percentile 99.000 =   20.000
#   sockperf: ---> <MAX> observation =   75.123
sockperf_metrics() {
  awk '
    function num(s) {
      gsub(/[^0-9.eE+-]/, "", s)
      if (s ~ /^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/) { return s }
      return ""
    }

    /Summary.*Latency is/ {
      for (i = 1; i <= NF; i++) {
        if ($i == "is" && (i + 1) <= NF) {
          v = num($(i+1))
          if (v != "") { print "latency", v, "usec" }
        }
      }
      next
    }

    /avg-latency=/ {
      s = $0
      sub(/^.*avg-latency=/, "", s)
      if (match(s, /^[0-9]+([.][0-9]+)?/) > 0) {
        print "avg-latency", substr(s, RSTART, RLENGTH), "usec"
      }
      if (match(s, /std-dev=[0-9]+([.][0-9]+)?/) > 0) {
        d = substr(s, RSTART, RLENGTH)
        sub(/std-dev=/, "", d)
        print "latency-stddev", d, "usec"
      }
      next
    }

    /Message Rate is/ {
      s = $0
      sub(/^.*Message Rate is[ \t]*/, "", s)
      if (match(s, /^[0-9]+([.][0-9]+)?/) > 0) {
        print "message-rate", substr(s, RSTART, RLENGTH), "msg/s"
      }
      next
    }

    /BandWidth is/ {
      s = $0
      sub(/^.*BandWidth is[ \t]*/, "", s)
      if (match(s, /^[0-9]+([.][0-9]+)?/) > 0) {
        print "bandwidth", substr(s, RSTART, RLENGTH), "MBps"
      }
      # The Mbps figure in parentheses is the same measurement in link units;
      # reported too, because link budgets are quoted in Mbps.
      if (match(s, /\([0-9]+([.][0-9]+)?[ \t]*Mbps/) > 0) {
        m = substr(s, RSTART, RLENGTH)
        gsub(/[^0-9.]/, "", m)
        if (m != "") { print "bandwidth-mbps", m, "Mbps" }
      }
      next
    }

    /percentile/ {
      s = $0
      sub(/^.*percentile[ \t]*/, "", s)
      if (match(s, /^[0-9]+([.][0-9]+)?/) == 0) { next }
      p = substr(s, RSTART, RLENGTH)
      rest = substr(s, RSTART + RLENGTH)
      if (match(rest, /[0-9]+([.][0-9]+)?[ \t]*$/) == 0) { next }
      v = substr(rest, RSTART, RLENGTH)
      gsub(/[ \t]/, "", v)
      # sockperf prints percentiles with three decimals: 99.000, 99.900. The
      # trailing zeros carry no information and make the case id harder to
      # read, so p99.000 becomes p99 and p99.900 becomes p99.9. Dots are
      # valid in a LAVA test case id, so they are kept as-is.
      if (p ~ /[.]/) {
        sub(/0+$/, "", p)
        sub(/[.]$/, "", p)
      }
      print "latency-p" p, v, "usec"
      next
    }

    /<MAX> observation/ {
      v = num($NF)
      if (v != "") { print "latency-max", v, "usec" }
      next
    }

    /<MIN> observation/ {
      v = num($NF)
      if (v != "") { print "latency-min", v, "usec" }
      next
    }

    /dropped messages/ {
      s = $0
      sub(/^.*dropped messages[ \t]*=[ \t]*/, "", s)
      if (match(s, /^[0-9]+/) > 0) {
        print "dropped-messages", substr(s, RSTART, RLENGTH), "msgs"
      }
    }
  ' "$1" 2>/dev/null
}

# ---------------------------------------------------------------- run

BENCH_CMD_TIMEOUT="$TIMEOUT_SEC"
produced_any=0
# Canonical tags of the modes actually run; --modes accepts sockperf's short
# aliases, so the tag is not always the string the job passed in.
RAN_TAGS=""

for mode in $MODES; do
  case "$mode" in
    ping-pong|pp) subcmd="ping-pong"; tag="ping-pong" ;;
    under-load|ul) subcmd="under-load"; tag="under-load" ;;
    throughput|tp) subcmd="throughput"; tag="throughput" ;;
    *)
      log_warn "$TESTNAME: unknown mode '$mode'; skipping it"
      bench_metric "sockperf-${mode}" "skip"
      continue
      ;;
  esac

  RAN_TAGS="$RAN_TAGS $tag"
  mdir="$OUT_DIR/$tag"
  mkdir -p "$mdir" 2>/dev/null || true

  i=1
  while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
    runlog="$OUT_DIR/${tag}_run${i}.log"

    set -- "$BIN" "$subcmd" -i "$SERVER_IP" -p "$PORT" \
           -m "$MSG_SIZE" -t "$TIME_SEC"
    [ -n "$proto_flag" ] && set -- "$@" "$proto_flag"
    [ -n "$MPS" ] && set -- "$@" --mps "$MPS"
    # Word splitting is intended: EXTRA_ARGS is a flag string.
    # shellcheck disable=SC2086
    [ -n "$EXTRA_ARGS" ] && set -- "$@" $EXTRA_ARGS

    bench_run_logged "$runlog" "$@" || true

    parsed="$(sockperf_metrics "$runlog")"

    if [ -z "$parsed" ]; then
      log_warn "$TESTNAME: $tag iteration $i - no parsable summary"
      tail -20 "$runlog" 2>/dev/null || true
      i=$((i + 1))
      continue
    fi

    printf '%s\n' "$parsed" | while IFS=' ' read -r key val un; do
      [ -n "$key" ] || continue
      printf '%s\n' "$val" >> "$mdir/${key}.values"
      printf '%s\n' "$un" > "$mdir/${key}.units"
    done

    i=$((i + 1))
  done

  found=0
  for vf in "$mdir"/*.values; do
    [ -f "$vf" ] || continue
    key="$(basename "$vf" .values)"
    un="$(cat "$mdir/${key}.units" 2>/dev/null || true)"
    found=1
    produced_any=1

    if [ "$ITERATIONS" -gt 1 ] 2>/dev/null; then
      bench_metric_from_values "sockperf-${tag}-${key}" "$vf" "$un" "mean min max"
    else
      bench_metric_from_values "sockperf-${tag}-${key}" "$vf" "$un" "mean"
    fi
  done

  if [ "$found" -eq 0 ]; then
    log_fail "$TESTNAME: $tag produced no results"
    bench_metric "sockperf-${tag}" "fail"
  fi
done

stop_server

if [ "$produced_any" -eq 0 ]; then
  log_fail "$TESTNAME: no sockperf figures were parsed from any mode"
  bench_finish FAIL
  exit 0
fi

summary="$OUT_DIR/summary.txt"
{
  echo "# $TESTNAME summary"
  echo "binary     : $BIN"
  echo "server     : $SERVER_IP:$PORT ($PROTOCOL)"
  echo "msg_size   : $MSG_SIZE bytes"
  echo "time       : $TIME_SEC s"
  if is_loopback_ip "$SERVER_IP"; then
    echo "scope      : loopback - kernel stack and scheduler, NOT the NIC or link"
  else
    echo "scope      : remote peer - includes the NIC and the link"
  fi
  for mode in $RAN_TAGS; do
    echo "[$mode]"
    for vf in "$OUT_DIR/$mode"/*.values; do
      [ -f "$vf" ] || continue
      printf '  %-22s %s\n' "$(basename "$vf" .values)" \
        "$(bench_values_stat "$vf" mean)"
    done
  done
} > "$summary"

log_info "$TESTNAME: summary written to $summary"
cat "$summary" 2>/dev/null || true

bench_finish
exit 0

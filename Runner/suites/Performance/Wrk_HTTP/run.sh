#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# wrk / wrk2 HTTP load-testing wrapper for qcom-linux-testkit
# - Publishes requests/sec, transfer/sec, latency average/stdev/max, the wrk2
#   HdrHistogram percentiles, and the error and non-2xx counts to LAVA as
#   measurements
#
# Notes:
# - Always exits 0 (LAVA-friendly). Use Wrk_HTTP.res for gating.
# - wrk and wrk2 are not interchangeable. wrk pushes as hard as it can and
#   reports throughput; wrk2 holds a constant rate (-R) and reports an honest
#   latency distribution, because a coordinated-omission-free histogram needs
#   a fixed rate. If RATE is set, a wrk2-capable binary is required, and the
#   suite says so rather than silently dropping the flag.
# - Latencies are normalised to milliseconds and transfer rates to MB/s, so
#   the LAVA measurements are comparable across runs whatever units wrk chose
#   to print. Req/Sec's k and M suffixes are expanded for the same reason.
# - The default target is a throwaway HTTP server on loopback. That exercises
#   the kernel stack, the loopback path and the server process - NOT a NIC or
#   a link. Point --url at a real endpoint for a figure that includes those.
# - Error counts are reported as measurements rather than being folded into
#   the verdict: a run with 2% timeouts is not the same number as a clean one,
#   and whoever reads the results needs to see that.

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

TESTNAME="Wrk_HTTP"
test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null || true)"
[ -n "$test_path" ] || test_path="$SCRIPT_DIR"

OUT_DIR="${OUT_DIR:-$test_path/logs_${TESTNAME}}"
URL="${URL:-}"
DURATION="${DURATION:-30s}"
THREADS="${THREADS:-NPROC}"
CONNECTIONS="${CONNECTIONS:-100}"
RATE="${RATE:-}"
LATENCY="${LATENCY:-1}"
LUA_SCRIPT="${LUA_SCRIPT:-}"
HEADER="${HEADER:-}"
ITERATIONS="${ITERATIONS:-1}"
BINARY="${BINARY:-}"
WRK_DIR="${WRK_DIR:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"
START_SERVER="${START_SERVER:-auto}"
SERVER_PORT="${SERVER_PORT:-8080}"
SERVER_CMD="${SERVER_CMD:-}"
PAYLOAD_KB="${PAYLOAD_KB:-4}"
SERVER_WAIT_SEC="${SERVER_WAIT_SEC:-10}"
SET_PERF_GOV="${SET_PERF_GOV:-1}"
TIMEOUT_SEC="${TIMEOUT_SEC:-600}"

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]
  --out-dir DIR        output directory (default: $OUT_DIR)
  --url URL            target URL; empty means use a local throwaway server
  --duration SPEC      wrk -d value, e.g. 30s (default: $DURATION)
  --threads N|NPROC    wrk -t value (default: $THREADS)
  --connections N      wrk -c value (default: $CONNECTIONS)
  --rate N             wrk2 -R value; requires a wrk2-capable binary
  --latency 0|1        pass --latency for the distribution (default: $LATENCY)
  --lua-script PATH    wrk -s script
  --header "H: V"      extra request header
  --iterations N       repeats of the whole run (default: $ITERATIONS)
  --binary PATH        explicit wrk/wrk2 binary
  --wrk-dir DIR        directory holding the binary
  --extra-args "ARGS"  extra arguments appended verbatim
  --start-server MODE  auto|1|0 - serve a local doc root (default: $START_SERVER)
                       auto starts one only when --url is empty
  --server-port N      port for the local server (default: $SERVER_PORT)
  --server-cmd CMD     command for the local server; empty auto-detects
  --payload-kb N       size of the generated index.html (default: $PAYLOAD_KB)
  --server-wait-sec N  seconds to wait for the server (default: $SERVER_WAIT_SEC)
  --set-perf-gov 0|1   pin CPU governor to performance (default: $SET_PERF_GOV)
  --timeout-sec N      per-run timeout (default: $TIMEOUT_SEC)
  -h, --help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --url) URL="$2"; shift 2 ;;
    --duration) DURATION="$2"; shift 2 ;;
    --threads) THREADS="$2"; shift 2 ;;
    --connections) CONNECTIONS="$2"; shift 2 ;;
    --rate) RATE="$2"; shift 2 ;;
    --latency) LATENCY="$2"; shift 2 ;;
    --lua-script) LUA_SCRIPT="$2"; shift 2 ;;
    --header) HEADER="$2"; shift 2 ;;
    --iterations) ITERATIONS="$2"; shift 2 ;;
    --binary) BINARY="$2"; shift 2 ;;
    --wrk-dir) WRK_DIR="$2"; shift 2 ;;
    --extra-args) EXTRA_ARGS="$2"; shift 2 ;;
    --start-server) START_SERVER="$2"; shift 2 ;;
    --server-port) SERVER_PORT="$2"; shift 2 ;;
    --server-cmd) SERVER_CMD="$2"; shift 2 ;;
    --payload-kb) PAYLOAD_KB="$2"; shift 2 ;;
    --server-wait-sec) SERVER_WAIT_SEC="$2"; shift 2 ;;
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

BIN=""
for cand in wrk2 wrk; do
  BIN="$(bench_resolve_bin "$cand" "$BINARY" "$WRK_DIR" "$SCRIPT_DIR" "$SCRIPT_DIR/bin" || true)"
  [ -n "$BIN" ] && break
  [ -n "$BINARY" ] && break
done

if [ -z "$BIN" ] || [ ! -x "$BIN" ]; then
  bench_skip_exit "wrk/wrk2 not found (use --binary or --wrk-dir, or add wrk to the image)"
  exit 0
fi

log_info "$TESTNAME: binary=$BIN"

# wrk2 is detected from its help text rather than its filename: distributions
# package wrk2 as "wrk" often enough that trusting the name is unreliable.
WRK2_CAPABLE=0
if "$BIN" --help 2>&1 | grep -q -- '-R,'; then
  WRK2_CAPABLE=1
elif "$BIN" --help 2>&1 | grep -qi 'rate.*requests per second'; then
  WRK2_CAPABLE=1
fi

if [ -n "$RATE" ] && [ "$WRK2_CAPABLE" -eq 0 ]; then
  bench_skip_exit "RATE requested but $BIN does not support -R; install wrk2 or clear RATE"
  exit 0
fi

if [ -z "$RATE" ] && [ "$WRK2_CAPABLE" -eq 1 ]; then
  # wrk2 without -R defaults to an unbounded rate and its histogram then
  # carries the coordinated-omission problem it exists to avoid. Say so.
  log_warn "$TESTNAME: $BIN looks like wrk2 but no RATE was given; its latency distribution will not be rate-corrected"
fi

# ---------------------------------------------------------------- local server

SERVER_PID=""
SERVER_LOG="$OUT_DIR/server.log"
DOC_ROOT=""

stop_server() {
  [ -n "$SERVER_PID" ] || return 0

  if kill -0 "$SERVER_PID" 2>/dev/null; then
    log_info "$TESTNAME: stopping local HTTP server (pid $SERVER_PID)"
    kill -TERM "$SERVER_PID" 2>/dev/null || true

    _w=0
    while [ "$_w" -lt 5 ]; do
      kill -0 "$SERVER_PID" 2>/dev/null || break
      sleep 1
      _w=$((_w + 1))
    done

    kill -0 "$SERVER_PID" 2>/dev/null && kill -KILL "$SERVER_PID" 2>/dev/null || true
  fi

  SERVER_PID=""
}

cleanup() {
  stop_server
  [ -n "$DOC_ROOT" ] && [ -d "$DOC_ROOT" ] && rm -rf "$DOC_ROOT" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM HUP

want_server=0
case "$START_SERVER" in
  1) want_server=1 ;;
  0) want_server=0 ;;
  auto) [ -z "$URL" ] && want_server=1 ;;
  *)
    log_warn "$TESTNAME: unrecognised --start-server '$START_SERVER'; treating as auto"
    [ -z "$URL" ] && want_server=1
    ;;
esac

if [ "$want_server" -eq 1 ]; then
  DOC_ROOT="$(mktemp -d 2>/dev/null || echo "/tmp/wrk_docroot.$$")"
  mkdir -p "$DOC_ROOT" 2>/dev/null || true

  # A payload of a known size, so requests/sec and transfer/sec can be
  # reconciled with each other when reading the results.
  awk -v kb="$PAYLOAD_KB" '
    BEGIN {
      line = ""
      for (i = 0; i < 63; i++) { line = line "x" }
      n = kb * 16
      for (i = 0; i < n; i++) { print line }
    }
  ' > "$DOC_ROOT/index.html" 2>/dev/null || true

  if [ -z "$SERVER_CMD" ]; then
    if command -v python3 >/dev/null 2>&1; then
      SERVER_CMD="python3 -m http.server $SERVER_PORT --bind 127.0.0.1 --directory '$DOC_ROOT'"
    elif command -v busybox >/dev/null 2>&1 && busybox httpd --help 2>&1 | grep -qi httpd; then
      SERVER_CMD="busybox httpd -f -p 127.0.0.1:$SERVER_PORT -h '$DOC_ROOT'"
    elif command -v httpd >/dev/null 2>&1; then
      SERVER_CMD="httpd -f -p 127.0.0.1:$SERVER_PORT -h '$DOC_ROOT'"
    fi
  fi

  if [ -z "$SERVER_CMD" ]; then
    bench_skip_exit "no local HTTP server available (install python3 or busybox httpd, or set --url / --server-cmd)"
    exit 0
  fi

  log_info "$TESTNAME: starting local server: $SERVER_CMD"
  sh -c "$SERVER_CMD" > "$SERVER_LOG" 2>&1 &
  SERVER_PID=$!

  [ -n "$URL" ] || URL="http://127.0.0.1:$SERVER_PORT/index.html"

  # Wait for the port to answer rather than sleeping a fixed time: a slow
  # board would otherwise be load-tested against a server that is not up.
  ready=0
  _w=0
  while [ "$_w" -lt "$SERVER_WAIT_SEC" ] 2>/dev/null; do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
      log_fail "$TESTNAME: local HTTP server exited immediately"
      tail -20 "$SERVER_LOG" 2>/dev/null || true
      SERVER_PID=""
      bench_metric "wrk-server-start" "fail"
      bench_finish FAIL
      exit 0
    fi

    if command -v curl >/dev/null 2>&1; then
      curl -s -o /dev/null --max-time 2 "$URL" && { ready=1; break; }
    elif command -v wget >/dev/null 2>&1; then
      wget -q -O /dev/null -T 2 "$URL" && { ready=1; break; }
    else
      # No HTTP client to probe with; fall back to a liveness check.
      sleep 1
      ready=1
      break
    fi

    sleep 1
    _w=$((_w + 1))
  done

  if [ "$ready" -ne 1 ]; then
    log_fail "$TESTNAME: local HTTP server did not answer at $URL within ${SERVER_WAIT_SEC}s"
    tail -20 "$SERVER_LOG" 2>/dev/null || true
    bench_metric "wrk-server-start" "fail"
    bench_finish FAIL
    exit 0
  fi

  bench_metric "wrk-server-start" "pass"
  log_warn "$TESTNAME: loopback run - this measures the kernel stack and the server process, not a NIC or a link"
fi

if [ -z "$URL" ]; then
  bench_skip_exit "no target URL (set --url, or allow a local server with --start-server 1)"
  exit 0
fi

NTHREADS="$(bench_resolve_threads "$THREADS")"
[ -n "$NTHREADS" ] || NTHREADS=1

if [ "$SET_PERF_GOV" = "1" ]; then
  bench_set_governor performance
fi

# ---------------------------------------------------------------- parser

# wrk_metrics <logfile>
#
# Emits "<key> <value> <units>" lines, with every latency in ms and every
# transfer rate in MB/s.
wrk_metrics() {
  awk '
    # to_ms(value, unit): wrk prints whichever unit keeps the number short.
    function to_ms(v, u) {
      if (u ~ /^us/ || u ~ /^\xc2\xb5s/) { return v / 1000 }
      if (u ~ /^ms/) { return v }
      if (u ~ /^m$/) { return v * 60000 }
      if (u ~ /^s/)  { return v * 1000 }
      return v
    }

    # to_mb(value, unit): transfer rates, normalised to MB.
    function to_mb(v, u) {
      if (u ~ /^B/)  { return v / 1000000 }
      if (u ~ /^KB/ || u ~ /^kB/) { return v / 1000 }
      if (u ~ /^MB/) { return v }
      if (u ~ /^GB/) { return v * 1000 }
      if (u ~ /^TB/) { return v * 1000000 }
      return v
    }

    # Split "412.23us" into its number and its unit.
    function split_num(tok, parts) {
      if (match(tok, /^[0-9]+([.][0-9]+)?/) == 0) { return 0 }
      parts[1] = substr(tok, RSTART, RLENGTH)
      parts[2] = substr(tok, RSTART + RLENGTH)
      return 1
    }

    # Expand the k/M/G suffix wrk uses on Req/Sec.
    function expand_si(tok) {
      if (match(tok, /^[0-9]+([.][0-9]+)?/) == 0) { return "" }
      v = substr(tok, RSTART, RLENGTH) + 0
      s = substr(tok, RSTART + RLENGTH)
      if (s ~ /^[kK]/) { v = v * 1000 }
      else if (s ~ /^[mM]/) { v = v * 1000000 }
      else if (s ~ /^[gG]/) { v = v * 1000000000 }
      return v
    }

    # Thread Stats rows: "    Latency   412.23us    1.23ms  22.01ms   91.23%"
    $1 == "Latency" && NF >= 4 {
      if (split_num($2, p)) { printf "latency-avg %.6f ms\n", to_ms(p[1] + 0, p[2]) }
      if (split_num($3, p)) { printf "latency-stdev %.6f ms\n", to_ms(p[1] + 0, p[2]) }
      if (split_num($4, p)) { printf "latency-max %.6f ms\n", to_ms(p[1] + 0, p[2]) }
      next
    }

    # "    Req/Sec    57.21k     5.11k   70.00k    78.00%"
    ($1 == "Req/Sec" || $1 == "Req/Sec:") && NF >= 4 {
      v = expand_si($2); if (v != "") { printf "req-per-sec-per-thread-avg %.6f req/s\n", v }
      v = expand_si($4); if (v != "") { printf "req-per-sec-per-thread-max %.6f req/s\n", v }
      next
    }

    # "Requests/sec: 113948.52"
    /^[ \t]*Requests\/sec:/ {
      if (split_num($2, p)) { printf "requests-per-sec %s req/s\n", p[1] }
      next
    }

    # "Transfer/sec:     51.12MB"
    /^[ \t]*Transfer\/sec:/ {
      if (split_num($2, p)) { printf "transfer-per-sec %.6f MB/s\n", to_mb(p[1] + 0, p[2]) }
      next
    }

    # "  3429876 requests in 30.10s, 1.50GB read"
    /requests in/ {
      if ($1 ~ /^[0-9]+$/) { printf "total-requests %s requests\n", $1 }
      next
    }

    # "Socket errors: connect 0, read 0, write 0, timeout 12"
    /Socket errors:/ {
      s = $0
      sub(/^.*Socket errors:[ \t]*/, "", s)
      n = split(s, parts, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", parts[i])
        split(parts[i], kv, /[ \t]+/)
        if (kv[1] != "" && kv[2] ~ /^[0-9]+$/) {
          printf "socket-errors-%s %s errors\n", kv[1], kv[2]
        }
      }
      next
    }

    # "  Non-2xx or 3xx responses: 42"
    /Non-2xx or 3xx responses:/ {
      if (match($0, /[0-9]+[ \t]*$/) > 0) {
        v = substr($0, RSTART, RLENGTH)
        gsub(/[ \t]/, "", v)
        printf "non-2xx-3xx-responses %s responses\n", v
      }
      next
    }

    # wrk2 HdrHistogram block: " 99.000%    5.22ms"
    #
    # The percentile is held in pc, not p: p is the array passed to
    # split_num(), and awk treats using one name as both an array and a scalar
    # as a fatal error - which aborts the parse part-way through the file and
    # loses every figure after this point.
    /^[ \t]*[0-9]+([.][0-9]+)?%/ && NF >= 2 {
      pc = $1
      sub(/%$/, "", pc)
      if (pc ~ /[.]/) { sub(/0+$/, "", pc); sub(/[.]$/, "", pc) }
      if (split_num($2, q)) {
        printf "latency-p%s %.6f ms\n", pc, to_ms(q[1] + 0, q[2])
      }
      next
    }
  ' "$1" 2>"${WRK_PARSE_ERR:-/dev/null}"
}

# ---------------------------------------------------------------- run

BENCH_CMD_TIMEOUT="$TIMEOUT_SEC"
VDIR="$OUT_DIR/values"
mkdir -p "$VDIR" 2>/dev/null || true

# Parser errors go to a file instead of /dev/null. A broken parser that fails
# silently looks exactly like a benchmark that produced no numbers, and the
# two need very different fixes.
WRK_PARSE_ERR="$OUT_DIR/parse_errors.log"
: > "$WRK_PARSE_ERR"

log_info "$TESTNAME: url=$URL duration=$DURATION threads=$NTHREADS connections=$CONNECTIONS rate=${RATE:-unbounded}"

i=1
while [ "$i" -le "$ITERATIONS" ] 2>/dev/null; do
  runlog="$OUT_DIR/wrk_run${i}.log"

  set -- "$BIN" -t "$NTHREADS" -c "$CONNECTIONS" -d "$DURATION"
  [ -n "$RATE" ] && set -- "$@" -R "$RATE"
  [ "$LATENCY" = "1" ] && set -- "$@" --latency
  [ -n "$LUA_SCRIPT" ] && set -- "$@" -s "$LUA_SCRIPT"
  [ -n "$HEADER" ] && set -- "$@" -H "$HEADER"
  # Word splitting is intended: EXTRA_ARGS is a flag string.
  # shellcheck disable=SC2086
  [ -n "$EXTRA_ARGS" ] && set -- "$@" $EXTRA_ARGS
  set -- "$@" "$URL"

  bench_run_logged "$runlog" "$@" || true

  parsed="$(wrk_metrics "$runlog")"

  if [ -z "$parsed" ]; then
    log_warn "$TESTNAME: iteration $i - no parsable wrk output"
    tail -25 "$runlog" 2>/dev/null || true
    i=$((i + 1))
    continue
  fi

  printf '%s\n' "$parsed" | while IFS=' ' read -r key val un; do
    [ -n "$key" ] || continue
    printf '%s\n' "$val" >> "$VDIR/${key}.values"
    printf '%s\n' "$un" > "$VDIR/${key}.units"
  done

  i=$((i + 1))
done

stop_server

if [ -s "$WRK_PARSE_ERR" ]; then
  log_warn "$TESTNAME: the output parser reported errors; results may be incomplete"
  head -5 "$WRK_PARSE_ERR" 2>/dev/null || true
fi

found=0
for vf in "$VDIR"/*.values; do
  [ -f "$vf" ] || continue
  key="$(basename "$vf" .values)"
  un="$(cat "$VDIR/${key}.units" 2>/dev/null || true)"
  found=1

  if [ "$ITERATIONS" -gt 1 ] 2>/dev/null; then
    bench_metric_from_values "wrk-${key}" "$vf" "$un" "mean min max"
  else
    bench_metric_from_values "wrk-${key}" "$vf" "$un" "mean"
  fi
done

if [ "$found" -eq 0 ]; then
  log_fail "$TESTNAME: no figures parsed from any run"
  bench_finish FAIL
  exit 0
fi

summary="$OUT_DIR/summary.txt"
{
  echo "# $TESTNAME summary"
  echo "binary      : $BIN (wrk2-capable=$WRK2_CAPABLE)"
  echo "url         : $URL"
  echo "duration    : $DURATION"
  echo "threads     : $NTHREADS"
  echo "connections : $CONNECTIONS"
  echo "rate        : ${RATE:-unbounded}"
  case "$URL" in
    http://127.*|http://localhost*|https://127.*|https://localhost*)
      echo "scope       : loopback - kernel stack and server process, not a NIC or link"
      ;;
    *)
      echo "scope       : remote endpoint - includes the NIC and the link"
      ;;
  esac
  for vf in "$VDIR"/*.values; do
    [ -f "$vf" ] || continue
    printf '  %-28s %s %s\n' "$(basename "$vf" .values)" \
      "$(bench_values_stat "$vf" mean)" \
      "$(cat "$VDIR/$(basename "$vf" .values).units" 2>/dev/null || true)"
  done
} > "$summary"

log_info "$TESTNAME: summary written to $summary"
cat "$summary" 2>/dev/null || true

bench_finish
exit 0

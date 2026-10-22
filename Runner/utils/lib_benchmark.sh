#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# lib_benchmark.sh - shared helpers for the Performance benchmark suites.
#
# The suites under Runner/suites/Performance that measure throughput or
# latency all need the same handful of things:
#
#   - locate a benchmark binary that may or may not be in the image
#   - skip cleanly (not fail) when it is absent
#   - pin the CPU governor so numbers are comparable run to run
#   - accumulate per-iteration values and reduce them to mean/min/max
#   - publish each number to LAVA as a measurement, not just a verdict
#   - write the <TESTNAME>.res file the rest of the testkit expects
#
# This library provides those, so each run.sh stays about its own benchmark.
#
# Conventions
# -----------
# Call bench_init first. It defines:
#   BENCH_NAME      test name, used for .res and log prefixes
#   BENCH_OUT_DIR   directory for logs and intermediate files
#   BENCH_METRICS   metrics file consumed by send-metrics-to-lava.sh
#   BENCH_RES_FILE  <TESTNAME>.res consumed by send-to-lava.sh
#
# Record numbers with bench_metric, then call bench_finish. Suites are
# expected to exit 0 regardless of outcome (LAVA-friendly); the verdict
# travels in the .res file.
#
# Requires functestlib.sh to have been sourced already (for log_* helpers).
# lib_performance.sh is optional; governor control is used when present.

# Idempotency guard - sourcing twice must not reset counters mid-run.
[ -n "${__LIB_BENCHMARK_LOADED:-}" ] && return 0
__LIB_BENCHMARK_LOADED=1

BENCH_NAME=""
BENCH_OUT_DIR=""
BENCH_METRICS=""
BENCH_RES_FILE=""
BENCH_PASS_COUNT=0
BENCH_FAIL_COUNT=0
BENCH_SKIP_COUNT=0
BENCH_GOVERNOR_SET=0

# ---------------------------------------------------------------- lifecycle

# bench_init <testname> [out_dir] [res_dir]
bench_init() {
    BENCH_NAME="${1:?bench_init requires a test name}"
    BENCH_OUT_DIR="${2:-./logs_${BENCH_NAME}}"
    _res_dir="${3:-.}"

    BENCH_METRICS="$BENCH_OUT_DIR/metrics.txt"
    BENCH_RES_FILE="$_res_dir/${BENCH_NAME}.res"

    BENCH_PASS_COUNT=0
    BENCH_FAIL_COUNT=0
    BENCH_SKIP_COUNT=0

    mkdir -p "$BENCH_OUT_DIR" 2>/dev/null || true

    if [ ! -d "$BENCH_OUT_DIR" ]; then
        log_error "$BENCH_NAME: cannot create output directory $BENCH_OUT_DIR"
        return 1
    fi

    : > "$BENCH_METRICS"
    : > "$BENCH_RES_FILE"

    log_info "------------------- Starting $BENCH_NAME -------------------"
    log_info "$BENCH_NAME: out_dir=$BENCH_OUT_DIR metrics=$BENCH_METRICS"
    return 0
}

# bench_finish [force_result]
#
# Writes the .res file. With no argument the verdict is derived from the
# recorded cases: any failure means FAIL, no cases at all means SKIP,
# otherwise PASS. Pass PASS/FAIL/SKIP explicitly to override.
bench_finish() {
    _forced="${1:-}"
    _total=$((BENCH_PASS_COUNT + BENCH_FAIL_COUNT + BENCH_SKIP_COUNT))

    if [ -n "$_forced" ]; then
        _verdict="$_forced"
    elif [ "$BENCH_FAIL_COUNT" -gt 0 ]; then
        _verdict="FAIL"
    elif [ "$_total" -eq 0 ]; then
        _verdict="SKIP"
    else
        _verdict="PASS"
    fi

    log_info "$BENCH_NAME: cases pass=$BENCH_PASS_COUNT fail=$BENCH_FAIL_COUNT skip=$BENCH_SKIP_COUNT"

    case "$_verdict" in
        PASS) log_pass "$BENCH_NAME PASS" ;;
        FAIL) log_fail "$BENCH_NAME FAIL" ;;
        *)    log_skip "$BENCH_NAME $_verdict" ;;
    esac

    echo "$BENCH_NAME $_verdict" > "$BENCH_RES_FILE"
    bench_restore_governor
    log_info "------------------- Finished $BENCH_NAME -------------------"
    return 0
}

# bench_skip_exit <reason>
#
# Common path for "the benchmark is not installed on this image". Writes a
# SKIP result and returns 0 so the caller can `exit 0` without ceremony.
bench_skip_exit() {
    _reason="${1:-unspecified}"
    log_skip "$BENCH_NAME SKIP - $_reason"

    if [ -n "$BENCH_RES_FILE" ]; then
        echo "$BENCH_NAME SKIP" > "$BENCH_RES_FILE"
    fi

    bench_restore_governor
    return 0
}

# ---------------------------------------------------------------- metrics

# bench_metric <case_id> <result> [measurement] [units]
#
# Records one LAVA test case. The measurement is optional; when present it is
# published as a LAVA MEASUREMENT by send-metrics-to-lava.sh.
bench_metric() {
    _id="${1:?bench_metric requires a case id}"
    _result="$(printf '%s' "${2:-pass}" | tr '[:upper:]' '[:lower:]')"
    _meas="${3:-}"
    _units="${4:-}"

    case "$_result" in
        pass) BENCH_PASS_COUNT=$((BENCH_PASS_COUNT + 1)) ;;
        fail) BENCH_FAIL_COUNT=$((BENCH_FAIL_COUNT + 1)) ;;
        skip) BENCH_SKIP_COUNT=$((BENCH_SKIP_COUNT + 1)) ;;
        *)
            log_warn "$BENCH_NAME: unknown result '$_result' for '$_id', recording as fail"
            _result="fail"
            BENCH_FAIL_COUNT=$((BENCH_FAIL_COUNT + 1))
            ;;
    esac

    if [ -n "$_meas" ]; then
        if bench_is_number "$_meas"; then
            printf '%s %s %s %s\n' "$_id" "$_result" "$_meas" "$_units" >> "$BENCH_METRICS"
            log_info "$BENCH_NAME: $_id = $_meas ${_units} [$_result]"
        else
            # Deliberately do not emit a bad number: a non-numeric measurement
            # makes LAVA drop the whole case. Keep the verdict, lose the value.
            log_warn "$BENCH_NAME: '$_id' measurement '$_meas' is not numeric; recording result only"
            printf '%s %s\n' "$_id" "$_result" >> "$BENCH_METRICS"
        fi
    else
        printf '%s %s\n' "$_id" "$_result" >> "$BENCH_METRICS"
        log_info "$BENCH_NAME: $_id [$_result]"
    fi

    return 0
}

# bench_emit_lava
#
# Publishes the collected metrics. Normally the suite's LAVA yaml calls
# send-metrics-to-lava.sh directly; this is for standalone runs and for
# suites that prefer to emit from inside run.sh.
bench_emit_lava() {
    _emitter=""

    if [ -n "${TOOLS:-}" ] && [ -x "$TOOLS/send-metrics-to-lava.sh" ]; then
        _emitter="$TOOLS/send-metrics-to-lava.sh"
    elif command -v send-metrics-to-lava.sh >/dev/null 2>&1; then
        _emitter="send-metrics-to-lava.sh"
    fi

    if [ -z "$_emitter" ]; then
        log_warn "$BENCH_NAME: send-metrics-to-lava.sh not found; metrics left in $BENCH_METRICS"
        return 0
    fi

    [ -s "$BENCH_METRICS" ] || return 0
    "$_emitter" "$BENCH_METRICS" || true
    return 0
}

# ---------------------------------------------------------------- numbers

# bench_is_number <value>
bench_is_number() {
    printf '%s' "${1:-}" | grep -Eq '^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$'
}

# bench_values_add <file> <value>
#
# Appends one sample, ignoring anything non-numeric so a single unparsable
# iteration cannot poison the aggregate.
bench_values_add() {
    _file="${1:?bench_values_add requires a file}"
    _val="${2:-}"

    if bench_is_number "$_val"; then
        echo "$_val" >> "$_file"
        return 0
    fi

    log_warn "$BENCH_NAME: ignoring non-numeric sample '$_val'"
    return 1
}

# bench_values_stat <file> <mean|min|max|count|stddev>
#
# Prints the requested statistic, or nothing when there are no samples.
bench_values_stat() {
    _file="${1:?bench_values_stat requires a file}"
    _what="${2:-mean}"

    [ -s "$_file" ] || return 1

    awk -v what="$_what" '
        NF == 0 { next }
        {
            v = $1 + 0
            n++
            sum += v
            sumsq += v * v
            if (n == 1 || v < mn) { mn = v }
            if (n == 1 || v > mx) { mx = v }
        }
        END {
            if (n == 0) { exit 1 }
            if (what == "count") { printf "%d\n", n; exit 0 }
            if (what == "min")   { printf "%.6f\n", mn; exit 0 }
            if (what == "max")   { printf "%.6f\n", mx; exit 0 }
            if (what == "mean")  { printf "%.6f\n", sum / n; exit 0 }
            if (what == "stddev") {
                if (n < 2) { printf "0.000000\n"; exit 0 }
                mean = sum / n
                var = (sumsq / n) - (mean * mean)
                if (var < 0) { var = 0 }
                printf "%.6f\n", sqrt(var)
                exit 0
            }
            exit 1
        }
    ' "$_file" 2>/dev/null
}

# bench_metric_from_values <case_prefix> <values_file> <units> [stats]
#
# Convenience wrapper: reduces a samples file to several metrics at once.
# Default stats are mean, min and max.
bench_metric_from_values() {
    _prefix="${1:?bench_metric_from_values requires a prefix}"
    _file="${2:?bench_metric_from_values requires a values file}"
    _units="${3:-}"
    _stats="${4:-mean min max}"

    if [ ! -s "$_file" ]; then
        log_warn "$BENCH_NAME: no samples collected for $_prefix"
        bench_metric "$_prefix" "fail"
        return 1
    fi

    for _stat in $_stats; do
        _v="$(bench_values_stat "$_file" "$_stat")"
        if [ -n "$_v" ]; then
            bench_metric "${_prefix}-${_stat}" "pass" "$_v" "$_units"
        else
            bench_metric "${_prefix}-${_stat}" "fail"
        fi
    done

    return 0
}

# ---------------------------------------------------------------- binaries

# bench_resolve_bin <name> [explicit_path] [extra_dir ...]
#
# Prints an executable path for <name>, or nothing. Search order:
#   1. an explicit path supplied by the caller (--binary / BINARY)
#   2. PATH
#   3. the suite directory and any extra directories offered
#   4. the testkit's own bin locations
#
# Nothing is downloaded and nothing is built: a benchmark that is absent is a
# SKIP, because silently fetching a different build would make the numbers
# incomparable with other runs.
bench_resolve_bin() {
    _name="${1:?bench_resolve_bin requires a binary name}"
    shift

    _explicit="${1:-}"
    [ "$#" -gt 0 ] && shift

    if [ -n "$_explicit" ]; then
        if [ -x "$_explicit" ]; then
            printf '%s\n' "$_explicit"
            return 0
        fi
        log_warn "$BENCH_NAME: explicit binary '$_explicit' is not executable; falling back to search"
    fi

    if command -v "$_name" >/dev/null 2>&1; then
        command -v "$_name"
        return 0
    fi

    for _dir in "$@" "${SCRIPT_DIR:-.}" "${SCRIPT_DIR:-.}/bin" \
                "${__RUNNER_UTILS_BIN_DIR:-}" "${ROOT_DIR:-}/common"; do
        [ -n "$_dir" ] || continue
        if [ -x "$_dir/$_name" ]; then
            printf '%s\n' "$_dir/$_name"
            return 0
        fi
    done

    # Last resort: the testkit's own locator, when available.
    if command -v find_test_case_bin_by_name >/dev/null 2>&1; then
        _found="$(find_test_case_bin_by_name "$_name" 2>/dev/null || true)"
        if [ -n "$_found" ] && [ -x "$_found" ]; then
            printf '%s\n' "$_found"
            return 0
        fi
    fi

    return 1
}

# bench_require_cmds <cmd> [cmd ...]
#
# Returns non-zero if any command is missing, naming all of them so one run
# reports the complete set of gaps rather than the first.
bench_require_cmds() {
    _missing=""

    for _c in "$@"; do
        command -v "$_c" >/dev/null 2>&1 || _missing="$_missing $_c"
    done

    if [ -n "$_missing" ]; then
        log_warn "$BENCH_NAME: missing required command(s):$_missing"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------- environment

# bench_set_governor [governor]
#
# Pins the CPU frequency governor so successive runs are comparable. Uses
# lib_performance.sh when it is loaded, otherwise writes sysfs directly.
# Best effort: a board without cpufreq is not a failure.
bench_set_governor() {
    _gov="${1:-performance}"

    if command -v set_performance_governor >/dev/null 2>&1 && [ "$_gov" = "performance" ]; then
        if set_performance_governor; then
            BENCH_GOVERNOR_SET=1
            log_info "$BENCH_NAME: CPU governor pinned to performance"
            return 0
        fi
    fi

    _applied=0
    for _f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -w "$_f" ] || continue
        if echo "$_gov" > "$_f" 2>/dev/null; then
            _applied=1
        fi
    done

    if [ "$_applied" -eq 1 ]; then
        BENCH_GOVERNOR_SET=1
        log_info "$BENCH_NAME: CPU governor set to $_gov"
    else
        log_warn "$BENCH_NAME: could not set CPU governor to $_gov (continuing)"
    fi

    return 0
}

# bench_restore_governor
bench_restore_governor() {
    [ "$BENCH_GOVERNOR_SET" -eq 1 ] || return 0
    BENCH_GOVERNOR_SET=0

    if command -v restore_governor >/dev/null 2>&1; then
        restore_governor 2>/dev/null || true
    fi

    return 0
}

# bench_drop_caches
#
# Best effort page-cache drop, for storage and memory benchmarks.
bench_drop_caches() {
    sync 2>/dev/null || true

    if [ -w /proc/sys/vm/drop_caches ]; then
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
        log_info "$BENCH_NAME: dropped page cache"
    else
        log_warn "$BENCH_NAME: /proc/sys/vm/drop_caches not writable; cache not dropped"
    fi

    return 0
}

# bench_nproc
#
# Online CPU count, with fallbacks for images without coreutils' nproc.
bench_nproc() {
    if command -v nproc >/dev/null 2>&1; then
        nproc 2>/dev/null && return 0
    fi

    if command -v getconf >/dev/null 2>&1; then
        _n="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
        if [ -n "$_n" ]; then
            printf '%s\n' "$_n"
            return 0
        fi
    fi

    if [ -r /proc/cpuinfo ]; then
        grep -c '^processor' /proc/cpuinfo 2>/dev/null && return 0
    fi

    echo 1
    return 0
}

# bench_resolve_threads <value>
#
# Accepts a thread count, or the literal NPROC / 0 / "auto" meaning "all
# online CPUs". Keeps the NPROC spelling used by the Linaro test definitions
# so job writers can reuse the same parameter values.
bench_resolve_threads() {
    _t="${1:-NPROC}"

    case "$_t" in
        NPROC|nproc|auto|AUTO|0|"")
            bench_nproc
            ;;
        *)
            if bench_is_number "$_t"; then
                printf '%s\n' "$_t"
            else
                log_warn "$BENCH_NAME: invalid thread count '$_t'; using 1"
                echo 1
            fi
            ;;
    esac
}

# bench_log_env
#
# One-line record of the things that most often explain a number changing
# between runs.
bench_log_env() {
    log_info "$BENCH_NAME: kernel=$(uname -r 2>/dev/null || echo unknown) cpus=$(bench_nproc)"

    if [ -r /proc/cpuinfo ]; then
        _model="$(awk -F': ' '/model name|Processor/ { print $2; exit }' /proc/cpuinfo 2>/dev/null || true)"
        [ -n "$_model" ] && log_info "$BENCH_NAME: cpu=$_model"
    fi

    _gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
    log_info "$BENCH_NAME: governor=$_gov"

    if [ -r /proc/meminfo ]; then
        _mem="$(awk '/MemTotal/ { print $2 " " $3; exit }' /proc/meminfo 2>/dev/null || true)"
        [ -n "$_mem" ] && log_info "$BENCH_NAME: memtotal=$_mem"
    fi

    if command -v log_soc_info >/dev/null 2>&1; then
        log_soc_info 2>/dev/null || true
    fi

    return 0
}

# bench_run_logged <logfile> <command...>
#
# Runs a command, tees output to a log, and returns the command's exit status
# rather than tee's.
bench_run_logged() {
    _log="${1:?bench_run_logged requires a log file}"
    shift

    log_info "$BENCH_NAME: running: $*"

    if command -v run_with_timeout >/dev/null 2>&1 && [ -n "${BENCH_CMD_TIMEOUT:-}" ]; then
        run_with_timeout "$BENCH_CMD_TIMEOUT" "$@" > "$_log" 2>&1
        _rc=$?
    else
        "$@" > "$_log" 2>&1
        _rc=$?
    fi

    if [ "$_rc" -ne 0 ]; then
        log_warn "$BENCH_NAME: command exited rc=$_rc (see $_log)"
        tail -20 "$_log" 2>/dev/null || true
    fi

    return "$_rc"
}

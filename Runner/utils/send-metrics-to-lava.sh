#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# Emit LAVA testcase signals *with measurements* from a metrics file.
#
# send-to-lava.sh emits pass/fail only. Benchmark suites also need to publish
# the number they measured, so that LAVA stores it as a result measurement and
# it becomes queryable/graphable instead of being buried in a log file.
#
# Expected metrics-file format, one record per line, whitespace separated:
#
#   <testcase_id> <result> [measurement] [units]
#
#   coremark-iterations-per-sec pass 12345.67 iter/s
#   ddr-bw-rd-128m              pass 10240.5  MB/s
#   vkmark-score                pass 412      score
#   osbench-create-threads      fail
#
# Lines beginning with '#' and blank lines are ignored.
#
# Why measurement validation matters
# ----------------------------------
# LAVA parses MEASUREMENT as a number. If a parser upstream yields an empty
# measurement and the units are still emitted, the units token slides into the
# MEASUREMENT slot and LAVA rejects the whole signal:
#
#   error: Invalid measurement 'ms'
#
# and the test case is dropped entirely - the result is lost, not merely
# unmeasured. To make that failure mode impossible, this script validates the
# measurement against a strict numeric pattern and, when it does not match,
# emits a plain result-only signal (and warns). A case with a questionable
# number is therefore still reported, just without a measurement.
#
# This script reuses the kernel-console quieting approach of send-to-lava.sh:
# asynchronous printk messages interleaved into userspace stdout can corrupt a
# signal line, so console_loglevel is lowered only for the individual printf
# that emits the signal and restored immediately afterwards.

METRICS_FILE="${1:-}"
SIGNAL_FILE="${TMPDIR:-/tmp}/lava_metric_signals_$$.log"
PRINTK_SAVED=""
PRINTK_CHANGED=0

valid_result() {
    case "$1" in
        PASS|FAIL|SKIP|UNKNOWN)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

sanitize_testcase_id() {
    # LAVA testcase IDs should be token-safe. Keep only characters that do not
    # interfere with signal parsing.
    printf '%s' "$1" | tr -dc '[:alnum:]_.:-'
}

sanitize_units() {
    # Units travel inside the signal line, so keep them token-safe too. Spaces
    # would break field parsing on the LAVA side.
    printf '%s' "$1" | tr -dc '[:alnum:]_./%-'
}

is_number() {
    # Strict decimal / scientific notation. Deliberately rejects the empty
    # string, bare signs, and trailing-garbage values such as "232.5ms".
    printf '%s' "$1" | grep -Eq '^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$'
}

save_and_quiet_kernel_console() {
    PRINTK_SAVED=""
    PRINTK_CHANGED=0

    # /proc/sys/kernel/printk format:
    # console_loglevel default_message_loglevel minimum_console_loglevel default_console_loglevel
    #
    # Set only console_loglevel to 1 while preserving the remaining fields.
    if [ -r /proc/sys/kernel/printk ] && [ -w /proc/sys/kernel/printk ]; then
        PRINTK_SAVED="$(cat /proc/sys/kernel/printk 2>/dev/null || true)"

        if [ -n "$PRINTK_SAVED" ]; then
            quiet_printk="$(
                printf '%s\n' "$PRINTK_SAVED" |
                awk 'NF >= 4 { $1 = 1; print }'
            )"

            if [ -n "$quiet_printk" ]; then
                if printf '%s\n' "$quiet_printk" > /proc/sys/kernel/printk 2>/dev/null; then
                    PRINTK_CHANGED=1
                fi
            fi
        fi
    fi

    return 0
}

restore_kernel_console() {
    if [ "$PRINTK_CHANGED" = "1" ] &&
       [ -n "$PRINTK_SAVED" ] &&
       [ -w /proc/sys/kernel/printk ]; then
        printf '%s\n' "$PRINTK_SAVED" > /proc/sys/kernel/printk 2>/dev/null || true
    fi

    PRINTK_SAVED=""
    PRINTK_CHANGED=0
}

cleanup() {
    restore_kernel_console
    rm -f "$SIGNAL_FILE"
}

trap cleanup EXIT HUP INT TERM

rm -f "$SIGNAL_FILE"

if [ -z "$METRICS_FILE" ]; then
    echo "[WARNING] Metrics file argument missing" >&2
    exit 0
fi

if [ ! -f "$METRICS_FILE" ]; then
    echo "[WARNING] Metrics file missing: $METRICS_FILE" >&2
    exit 0
fi

# Build the validated signal buffer first, so that parsing problems are
# reported before anything touches the console loglevel.
while IFS= read -r line || [ -n "$line" ]; do
    # Metrics records are token based. Intentional word splitting.
    # shellcheck disable=SC2086
    set -- $line

    [ "$#" -gt 0 ] || continue

    case "$1" in
        \#*)
            continue
            ;;
    esac

    if [ "$#" -lt 2 ]; then
        echo "[WARNING] Ignoring malformed metric line: $line" >&2
        continue
    fi

    testcase="$1"
    result="$2"
    measurement="${3:-}"
    units="${4:-}"

    result="$(printf '%s' "$result" | tr '[:lower:]' '[:upper:]')"
    testcase_clean="$(sanitize_testcase_id "$testcase")"

    if [ -z "$testcase_clean" ]; then
        echo "[WARNING] Ignoring metric line with invalid testcase id: $line" >&2
        continue
    fi

    if ! valid_result "$result"; then
        echo "[WARNING] Ignoring metric line with invalid result: $line" >&2
        continue
    fi

    if [ -z "$measurement" ]; then
        # No measurement offered at all - a plain pass/fail case.
        printf '<<<LAVA_SIGNAL_TESTCASE TEST_CASE_ID=%s RESULT=%s>>>\n' \
            "$testcase_clean" "$result" >> "$SIGNAL_FILE"
        continue
    fi

    if ! is_number "$measurement"; then
        # A measurement was offered but is not a number LAVA will accept.
        # Emit the verdict without it rather than losing the case.
        echo "[WARNING] Non-numeric measurement '$measurement' for '$testcase_clean'; emitting result only" >&2
        printf '<<<LAVA_SIGNAL_TESTCASE TEST_CASE_ID=%s RESULT=%s>>>\n' \
            "$testcase_clean" "$result" >> "$SIGNAL_FILE"
        continue
    fi

    units_clean="$(sanitize_units "$units")"

    if [ -n "$units_clean" ]; then
        printf '<<<LAVA_SIGNAL_TESTCASE TEST_CASE_ID=%s RESULT=%s UNITS=%s MEASUREMENT=%s>>>\n' \
            "$testcase_clean" "$result" "$units_clean" "$measurement" >> "$SIGNAL_FILE"
    else
        printf '<<<LAVA_SIGNAL_TESTCASE TEST_CASE_ID=%s RESULT=%s MEASUREMENT=%s>>>\n' \
            "$testcase_clean" "$result" "$measurement" >> "$SIGNAL_FILE"
    fi
done < "$METRICS_FILE"

# Emit signals with the smallest possible critical section.
if [ -s "$SIGNAL_FILE" ]; then
    while IFS= read -r signal_line || [ -n "$signal_line" ]; do
        [ -n "$signal_line" ] || continue

        save_and_quiet_kernel_console
        printf '\n%s\n\n' "$signal_line"
        restore_kernel_console
    done < "$SIGNAL_FILE"
fi

rm -f "$SIGNAL_FILE"

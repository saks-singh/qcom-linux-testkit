#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# metrics-from-sysbench-csv.sh <csv-file> [out-file]
#
# Convert Sysbench_Performance's CSV into the record format that
# send-metrics-to-lava.sh consumes, so sysbench scores reach LAVA as
# measurements instead of only a pass/fail verdict.
#
# Input (written by perf_sysbench_csv_append):
#   timestamp,test,threads,metric,iteration,value
#   2026-10-22 11:00:00,cpu,4,time_sec,1,10.0021
#   2026-10-22 11:00:30,memory,4,mem_mbps,1,8421.33
#
# Output:
#   sysbench-cpu-time-sec-t4-mean pass 10.002100 s
#   sysbench-memory-mem-mbps-t4-mean pass 8421.330000 MB/s
#
# Values are grouped by (test, threads, metric) and aggregated across
# iterations. A single iteration emits the mean only; two or more also emit
# min and max, because with repeats the spread is part of the result - a mean
# that hides a 3x outlier is how a flaky board passes review.
#
# Always exits 0: a missing or unparsable CSV must not fail the job, since the
# suite's own verdict is carried separately by its .res file.

CSV="${1:-}"
OUT="${2:-}"

if [ -z "$CSV" ] || [ ! -r "$CSV" ]; then
  echo "[WARN] metrics-from-sysbench-csv: no readable CSV at '${CSV:-<unset>}'" >&2
  exit 0
fi

emit() {
  awk -F',' '
    function isnum(x) {
      return (x ~ /^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/)
    }

    # Units come from the metric name sysbench recorded, not from a guess:
    # the CSV carries no unit column, and a wrong unit in a trend chart is
    # worse than none.
    function units(m) {
      if (m ~ /mbps$/)  { return "MB/s" }
      if (m ~ /iops$/)  { return "IOPS" }
      if (m ~ /_sec$/)  { return "s" }
      if (m ~ /_ms$/)   { return "ms" }
      if (m ~ /eps$/)   { return "events/s" }
      if (m ~ /lat/)    { return "ms" }
      return ""
    }

    # LAVA accepts a limited character set in a test case id.
    function slug(s) {
      gsub(/_/, "-", s)
      gsub(/[^A-Za-z0-9.:-]/, "-", s)
      gsub(/-+/, "-", s)
      sub(/^-+/, "", s)
      sub(/-+$/, "", s)
      return tolower(s)
    }

    NR == 1 && $0 ~ /^timestamp,/ { next }

    NF >= 6 {
      test = $2; thr = $3; metric = $4; val = $6

      gsub(/^[ \t]+|[ \t]+$/, "", test)
      gsub(/^[ \t]+|[ \t]+$/, "", thr)
      gsub(/^[ \t]+|[ \t]+$/, "", metric)
      gsub(/^[ \t]+|[ \t]+$/, "", val)

      if (test == "" || metric == "" || !isnum(val)) { next }

      key = test SUBSEP thr SUBSEP metric
      if (!(key in n)) { order[++count] = key; mn[key] = val + 0; mx[key] = val + 0 }
      n[key]++
      sum[key] += val + 0
      if ((val + 0) < mn[key]) { mn[key] = val + 0 }
      if ((val + 0) > mx[key]) { mx[key] = val + 0 }
    }

    END {
      for (i = 1; i <= count; i++) {
        key = order[i]
        split(key, p, SUBSEP)
        test = p[1]; thr = p[2]; metric = p[3]

        id = "sysbench-" slug(test) "-" slug(metric)
        if (thr != "") { id = id "-t" slug(thr) }

        u = units(metric)
        if (u != "") {
          printf "%s-mean pass %.6f %s\n", id, sum[key] / n[key], u
        } else {
          printf "%s-mean pass %.6f\n", id, sum[key] / n[key]
        }

        if (n[key] > 1) {
          if (u != "") {
            printf "%s-min pass %.6f %s\n", id, mn[key], u
            printf "%s-max pass %.6f %s\n", id, mx[key], u
          } else {
            printf "%s-min pass %.6f\n", id, mn[key]
            printf "%s-max pass %.6f\n", id, mx[key]
          }
        }
      }
    }
  ' "$CSV" 2>/dev/null
}

if [ -n "$OUT" ]; then
  emit > "$OUT" 2>/dev/null || true
  [ -s "$OUT" ] || echo "[WARN] metrics-from-sysbench-csv: no numeric rows in $CSV" >&2
else
  emit
fi

exit 0

#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# metrics-from-tiotest-tsv.sh <tsv-file> [out-file]
#
# Convert Tiotest's metrics TSV into the record format that
# send-metrics-to-lava.sh consumes, so storage throughput, IOPS and latency
# reach LAVA as measurements instead of only a pass/fail verdict.
#
# Input (written by tiotest_metrics_append, no header, 8 tab-separated
# columns, any field possibly empty):
#   mode  threads  mbps  iops  lat_avg_ms  lat_max_ms  pct_gt2s  pct_gt10s
#   seqwr 4        512.30 131148  0.412     22.010      0.000     0.000
#
# Output:
#   tiotest-seqwr-t4-throughput-mean pass 512.300000 MB/s
#   tiotest-seqwr-t4-iops-mean pass 131148.000000 IOPS
#   tiotest-seqwr-t4-latency-avg-mean pass 0.412000 ms
#   ...
#
# Rows are grouped by (mode, threads) and aggregated across iterations: the
# suite appends one row per iteration, so without grouping the same case id
# would be emitted repeatedly and LAVA would keep only the last value.
#
# Empty fields are skipped rather than coerced to zero. tiotest leaves the
# latency columns blank when run with latency reporting hidden, and a blank
# read as 0 ms would look like an impossibly fast device.
#
# Always exits 0: the suite's verdict is carried separately by its .res file.

TSV="${1:-}"
OUT="${2:-}"

if [ -z "$TSV" ] || [ ! -r "$TSV" ]; then
  echo "[WARN] metrics-from-tiotest-tsv: no readable TSV at '${TSV:-<unset>}'" >&2
  exit 0
fi

emit() {
  awk -F'\t' '
    function isnum(x) {
      return (x ~ /^[+-]?([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$/)
    }

    function slug(s) {
      gsub(/_/, "-", s)
      gsub(/[^A-Za-z0-9.:-]/, "-", s)
      gsub(/-+/, "-", s)
      sub(/^-+/, "", s)
      sub(/-+$/, "", s)
      return tolower(s)
    }

    function add(key, val) {
      if (!(key in n)) { order[++count] = key; mn[key] = val + 0; mx[key] = val + 0 }
      n[key]++
      sum[key] += val + 0
      if ((val + 0) < mn[key]) { mn[key] = val + 0 }
      if ((val + 0) > mx[key]) { mx[key] = val + 0 }
    }

    BEGIN {
      # column index -> metric suffix and units
      name[3] = "throughput";  unit[3] = "MB/s"
      name[4] = "iops";        unit[4] = "IOPS"
      name[5] = "latency-avg"; unit[5] = "ms"
      name[6] = "latency-max"; unit[6] = "ms"
      name[7] = "pct-gt-2s";   unit[7] = "%"
      name[8] = "pct-gt-10s";  unit[8] = "%"
    }

    # Tolerate a header line if one is ever added upstream.
    $1 == "mode" { next }

    NF >= 3 {
      mode = $1; thr = $2
      gsub(/^[ \t]+|[ \t]+$/, "", mode)
      gsub(/^[ \t]+|[ \t]+$/, "", thr)
      if (mode == "") { next }

      base = "tiotest-" slug(mode)
      if (thr != "") { base = base "-t" slug(thr) }

      for (c = 3; c <= 8; c++) {
        v = $c
        gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (!isnum(v)) { continue }
        add(base "-" name[c] SUBSEP unit[c], v)
      }
    }

    END {
      for (i = 1; i <= count; i++) {
        key = order[i]
        split(key, p, SUBSEP)
        id = p[1]; u = p[2]

        printf "%s-mean pass %.6f %s\n", id, sum[key] / n[key], u
        if (n[key] > 1) {
          printf "%s-min pass %.6f %s\n", id, mn[key], u
          printf "%s-max pass %.6f %s\n", id, mx[key], u
        }
      }
    }
  ' "$TSV" 2>/dev/null
}

if [ -n "$OUT" ]; then
  emit > "$OUT" 2>/dev/null || true
  [ -s "$OUT" ] || echo "[WARN] metrics-from-tiotest-tsv: no numeric rows in $TSV" >&2
else
  emit
fi

exit 0

#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
#
# make/perl-free CoreMark-PRO certify run, for images that carry prebuilt
# CoreMark-PRO workload binaries but no make or perl.
#
# Follows upstream's certify-all (Makefile.mak certify-process/wcertify-%,
# util/perl/cert_median.pl, util/perl/cert_mark.pl):
# - for each concurrency type, single (-c1 -w1) and best (-c<contexts>):
#   - one verification run (-v1) per workload
#   - three performance runs (-v0); the score is the median iter/s
# - CoreMark-PRO mark = 1000 * geomean(iter/s * reference weight)
# and prints the same WORKLOAD RESULTS TABLE / MARK RESULTS TABLE, so run.sh
# parses it exactly as it parses a make certify-all log.
#
# Usage: certify.sh --bin-dir DIR [--contexts N] [--runs N]

BIN_DIR=""
CONTEXTS=""
RUNS=3

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bin-dir) BIN_DIR="$2"; shift 2 ;;
    --contexts) CONTEXTS="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    *) echo "certify.sh: unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$BIN_DIR" ] || [ ! -d "$BIN_DIR" ]; then
  echo "certify.sh: --bin-dir DIR is required" >&2
  exit 2
fi
[ -n "$CONTEXTS" ] || CONTEXTS="$(nproc 2>/dev/null || echo 1)"

# Workload name and reference weight, from cert_mark.pl.
WORKLOADS="cjpeg-rose7-preset:1/40.3438
core:10000/2855
linear_alg-mid-100x100-sp:1/38.5624
loops-all-mid-10k-sp:1/0.87959
nnet_test:1/1.45853
parser-125k:1/4.81116
radix2-big-64k:1/99.6587
sha-test:1/48.5201
zip-test:1/21.3618"

SCORES="$(mktemp 2>/dev/null || echo "/tmp/cmp_scores.$$")"
: > "$SCORES"
trap 'rm -f "$SCORES"' EXIT

# Print "<iter/s> <fails>" for one run of a workload; iter/s is rounded to two
# places as results_parser.pl writes it into the results log.
run_once() {
  # $1 binary, rest flags
  bin="$1"
  shift
  "$bin" "$@" 2>&1 | tee -a "$RAWLOG" | awk '
    /:iterations=/ { sub(/.*=/, ""); its = $0 + 0 }
    /:time\(secs\)=/ { sub(/.*=/, ""); secs = $0 + 0 }
    /fails=/ { v = $0; sub(/.*fails=/, "", v); fails += v + 0 }
    /^-- Done:/ { done = 1 }
    END {
      if (!done) { print "NA 1"; exit }
      # A short verification run can report 0 secs; only its fails count.
      if (secs <= 0) { printf "INF %d\n", fails; exit }
      printf "%.2f %d\n", its / secs, fails
    }'
}

RAWLOG="${RAWLOG:-/dev/null}"

cd "$BIN_DIR" || exit 2
echo "CoreMark-PRO certify (make/perl-free): bin=$BIN_DIR contexts=$CONTEXTS runs=$RUNS"

for contype in single best; do
  if [ "$contype" = "single" ]; then
    flags="-c1 -w1"
  else
    flags="-c$CONTEXTS"
  fi
  echo "	Gathering results for $contype ($flags)"

  printf '%s\n' "$WORKLOADS" | while IFS=: read -r wld weight; do
    [ -n "$wld" ] || continue
    bin="./$wld.exe"
    if [ ! -x "$bin" ]; then
      echo "	$wld: binary missing"
      echo "$wld $contype NA 1" >> "$SCORES"
      continue
    fi

    echo "	Verification run for $wld"
    set -- $(run_once "$bin" $flags -v1)
    vfails="$2"
    [ "$1" = "NA" ] && vfails=1

    echo "	Performance runs for $wld"
    perf=""
    pfails=0
    i=1
    while [ "$i" -le "$RUNS" ]; do
      set -- $(run_once "$bin" $flags -v0)
      if [ "$1" = "NA" ] || [ "$1" = "INF" ]; then
        pfails=$((pfails + 1))
      else
        perf="$perf $1"
        pfails=$((pfails + $2))
      fi
      i=$((i + 1))
    done

    med="$(printf '%s\n' $perf | sort -n | awk '
      { v[NR] = $1 }
      END {
        if (NR == 0) { print "NA"; exit }
        if (NR % 2) print v[(NR + 1) / 2]
        else printf "%.2f\n", (v[NR / 2] + v[NR / 2 + 1]) / 2
      }')"
    echo "	$wld $contype: runs=[$perf ] median=$med verify_fails=$vfails perf_fails=$pfails"
    echo "$wld $contype $med $((vfails + pfails))" >> "$SCORES"
  done
done

awk -v weights="$(printf '%s\n' "$WORKLOADS" | tr '\n' ' ')" '
  { ips[$1, $2] = $3; err[$1, $2] = $4 }
  END {
    n = split(weights, w, " ")
    for (i = 1; i <= n; i++) {
      split(w[i], p, ":")
      name[i] = p[1]
      split(p[2], q, "/")
      wt[i] = q[1] / q[2]
    }

    print ""
    print "WORKLOAD RESULTS TABLE"
    print ""
    printf "%-47s %10s %10s %10s\n", "", "MultiCore", "SingleCore", ""
    printf "%-47s %10s %10s %10s\n", "Workload Name", "(iter/s)", "(iter/s)", "Scaling"
    dash = "-----------------------------------------------"
    printf "%-47s %10s %10s %10s\n", dash, substr(dash, 1, 10), substr(dash, 1, 10), substr(dash, 1, 10)
    for (i = 1; i <= n; i++) {
      s = ips[name[i], "single"]; b = ips[name[i], "best"]
      sv = (s == "NA" || s == "") ? "n/a" : sprintf("%10.2f", s)
      bv = (b == "NA" || b == "") ? "n/a" : sprintf("%10.2f", b)
      sc = (sv != "n/a" && bv != "n/a" && s + 0 != 0) ? sprintf("%10.2f", b / s) : "n/a"
      printf "%-47s %10s %10s %10s\n", name[i], bv, sv, sc
    }

    print ""
    print "MARK RESULTS TABLE"
    print ""
    printf "%-47s %10s %10s %10s\n", "Mark Name", "MultiCore", "SingleCore", "Scaling"
    printf "%-47s %10s %10s %10s\n", dash, substr(dash, 1, 10), substr(dash, 1, 10), substr(dash, 1, 10)
    bad = 0
    ls = 0; lb = 0
    for (i = 1; i <= n; i++) {
      s = ips[name[i], "single"]; b = ips[name[i], "best"]
      if (s == "NA" || s == "" || b == "NA" || b == "" || err[name[i], "single"] || err[name[i], "best"]) {
        print "certify.sh: ERROR: Missing or failed score for " name[i]
        bad = 1
        continue
      }
      ls += log(s * wt[i]); lb += log(b * wt[i])
    }
    if (bad) {
      print "certify.sh: ERROR: Could not compute score for '\''CoreMark-PRO'\''"
      exit 1
    }
    single = 1000 * exp(ls / n); best = 1000 * exp(lb / n)
    printf "%-47s %10.2f %10.2f %10.2f\n", "CoreMark-PRO", best, single, best / single
  }' "$SCORES"

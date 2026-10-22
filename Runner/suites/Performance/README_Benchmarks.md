# Performance benchmark suites

This directory holds the performance-build benchmark suites. They differ from
most of the testkit in one way that matters: they publish **measurements** to
LAVA, not just verdicts, so a result can be compared between builds and
boards rather than only checked for pass/fail.

Everything here follows the repo's suite idiom - `run.sh` walks up for
`Runner/init_env`, sources `$TOOLS/functestlib.sh`, resolves its own path via
`find_test_case_by_name`, writes `<TESTNAME>.res`, and **always exits 0** so
LAVA sees the test's own verdict rather than a shell exit code. Gate on the
`.res` file.

## Contents

| Suite | Directory | What it measures |
|---|---|---|
| Coremark | `Coremark/` | Single-core CPU, iterations/sec |
| CoreMark-PRO | `CoremarkPro/` | Multicore and single-core workloads, and the scaling ratio |
| OSBench | `OSBench/` | Kernel/OS primitives: thread, process, memory, file creation |
| DDR latency + bandwidth | `DDR_Lmbench/` | lmbench `lat_mem_rd` and `bw_mem` (rd/frd/wr/fwr/bzero/cp/bcopy) |
| DDR speed | `DDR_RAMspeed/` | RAMspeed/RAMsmp copy/scale/add/triad and per-block-size rates |
| Scheduler (threads) | `Threadbench/` | Thread create/switch throughput across thread counts |
| Graphics (Vulkan) | `Vkmark/` | vkmark overall score and per-scene fps |
| GPU + CPU | `QMLBench/` | qmlbench per-benchmark averages and total score |
| Sockets | `Sockperf/` | Latency, percentiles, message rate, bandwidth |
| HTTP load | `Wrk_HTTP/` | wrk/wrk2 requests/sec, transfer/sec, latency distribution |
| Real-time latency | `Cyclictest_Scenarios/` | cyclictest wake-up latency, three load scenarios |

Already present elsewhere in the repo and **not** duplicated here:

- **Storage (TIO)** - `Performance/Tiotest/`
- **Hackbench** - `Kernel/RT-tests/Hackbench/`
- **Cyclictest runner** - `Kernel/RT-tests/Cyclictest/`; the scenarios in
  `Cyclictest_Scenarios/` are job definitions that drive it, not a second
  implementation
- **glmark2** - `Multimedia/Graphics/X11_Glmark2/` *validates* rendering but
  publishes no measurement, so glmark2 **scores** are not yet in LAVA. A
  `Performance` counterpart would be needed for that; see "Known gaps".

## Publishing measurements: `send-metrics-to-lava.sh`

`Runner/utils/send-to-lava.sh` emits verdicts only. Rather than change it -
over a hundred suites depend on its behaviour - these suites use a sibling:

```
Runner/utils/send-metrics-to-lava.sh <metrics-file>
```

Input is one record per line:

```
<testcase_id> <result> [measurement] [units]
```

e.g.

```
coremark-iterations-per-sec pass 24531.80 iter/s
ddr-latency-main-memory-read pass 112.400 ns
cyclictest-all-max-latency-max pass 132 us
wrk-latency-p99.9 pass 12.31 ms
```

It validates strictly, and that is the point. An **empty measurement field
lets the units token slide into the measurement slot**, LAVA rejects the
signal with `Invalid measurement 'ms'`, and **drops the whole test case** -
so a parser bug silently becomes a missing result. The emitter therefore
rejects anything that is not a plain number (including `232.5ms` and a bare
sign), sanitises the case id and the units to the characters LAVA accepts,
and falls back to a result-only signal with a warning rather than emitting a
record LAVA will discard.

Each suite writes `$OUT_DIR/metrics.txt` and the job definition pipes it
through the emitter, then sends the verdict:

```yaml
- '$REPO_PATH/Runner/utils/send-metrics-to-lava.sh "$OUT_DIR/metrics.txt" || true'
- '$REPO_PATH/Runner/utils/send-to-lava.sh Coremark.res'
```

### `expected:` is a whitelist

If a job definition carries an `expected:` list, LAVA forces any case **not**
on it to `fail`. These suites emit case ids derived from the tool's own output
(scene names, percentiles, block sizes), so the set is not fully known in
advance. Either omit `expected:` or keep it in step with the suite.

## Shared helpers: `Runner/utils/lib_benchmark.sh`

Common behaviour lives in one library so the suites stay comparable:

- `bench_init` / `bench_finish` / `bench_skip_exit` - lifecycle and `.res`
- `bench_metric` - one measurement
- `bench_values_add` / `bench_values_stat` / `bench_metric_from_values` -
  mean/min/max across iterations
- `bench_resolve_bin` - find a benchmark binary
- `bench_set_governor` / `bench_restore_governor` - pin to `performance` and
  put it back, so a run is not scored against a drifting clock
- `bench_drop_caches`, `bench_nproc`, `bench_resolve_threads` (`NPROC` →
  online CPU count), `bench_log_env`
- `bench_run_logged` - run a command capturing **both** streams and honouring
  `BENCH_CMD_TIMEOUT`. Both streams matter: lmbench's `bw_mem` and
  `lat_mem_rd` write their results to stderr.

### `bench_resolve_bin` never downloads and never builds

If a benchmark binary is missing, the suite **SKIPs**. It does not fetch
sources and compile on the DUT. A score from a differently-compiled binary -
different compiler, flags, or libc - is not comparable with the rest of the
series, and an incomparable number in a trend chart is worse than a gap.
Supply binaries in the image, or via each suite's `--binary` / `--*-dir`.

For the same reason, no suite silently substitutes a different tool.
`Threadbench` in `auto` mode SKIPs when no threadbench binary is present
rather than quietly reporting `perf bench sched` figures under the same name.

## Running a suite by hand

```sh
cd Runner/suites/Performance/Coremark
./run.sh --out-dir /tmp/cm --iterations 3
cat Coremark.res
cat /tmp/cm/summary.txt
```

Every suite accepts `--help`, `--out-dir`, `--iterations` and
`--timeout-sec`; most accept `--set-perf-gov 0|1`. An unknown flag is a
**FAIL**, not a silent ignore - a yaml/`run.sh` flag mismatch would otherwise
be invisible in LAVA.

## Real-time scenarios

`Cyclictest_Scenarios/` holds three job definitions over the existing
`Kernel/RT-tests/Cyclictest` runner, using its `BACKGROUND_CMD` parameter:

| File | Load |
|---|---|
| `rt-cyclictest-noload.yaml` | none - the baseline |
| `rt-cyclictest-stressng-mem.yaml` | `stress-ng --vm` memory pressure |
| `rt-cyclictest-glmark2.yaml` | glmark2 driving the GPU |

Read the loaded runs **against the no-load baseline**; a maximum latency on
its own says little. In the glmark2 scenario glmark2 is the load, not the
subject - its score is not collected.

Two deliberate choices:

- Both loaded scenarios **SKIP when the load generator is missing** instead of
  running cyclictest idle. An unloaded run reported under a loaded test name
  reads as an excellent result for a test that never happened.
- Both wrap the load in `exec`. `perf_rt_bg_stop` kills the PID it started,
  which is the `sh -c` wrapper; `exec` makes that PID the workload itself, so
  it reaps its own children instead of orphaning `stress-ng` workers or a
  `--run-forever` glmark2 onto whatever runs next on that board. `stress-ng`
  also gets its own `--timeout` as a second belt.

The runner already writes `result.txt` in the emitter's input format, so the
scenarios publish per-thread and aggregate min/avg/max latency in
microseconds with no extra parsing.

## Loopback caveat (Sockperf, Wrk_HTTP)

Both default to a server on the DUT over loopback. That is reproducible and
needs no lab topology, but it measures the **kernel network stack and the
server process** - not a NIC, a PHY or a link. Point `SERVER_IP` / `URL` at a
real peer for a figure that includes those. Both suites label the scope in
their summary so a loopback number is never mistaken for a wire number.

`Wrk_HTTP` additionally distinguishes wrk from wrk2 by probing `--help` for
`-R,` rather than trusting the filename, because distributions package wrk2 as
`wrk` often enough. Setting `RATE` without a wrk2-capable binary **SKIPs**
rather than dropping the flag; a wrk2 binary used *without* `RATE` warns,
because its latency histogram then carries the coordinated-omission problem
wrk2 exists to avoid.

## Error counts are measurements, not verdicts

Socket errors, non-2xx responses and dropped messages are published as
measurements. A run with 2% timeouts is not the same number as a clean one,
and folding that into a single pass/fail hides it from whoever reads the
trend.

## Known gaps

- **glmark2 scores** are not published - see the table above.
- **Browser benchmarks** (MotionMark, Speedometer, JetStream, Wirple,
  WebXPRT) are out of scope for this set.
- **ShellCheck** could not be run in the environment these suites were
  written in, although `CONTRIBUTING.md` requires it. The repo's POSIX
  idioms were held manually and every script passes `sh -n`; please run
  ShellCheck before merging.

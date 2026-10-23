# Hackbench (performance)

Scheduler / IPC benchmark. Groups of tasks pass messages over sockets or
pipes; the figure of merit is the **wall time** to complete the exchange, so
**lower is better**. Publishes the per-iteration times to LAVA as
measurements.

## Why this exists alongside `Kernel/RT-tests/Hackbench`

The RT-tests suite resolves the binary with a plain `PATH` lookup
(`rt_resolve_binary` → `command -v hackbench`). On an image where rt-tests is
not installed as `/usr/bin/hackbench` it SKIPs, even when the same workload is
reachable another way — which is what happened on job 503943:

```
[SKIP] Hackbench: hackbench binary not found/executable (none)
```

This suite changes two things:

1. **Wider search.** rt-tests is packaged under `/usr/lib/rt-tests`,
   `/usr/libexec/rt-tests`, `/opt/rt-tests` and others depending on the
   distribution; all are probed, and the list of what was tried is logged so a
   SKIP can be diagnosed from the job log alone.
2. **`perf bench sched messaging` fallback.** perf's `sched messaging`
   benchmark *is* hackbench, imported into perf's bench suite. Where an image
   ships perf but not rt-tests, that is a real hackbench number with no image
   change.

## The engine is in the case id

| Engine | Case ids |
|---|---|
| `hackbench` binary | `hackbench-time-{mean,min,max}` |
| `perf bench sched messaging` | `hackbench-perf-bench-sched-messaging-time-{mean,min,max}` |

The two implementations are not interchangeable to the decimal point, so
averaging them into one series would hide which actually ran. For the same
reason, `perf bench sched messaging` has no `-f`/`-s` equivalent: `FDS` and
`DATASIZE` do not apply to it, and `summary.txt` says so rather than
pretending they were honoured.

If neither engine is available the suite **SKIPs**; it does not download or
build hackbench (see `README_Benchmarks.md`).

## Usage

```sh
cd Runner/suites/Performance/Hackbench_Performance
./run.sh --out-dir /tmp/hb --iterations 10 --grps 10 --loops 100
cat Hackbench_Performance.res
cat /tmp/hb/summary.txt
```

`./run.sh --help` lists every option.

## Comparing times

A hackbench time only means something against a run with the same **engine,
group count, loop count and transport** (sockets vs pipes, processes vs
threads). All of those are recorded in `summary.txt`. Changing the group count
changes the amount of work, not the speed of the scheduler.

## Output

- `logs_Hackbench_Performance/metrics.txt` — emitter records, published by
  `send-metrics-to-lava.sh`
- `logs_Hackbench_Performance/<engine>_run<N>.log` — raw output per iteration
- `logs_Hackbench_Performance/summary.txt` — run parameters and mean/min/max
- `Hackbench_Performance.res` — `PASS|FAIL|SKIP`, the gating verdict

**Do not put an `expected:` list for this suite in a job definition** — the
case id prefix depends on which engine was resolved, and LAVA treats
`expected:` as a whitelist, so it would force the other engine's cases to
`fail`.

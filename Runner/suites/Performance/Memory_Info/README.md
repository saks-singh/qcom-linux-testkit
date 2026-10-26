# Memory info (/proc/meminfo)

Reads `/proc/meminfo` and publishes the system-wide memory counters to LAVA as
measurements, in **kB** — the unit `/proc/meminfo` itself uses. The whole file
is archived per sample, so any other counter can be re-derived later without
another run.

Nothing is allocated or freed; this is a read of kernel counters.

## Why this exists alongside `Memory_Map`

`Memory_Map` walks per-process `smaps` for PSS attribution — it answers "which
process is holding the memory". This suite reports the system-wide totals and
is the one to trend.

## What is published

| Case id | Source | Units |
|---|---|---|
| `meminfo-memtotal` | `MemTotal` | kB |
| `meminfo-memfree` | `MemFree` | kB |
| `meminfo-cached` | `Cached` | kB |
| `meminfo-memavailable` | `MemAvailable`, the kernel's own estimate | kB |
| `meminfo-memtotal-minus-free-and-cached` | `MemTotal - (MemFree + Cached)` | kB |
| `meminfo-used-percent` | the above as a share of `MemTotal` | % |

Anything named in `EXTRA_FIELDS` is published the same way, so
`EXTRA_FIELDS: "SwapTotal SwapFree Buffers Shmem Slab"` adds
`meminfo-swaptotal` and friends with no code change.

With `ITERATIONS` above 1 the point values keep the ids above (taken from the
last sample) and `-mean`, `-min` and `-max` are published alongside them, so
the id set does not change shape with the sample count.

## The two "available" numbers are not the same thing

This matters, because they get used interchangeably and they are not
interchangeable:

- **`MemAvailable`** is the kernel's estimate of how much can be allocated
  without swapping. It deliberately excludes the part of the page cache that
  **cannot** be reclaimed — mapped pages, dirty pages, and the low watermark.
- **`MemTotal - (MemFree + Cached)`** counts *all* of `Cached` as free on
  demand. What it actually describes is memory currently **held** by anonymous
  pages, slab and the kernel — that is, **used** memory, not available memory.

So expect the subtraction to be the **smaller** number, and the gap between
them to be non-reclaimable page cache plus the watermark. Calling the
subtraction "available" would overstate free memory by the whole page cache.

Both are published, under names that say which is which. Nothing is published
under a bare `available` id, which would be ambiguous.

## Cached depends on what ran first

`Cached` reflects whatever touched the filesystem most recently. After
`Tiotest` has written several GB it describes `Tiotest`, not the booted system.

**Run this suite early in a job**, before the benchmarks that do I/O, if the
figure is meant to characterise the image. `SETTLE_SECS` is there for the
opposite end of the same problem: immediately after boot the counters are still
moving as services finish starting.

## Usage

```sh
cd Runner/suites/Performance/Memory_Info
./run.sh --out-dir /tmp/mem --iterations 5 --interval-secs 2
cat Memory_Info.res
cat /tmp/mem/summary.txt
```

`./run.sh --help` lists every option.

## Output

- `logs_Memory_Info/metrics.txt` — emitter records, published by
  `send-metrics-to-lava.sh`
- `logs_Memory_Info/meminfo-sample<N>.txt` — the full file, per sample
- `logs_Memory_Info/meminfo-last.txt` — the sample the point values come from
- `logs_Memory_Info/series.tsv` — one row per sample, for plotting
- `logs_Memory_Info/summary.txt`
- `Memory_Info.res` — `PASS|FAIL|SKIP`, the gating verdict

**Do not put an `expected:` list for this suite in a job definition** —
`EXTRA_FIELDS` and `ITERATIONS` both change which case ids appear, and LAVA
treats `expected:` as a whitelist, so it would force every unlisted case to
`fail`.

## Missing fields are SKIP, never 0

`MemAvailable` does not exist on kernels older than 3.14, and an arbitrary
`EXTRA_FIELDS` entry may not exist at all. Those are recorded as SKIP — absent
data, not a reading of zero — and the suite still PASSes.

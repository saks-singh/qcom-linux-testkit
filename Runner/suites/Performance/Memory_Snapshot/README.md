# Memory_Snapshot

Collects the **device identity** and the kernel's **memory accounting sources**
on the DUT, publishes the counters worth trending to LAVA as measurements, and
writes a `snapshot.json` that another tool can consume.

Everything here is a **read**. Nothing is allocated, freed, started or stopped,
and nothing is written outside `$OUT_DIR`. It is safe to run at any point in a
job, and it is cheap enough to run twice.

## Why this suite exists

The [`qcom-perf-skills`](https://github.com/qualcomm-linux/qcom-perf-skills)
`memory-analysis` skill (`memory-skills/skills/memory-analysis`) is a
**host-side orchestrator**: it reaches a device over ADB or SSH, reads a fixed
set of read-only kernel files, normalises them to a schema, and only then runs
its analysis and HTML report stages.

Its two transports are both awkward inside a LAVA job - adbd needs
`/etc/usb-debugging-enabled` and a reboot and does not autostart, and SSH needs
DUT networking the lab does not guarantee - and LAVA cannot consume an HTML
report. But the **collection stage is deterministic shell work**: every device
command it issues is a `cat`, `ls`, `uname`, `dmesg`, `journalctl` or
`getprop`. That half reproduces exactly on the DUT, with no host at all, which
is what this suite is.

So the split is:

| Stage | Deterministic? | Where it runs here |
|---|---|---|
| Device identity + source collection | yes | **this suite, on the DUT** |
| Normalisation to the snapshot schema | yes | **this suite** (`snapshot.json`) |
| Two-snapshot comparison / regression | yes | off the board, in CI, on two `snapshot.json` artifacts |
| Anomaly RCA, HTML report | no | not in scope |

## Schema conformance

`$OUT_DIR/snapshot.json` is written against the skill's own contract,
`memory-skills/common/schema/memory-snapshot.schema.json`, **`schema_version`
`1.0.0`**:

```json
{
  "schema_version": "1.0.0",
  "snapshot_id": "<uuid v4>",
  "timestamp": "2026-10-27T10:08:54Z",
  "label": "baseline",
  "dump_dir": "/.../logs_Memory_Snapshot/raw",
  "device": { "serial": "...", "model": "...", "kernel_version": "...", "soc_id": "..." },
  "sources": {
    "meminfo": { "available": true, "path": "/proc/meminfo", "parsed": { "MemTotal": 34695904 } },
    "slabinfo": { "available": false, "path": "/proc/slabinfo", "parsed": {} },
    "debugfs": {
      "dmabuf": { "available": true, "path": "...", "parsed": { "total_kb": 12288 } },
      "cma":    { "available": true, "path": "...", "parsed": { } },
      "kgsl":   { "available": false, "path": "...", "parsed": {} }
    }
  },
  "collection_errors": [ { "source": "cma", "error": "no CMA regions under ..." } ]
}
```

That is what makes a **baseline captured by one LAVA job comparable with a
later one**: the skill's offline comparison needs two snapshots and no device.

Two deliberate choices in the writer:

- `parsed` holds the **headline numbers this suite also publishes**, not a
  reimplementation of every upstream per-source parser. The schema leaves
  `parsed` an open object, and the **raw file is archived beside it**, so a
  richer parse never needs another board booking.
- If a UUID cannot be generated, `snapshot_id` is emitted as `null` rather than
  as an invented value, so a validator sees the problem instead of a
  plausible-looking lie. The JSON is then **parsed back** (`python3`, else
  `jq`, else a brace-balance check) and `snapshot-json-valid` reports the
  result.

## What reaches LAVA

| Case id | Units | Source |
|---|---|---|
| `snapshot-device-identified` | — (verdict) | serial + kernel version both resolved |
| `snapshot-meminfo-<field>` | kB | `/proc/meminfo`, 26 fields plus `EXTRA_MEMINFO_FIELDS` |
| `snapshot-slab-total`, `snapshot-slab-cache-count` | kB, — | `/proc/slabinfo`, summed `num_objs × objsize` |
| `snapshot-vmstat-<name>` | pages | `/proc/vmstat` |
| `snapshot-memblock-reserved-total`, `-range-count`, `snapshot-memblock-memory-total` | kB, — | `/sys/kernel/debug/memblock/{reserved,memory}` |
| `snapshot-dt-reserved-region-count` | — | `/proc/device-tree/reserved-memory/*` |
| `snapshot-dmabuf-total`, `snapshot-dmabuf-object-count` | kB, — | `/sys/kernel/debug/dma_buf/bufinfo` |
| `snapshot-cma-<region>-total`, `-used`, `snapshot-cma-region-count` | pages | `/sys/kernel/debug/cma/<region>/{count,used}` |
| `snapshot-kgsl-page-alloc`, `-max`, `snapshot-kgsl-proc-count` | kB, — | `/sys/class/kgsl/kgsl/`, `/sys/kernel/debug/kgsl/proc/` |
| `snapshot-zram<N>-orig-data`, `-compressed-data`, `-mem-used-total` | kB | `/sys/block/zram<N>/mm_stat` |
| `snapshot-pss-total`, `snapshot-process-count` | kB, — | `/proc/<pid>/smaps_rollup` |
| `snapshot-pss-<name>` | kB | top `PSS_TOP` processes |
| `snapshot-sources-available`, `snapshot-sources-total` | count | how much of the source list this image exposes |
| `snapshot-json-valid` | — (verdict) | `snapshot.json` parsed back |

**Process cases are keyed on the process NAME, with PSS summed across every
instance - never on a PID.** A PID-keyed case id changes on every boot, which
makes the trend useless and the case set unbounded, and two instances of the
same binary would otherwise collide on one id.

Device identity is **not** published as a measurement. A serial or a model
string is not a number, and forcing one into a measurement slot makes LAVA drop
the case. It goes to the log, to `raw/device-info.txt`, to `summary.txt` and
into the JSON's `device` block.

`snapshot-sources-available` is worth watching on its own: it moves when a
kernel config changes, and it explains a sudden gap in the other cases without
anyone having to open the log.

## A missing source is a SKIP, never a zero

A kernel built without `CONFIG_CMA` and a kernel with an empty CMA region are
different findings. Every unreadable source produces `skip` for its cases,
`"available": false` in the JSON, and an entry in `collection_errors[]` saying
why - *not present*, *not readable*, or *read returned nothing*. `/proc` files
report size 0, so emptiness is judged on the archived copy rather than on the
original.

## Reserved memory: why memblock and not the device tree

`memblock`'s debugfs view is **text** and carries both ends of every range, so
the reserved total can be summed exactly. The device-tree `reserved-memory`
node encodes its ranges as big-endian cells whose width depends on
`#address-cells`/`#size-cells`, which shell cannot decode reliably - so the
region **names** are recorded and the **sizes come from memblock**. Nothing is
guessed from the binary blob.

## Bracketing a workload

A single snapshot is a fact about a moment, not about an image: `Cached`,
dma-buf and PSS all describe whatever last ran on the board. To attribute a
change to a workload, take two and compare them off the board:

```yaml
- test:   # Memory_Snapshot, params: { LABEL: "baseline" }
- test:   # the workload
- test:   # Memory_Snapshot, params: { LABEL: "after_test", OUT_DIR: "./logs_after" }
```

Give the second one a different `OUT_DIR` so both artifacts survive.

## Running it by hand

```sh
cd Runner/suites/Performance/Memory_Snapshot
./run.sh --out-dir /tmp/ms --label baseline --pss-top 5
cat Memory_Snapshot.res
cat /tmp/ms/summary.txt
cat /tmp/ms/snapshot.json
ls /tmp/ms/raw/
```

An unknown flag is a **FAIL**, not a silent ignore - a yaml/`run.sh` flag
mismatch would otherwise be invisible in LAVA.

## Output files

| Path | Contents |
|---|---|
| `snapshot.json` | the schema 1.0.0 artifact |
| `metrics.txt` | emitter input, `<case_id> <result> [measurement] [units]` |
| `summary.txt` | human-readable digest, device block, top PSS, collection errors |
| `raw/<source>.txt` | verbatim copy of each collected source |
| `raw/device-info.txt` | serial, model, kernel, SoC id/family/revision, OS, nproc |
| `raw/dmesg.txt`, `raw/journal-kernel.txt` | kernel log, if `COLLECT_DMESG=1` |
| `raw/extra-*.txt` | `/proc/modules`, `/proc/vmallocinfo`, `/proc/swaps` - archived, no schema slot |
| `pss-by-pid.tsv`, `pss-by-name.tsv` | the PSS working files, kept for attribution |
| `collection-errors.tsv` | what could not be read, and why |

## Do not add an `expected:` list

Most of the case ids are derived at runtime - one per CMA region the kernel
declares, one per process in the PSS top N, one per `EXTRA_MEMINFO_FIELDS`
entry. LAVA treats `expected:` as a **whitelist** and forces every unlisted
case to `fail`.

## Visibility

`snapshot.json` and `raw/` contain kernel log lines, loaded module names and
process names. Set `visibility: personal` on a job that collects them if that
is sensitive for your image; the existing performance jobs are
`visibility: public`.

## Relationship to the other memory suites

- `Memory_Info/` - the four `/proc/meminfo` headline totals only. Small,
  focused, and the one to trend per build.
- `Memory_Map/` - walks per-process `smaps` for full PSS attribution ("which
  process holds the memory").
- `Memory_Snapshot/` - this one. The **whole source set** at one instant, in a
  schema another tool consumes. It overlaps both by design: the point is one
  self-consistent capture, not the minimum set of numbers.

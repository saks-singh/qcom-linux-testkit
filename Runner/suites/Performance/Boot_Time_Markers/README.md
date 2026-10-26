# Boot time markers

Publishes boot-phase **timestamps** and **durations** to LAVA as measurements.
Everything is in seconds. Lower is better for every figure.

This measures the boot that already happened — it reads kernel and systemd
records. Nothing here reboots the target; for repeated-boot statistics see
`Boot_Systemd_KPI_Loop`.

## Why this exists alongside `Boot_Systemd_Validate`

`Boot_Systemd_Validate` collects the same artifacts (`systemd-analyze
time/blame/critical-chain`, the boot journal) and gates them against
`boot_kpi_goals`, but it emits a **single pass/fail verdict**. None of the
individual markers reach LAVA as numbers, so there is nothing to trend.

This suite publishes each marker as its own measurement and does no gating, so
a boot-time regression shows up as a moving number rather than as a threshold
that one day trips.

## The clock

dmesg timestamps and systemd's `*TimestampMonotonic` properties are the **same
clock** — `CLOCK_MONOTONIC`, zero at kernel start — so they can be subtracted
from one another. That is what makes the kernel markers line up with the
systemd phases.

Firmware and bootloader happen **before** that zero. systemd reports them as
durations only (read out of UEFI variables); they have no timestamp on this
scale.

## What is published

### Phase durations, from `systemd-analyze time`

| Case id | Meaning |
|---|---|
| `boot-phase-firmware-duration` | time in firmware (UEFI only) |
| `boot-phase-loader-duration` | time in the bootloader (UEFI only) |
| `boot-phase-kernel-duration` | kernel start to userspace handover |
| `boot-phase-initrd-duration` | initramfs, when there is one |
| `boot-phase-userspace-duration` | userspace to boot finished |
| `boot-total-duration` | the `= N` total on the same line |

### systemd manager timestamps

| Case id | Property |
|---|---|
| `boot-kernel-start-timestamp` | `KernelTimestampMonotonic` (0 by definition) |
| `boot-initrd-start-timestamp` | `InitRDTimestampMonotonic` |
| `boot-userspace-start-timestamp` | `UserspaceTimestampMonotonic` |
| `boot-finish-timestamp` | `FinishTimestampMonotonic` |
| `boot-units-load-{start,finish}-timestamp` + `-duration` | **unit-file loading**, `UnitsLoad{Start,Finish}TimestampMonotonic` |
| `boot-generators-{start,finish}-timestamp` + `-duration` | generator run |
| `boot-security-{start,finish}-timestamp` + `-duration` | security setup (SELinux/IMA policy load) |
| `boot-userspace-to-finish-duration` | userspace span from the manager's own clock |

Both ends of unit-file loading are published, not just the span: a shift in
*when* loading starts and a change in *how long* it takes have different
causes.

### Kernel breakdown, from the kernel log

| Case id | Log line matched |
|---|---|
| `boot-kernel-smp-brought-up-timestamp` | `smp: Brought up …` |
| `boot-kernel-rootfs-mounted-timestamp` | `VFS: Mounted root` / `mounted filesystem` |
| `boot-kernel-freeing-unused-memory-timestamp` | `Freeing unused kernel memory` |
| `boot-kernel-init-process-timestamp` | `Run /sbin/init as init process` — **`/init` as a process** |
| `boot-kernel-rootfs-mounted-to-init-duration` | derived |
| `boot-init-to-systemd-duration` | init handover → `UserspaceTimestampMonotonic` |

The kernel log comes from `dmesg`, falling back to `journalctl -k -b -o
short-monotonic` when `dmesg` is restricted (`kernel.dmesg_restrict`) — both
print the same monotonic clock. Without `CONFIG_PRINTK_TIME` there are no
timestamps to parse and these markers SKIP; the suite says so once rather than
per marker.

### Per-unit markers

For each unit in `UNITS` (default includes **`systemd-udevd.service`**,
**`systemd-udev-trigger.service`**, `systemd-udev-settle.service`,
`local-fs.target`, **`sysinit.target`**, `basic.target`, `multi-user.target`,
`graphical.target`):

| Case id suffix | Property |
|---|---|
| `-start-timestamp` | `InactiveExitTimestampMonotonic` — the job started |
| `-active-timestamp` | `ActiveEnterTimestampMonotonic` — it became active |
| `-startup-duration` | active − start |
| `-finish-timestamp` | `InactiveEnterTimestampMonotonic`, for units that completed and left |
| `-run-duration` | finish − start, i.e. a oneshot's whole run |
| `-blame-duration` | what `systemd-analyze blame` attributes to it |

Unit names lose their dots in the case id, because LAVA case ids are flat
identifiers: `systemd-udev-trigger.service` →
`boot-unit-systemd-udev-trigger-service-run-duration`.

`-blame-duration` is kept as a **separate** id rather than reconciled with
`-startup-duration`. They can legitimately differ: blame measures what systemd
attributes to the unit, which for a `Type=oneshot` is the whole run and for
`Type=notify` ends at the notification. Where they disagree, the difference is
the interesting part.

### Targets and the slowest units

- `boot-target-<target>-reached-after` for `TARGET`
- `boot-default-target-reached-after` when the default differs from `TARGET`
- `boot-blame-<unit>-duration` for the `BLAME_TOP` slowest units

`systemd-analyze` only volunteers a "reached after" line for the **default**
target. For any other target the suite falls back to that unit's
`ActiveEnterTimestamp` measured from the start of userspace, which is the same
information.

## Absent markers are SKIP, never 0

A board that boots without UEFI has no firmware or loader figure. Reporting
that as `0 s` would read as an instantaneous firmware, and the zero would then
drag down any average taken across boards. Every marker this platform does not
have is recorded as SKIP instead — missing data, not a fast boot.

The same applies to units: `systemd-udev-settle.service` is deprecated and
absent on many current images, and `graphical.target` is not reached on a
headless Yocto build. Both SKIP, and the suite still PASSes.

## Usage

```sh
cd Runner/suites/Performance/Boot_Time_Markers
./run.sh --out-dir /tmp/boot --target multi-user.target
cat Boot_Time_Markers.res
cat /tmp/boot/summary.txt
```

`./run.sh --help` lists every option.

## Output

- `logs_Boot_Time_Markers/metrics.txt` — emitter records, published by
  `send-metrics-to-lava.sh`
- `logs_Boot_Time_Markers/systemd-analyze-{time,blame,critical-chain}.txt`
- `logs_Boot_Time_Markers/kernel-log.txt`, `manager-properties.txt`,
  `journal-boot.txt`, `journal-errors.txt`, `targets.txt`
- `logs_Boot_Time_Markers/summary.txt`
- `Boot_Time_Markers.res` — `PASS|FAIL|SKIP`, the gating verdict

**Do not put an `expected:` list for this suite in a job definition** — the
case ids depend on which units exist on the image and on which units turn up in
`systemd-analyze blame`, and LAVA treats `expected:` as a whitelist, so it
would force every unlisted case to `fail`.

## Comparing boots

A boot time is only comparable against a boot of the same image on the same
board with the same `systemctl get-default`. Enabling one service shifts
`boot-phase-userspace-duration` without anything having got slower. The default
target actually reached is recorded in `summary.txt` for exactly this reason.

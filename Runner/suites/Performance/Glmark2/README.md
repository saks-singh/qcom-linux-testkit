# Glmark2 (performance)

glmark2 OpenGL / OpenGL ES 2.0 benchmark. Publishes the **overall glmark2
Score** and **per-scene FPS** to LAVA as measurements.

## Why this exists alongside `Multimedia/Graphics/X11_Glmark2`

`Multimedia/Graphics/X11_Glmark2` *validates* that rendering works inside a
real XFCE session, and publishes a verdict only. On an image with no desktop
session - the usual case on a board - it SKIPs, so glmark2 **scores** never
reached LAVA. This suite takes whichever window system the board actually has
and reports the numbers.

The two are complementary, not duplicates: one answers "does the desktop
render", this one answers "how fast".

## Window system

glmark2 selects its window system by **binary name**, not by a flag. Upstream
builds `glmark2`, `glmark2-es2`, `glmark2-wayland`, `glmark2-es2-wayland`,
`glmark2-drm` and `glmark2-es2-drm` from one tree, so `--flavour` picks the
family and the binary is resolved from it:

| `--flavour` | Binaries tried, in order |
|---|---|
| `wayland` | `glmark2-es2-wayland`, `glmark2-wayland` |
| `x11` | `glmark2-es2`, `glmark2` |
| `drm` | `glmark2-es2-drm`, `glmark2-drm` |

ES2 comes first in every family: it is the variant Qualcomm boards ship and
the one with working drivers, while the desktop-GL variant is often absent or
falls back to software rendering - a software number under a GPU test name is
worse than no number.

`auto` (the default) adopts a running Wayland session if there is one (via
`lib_display.sh`), else uses X11 if `DISPLAY` is set, else falls back to
`drm`, which needs no compositor and is usually right on a headless board.

If no matching binary is present the suite **SKIPs**; it does not download or
build one (see `README_Benchmarks.md`).

## Usage

```sh
cd Runner/suites/Performance/Glmark2
./run.sh --out-dir /tmp/glmark2 --size 1920x1080 --iterations 3
cat Glmark2.res
cat /tmp/glmark2/summary.txt
```

`./run.sh --help` lists every option.

## Comparing scores

A glmark2 Score is the **sum over the scenes that ran**, so it is only
comparable against a run with the same binary flavour, scene list (`-b`) and
size. Change any of those and the scale changes - that is not a faster board.
`summary.txt` records all three for exactly this reason.

## Output

- `logs_Glmark2/metrics.txt` - emitter records, published by
  `send-metrics-to-lava.sh`
- `logs_Glmark2/glmark2_run<N>.log` - raw glmark2 output per iteration
- `logs_Glmark2/summary.txt` - run parameters and the mean score
- `Glmark2.res` - `Glmark2 PASS|FAIL|SKIP`, the gating verdict

Case ids:

```
glmark2-score-mean pass 1789.000000 points
glmark2-scene-build-use-vbo-true-fps-mean pass 1234.000000 fps
```

The per-scene ids come from glmark2's own output (scene name plus its
options), so they are not known in advance - **do not put an `expected:` list
for this suite in a job definition**, as LAVA treats it as a whitelist and
would force every scene case to `fail`.

Scene options are part of the case id on purpose: `[build] use-vbo=true` and
`use-vbo=false` are different measurements, and keying on the scene name alone
would average them into one meaningless figure.

# Panel material experiment

The tested live-blur replacements do not reach the requested 30% memory reduction
on this macOS 27 machine. Keep Liquid Glass as the default. The popover material
is the closest visual match among the replacements tested, with a flatter edge,
less refraction, and a darker background in light mode.

## Implementation

`PanelSurface` constructs only the selected backend:

| Mode | Surface |
| --- | --- |
| `glass` | Existing regular `NSGlassEffectView`, default |
| `hud` | `NSVisualEffectView`, HUD material, behind-window blur |
| `popover` | `NSVisualEffectView`, popover material, behind-window blur |
| `solid` | Ordinary layers without a material effect; diagnostic control |

Both blur replacements retain the panel geometry, text, additive foreground
blends, scrolling, tint setting, rounded corners, and shadow. A stretchable mask
clips the blur to rounded corners. The shadow uses an explicit rounded path.
The flipped foreground has its own backing layer to keep header icons rendering
correctly during expansion. Blur hosts also enable explicit proportional scaling
for the header icon to avoid a cropped cached bitmap during its fade.

All modes use the existing animation code: an **85 ms fade**, a **120 ms scale
settle** from 1.08 to 1, a 70 ms close, and a 150 ms results reveal. The benchmark
also checks that reopening during a close fade cancels the pending dismissal.
The material switch adds no polling or persistent display link.

Apple documents live behind-window blur for
[NSVisualEffectView](https://developer.apple.com/documentation/appkit/nsvisualeffectview)
and its
[blending mode](https://developer.apple.com/documentation/appkit/nsvisualeffectview/blendingmode-swift.property).
The
[materials](https://developer.apple.com/documentation/appkit/nsvisualeffectview/material-swift.enum)
adapt to system appearance and accessibility settings. Apple provides no memory
or speed guarantee relative to Liquid Glass. A standalone [CALayer background filter](https://developer.apple.com/documentation/quartzcore/calayer/backgroundfilters)
does not document the cross-window backdrop capture needed here.

## Measurements

One fresh final verification run per material and theme. Memory is in MiB (2²⁰ bytes). The earlier three-run comparison per material/theme showed the same small savings; its raw results remain in `build/material-benchmark-final`. The table below describes the final code with explicit header-icon scaling.

| Theme | Material | First collapsed footprint | First expanded, settled | After interaction footprint | After interaction RSS | Footprint saving |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| dark | glass | 20.72 | 30.53 | 37.06 | 116.05 | 0.00% |
| dark | hud | 18.56 | 30.14 | 36.11 | 114.59 | 2.57% |
| dark | popover | 18.56 | 29.97 | 36.02 | 114.58 | 2.82% |
| light | glass | 20.77 | 24.97 | 30.52 | 113.05 | 0.00% |
| light | hud | 18.63 | 24.34 | 29.58 | 111.67 | 3.07% |
| light | popover | 18.66 | 24.36 | 29.74 | 111.75 | 2.56% |

Synchronous timing in milliseconds. Each typing percentile covers 36 query updates. The CPU column covers the whole typing scenario, including animation work.

| Theme | Material | First show | Reopen p50 | Typing p50 | Typing p95 | Typing CPU |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| dark | glass | 41.38 | 15.86 | 10.34 | 23.15 | 1329.4 |
| dark | hud | 28.55 | 14.38 | 10.33 | 23.76 | 1148.2 |
| dark | popover | 31.47 | 14.61 | 8.76 | 24.91 | 1136.0 |
| light | glass | 36.23 | 15.45 | 10.41 | 25.38 | 1305.5 |
| light | hud | 34.57 | 14.91 | 6.99 | 24.45 | 1053.2 |
| light | popover | 38.39 | 14.23 | 12.82 | 26.19 | 1141.1 |

The solid-background control uses ordinary layers while keeping the foreground and animation machinery. One control run per theme gave:

| Theme | Solid footprint after interaction | Solid RSS after interaction |
| --- | ---: | ---: |
| dark | 36.36 | 114.47 |
| light | 29.74 | 111.22 |

Visible-idle CPU is 0.37–0.77 ms over one second (under 0.1% of one core, including measurement overhead), after the probe’s display link stops. Final WindowServer RSS deltas overlap at 0.36–0.53 MiB across all modes, subject to the compositor limits below.

Removing the material entirely still leaves memory close to the live-blur versions.
This control suggests the 30% target needs work beyond replacing the background
material on this host. It does not establish the same limit on macOS 26.

Popover saves about **2–3% of settled footprint**, with about 1% less RSS. Early
collapsed footprint falls by roughly 11%, which also misses the target. Typing
CPU falls by roughly 13–15% in the final pass. Typing and display-link timings vary
across runs; these samples do not establish an improvement in GPU frame delivery
or guarantee the absence of a latency regression.

Dark-mode expansion temporarily reaches approximately 112–113 MiB of footprint
in every live-blur mode before settling near 30–31 MiB. The large transient
allocation is shared by all backgrounds in this comparison.

All 24 comparison/verification runs completed, including rapid reopening during
dismissal. Panel, content and window dimensions, backing scale, and fade/scale
durations match across all materials in seven sampled layout states.
`make IDENTITY=-` and all 196 headless tests passed. Capture checks covered
collapsed panels, expanded lists and cards in both themes. The final icon scaling
fix was inspected in light mode. A separate recording shows repeated fade/scale
animations in `build/material-preview/popover-fade.mov`.

## Method and limits

Release build, macOS 27.0.1 (26A434), Apple M5 Pro, 24 GiB RAM, a 60 Hz display,
640-point panel width and 2x backing scale. The app still targets macOS 26;
these measurements establish behavior on this host only.

Each run starts a fresh process with default, unsaved preferences, seven visible
rows, no menu-bar icon or recent-app rows, and the real app index. Benchmark runs
skip hotkey registration so the installed copy can remain running. The initial comparison uses three runs
per material and theme with rotating material order; final verification uses one
fresh run per material and theme after the icon scaling correction. Capture and VM inspection run
separately from timing comparisons.

Memory comes from Mach `TASK_VM_INFO`: physical footprint is the primary metric,
with resident size and compressed memory recorded separately. Samples cover
pre-panel idle, collapsed first open, expanded results, a calculator card,
hidden state, repeated reopening, and settled results after interaction.
Expansion produces large temporary allocations; the settled expanded sample
waits three seconds, and the final idle sample follows a longer settling period.

Timing measures synchronous `show()` calls after controller construction and
query updates through layout. It excludes controller construction and is not an
input-to-present GPU measurement. Display-link callback gaps describe main-thread
pacing. Gaps while the panel is hidden during repeated reopening are not evidence
of visible animation hitches. The typing scenario updates 36 queries; reopening
cycles ten times. Idle CPU is sampled after the probe's display link stops.

WindowServer RSS is sampled against its pre-run value. The compositor serves the
whole desktop, and RSS omits compressed and some GPU memory. Its exact physical
footprint was unavailable without elevated privileges, so the experiment cannot
fully exclude shifting costs into WindowServer.

## Reproduce

Build and measure:

```sh
make IDENTITY=-
python3 scripts/benchmark-materials.py --output build/material-benchmark
python3 scripts/benchmark-materials.py --materials solid --repetitions 1 --output build/material-solid-control
```

Inspect visuals and VM allocation separately:

```sh
python3 scripts/benchmark-materials.py --repetitions 1 --capture --vmmap --output build/material-captures
```

For an interactive comparison, quit the running copy, then start the built app
directly so it inherits the development environment:

```sh
SPOTLITE_DEV_MATERIAL=popover SPOTLITE_SHOW_ON_LAUNCH=1 build/Spotlite.app/Contents/MacOS/Spotlite
```

Change `popover` to `hud` or `glass`. An unset or unrecognized material selects
glass. The regular app uses saved preferences; only the benchmark substitutes
fixed preferences. Detailed logs, samples, summaries and optional captures live
in the chosen output directory under ignored `build/`.

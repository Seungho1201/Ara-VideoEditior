# Waveform stability during scrubbing — 2026-09-27

The waveform's two-point sampling grid previously started at the dirty rectangle's left
edge. Moving the playhead invalidates narrow strips, so each repaint changed the bars'
positions and sometimes their source samples. The grid now starts at the clip's timeline
position; the dirty rectangle only limits which bars are drawn. Neighboring strokes are
included at repaint edges. Source in-points, playback speed, and visible-area culling remain
in use.

## Automated verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --arch arm64`: **98 tests passed**.
- Two AppKit bitmap regression tests compare incremental drawing with a fresh full drawing:
  48 forward/backward playhead comparisons at three zoom levels and 1×/2× backing scales,
  plus two tiled repaint comparisons. Fixtures include fractional clip starts, trimmed
  source ranges, 2×/0.5× speed, selected/unselected clips, and two audio tracks.
- The regression reproduced the displaced waveform before the fix. After the fix, all
  comparisons pass with a one-level (out of 255) allowance for Quartz alpha rounding.
- Release build: ARM64 Mach-O; ad hoc app signature verified; `git diff --check` passed.

## Running app

- Relaunched `build/Ara.app` and reopened the existing `Untitled.framestudio` project.
- Clicked the ruler to move 02:05 → 04:53 → 11:08 → 06:37 → 02:05 (60 fps).
  The captured A1 waveform region was identical before and after: **0 changed pixels**.
- The desktop tool's synthetic drag did not advance the playhead, so this live check used
  ruler clicks. Drag input is covered by the existing AppKit responder tests; a physical
  trackpad drag was not verified in this run.
- The user's saved project SHA-256 remained
  `c51eff254c06e38aa696d252247bbb0aae9eb6b3e0d4146c3cf3f8bdc9258037`.

Local screenshots and test/build logs are in the ignored `TestArtifacts/waveform-repaint/`.

# Cross Dissolve on a continuous split — 2026-09-27

The reported transition is applied, but it blends identical source frames. In the
running app, both V1 clips refer to the same video. The first starts at source
00:00:00:00 and lasts 00:00:07:44; the second starts at timeline/source 00:00:07:44.
Both use 1x speed and identical picture settings. Extending the outgoing tail and
incoming head for the centred dissolve therefore maps both pictures to the same
source time throughout its one-second window.

Verified with the existing ARM64 release modules and the actual source:

- A two-second excerpt around the cut, with and without Cross Dissolve, remains
  visually identical. Maximum mean normalized RGB difference at six sampled frames
  was 0.000157 (8-bit rendering round-off).
- A separate control changes the incoming source in-point to 11 seconds. Its
  midpoint visibly shows both scenes, each at 50%. Maximum mean RGB error against
  the expected gamma-domain blend was 0.001447.
- The original-media and existing FHD-proxy compositions agree within 0.005591
  mean normalized RGB difference across both cases.
- Both compositions exported to 1920×1080, 60 fps, two-second MP4 files. The maximum
  preview-composition versus decoded-output difference was 0.007505 across the six
  sampled frames in each file (including the reported playhead offset).

Metrics use 160×90 sRGB samples. PNGs at the midpoint were also inspected visually.
The control was exercised through the preview composition and exporter, without
replacing the running app's unsaved project. Clip selection was inspected and then
restored to the transition; the playhead remained at 00:00:08:04. No application
code, clip timing, source ranges, or transition settings were changed.

Local reproduction script, log, PNGs and MP4s are in the ignored directory
`TestArtifacts/dissolve-check/`. The script checks that the saved reference project
is byte-for-byte unchanged. It links against the current release `FrameCore.o` and
`FrameMedia.o`; it is a diagnostic for this source/cut, not a full transition suite.

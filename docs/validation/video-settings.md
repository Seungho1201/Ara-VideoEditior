# Timeline video settings — 2026-09-26

- Removed the frame-rate footer from Media. Settings now live in Export (⌘E), alongside HD/4K resolution; the temporary TIMELINE gear has been removed.
- Presets: 16:9, 9:16, 1:1, 4:3, 4:5; 23.976, 24, 25, 29.970, 30, 50, 59.940, 60 fps (NDF).
- Preview, transform hit-testing, PNG snapshots and H.264/AAC export use the saved aspect ratio. HD has a 1080-pixel short edge; the 4K preset doubles both dimensions.
- Frame-rate changes keep clip IDs, source in-points, speed, linked A/V and shared cut boundaries. Cuts are aligned once to the destination grid; source-limited ends round down. Changes that would lose a clip or move a boundary by a full output frame are rejected atomically.
- Applying both values records one Undo step. Version 1 projects load as 16:9 and migrate in memory; new saves use version 2 so old apps reject unsupported canvas formats instead of silently rendering them as 16:9.

## Verified

`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --arch arm64`

96 tests passed: 90 FrameCore tests, including 9 new video settings tests, and 6 existing AppKit input tests. The new cases cover all 64 supported frame-rate pairs, exact shared cuts and A/V links, source duration limits, speed-changed clips, atomic rejection, Undo/Redo, save/reopen, version 1 migration, malformed formats and portrait transform geometry.

`FrameProbe video-settings TestArtifacts/fixtures TestArtifacts/video-settings`

The actual AVFoundation composition and exporter produced these MP4s, including video, linked audio and text. Every output passed checks for pixel dimensions, frame rate, duration, audio track start/end, PNG size and composed snapshot vs. encoded frame parity (mean normalized pixel difference < 0.0003).

| Ratio | Pixels | fps | Duration (s) |
| --- | --- | --- | --- |
| 16:9 | 1920 × 1080 | 23.976 | 1.084417 |
| 9:16 | 1080 × 1920 | 30 | 1.100000 |
| 1:1 | 1080 × 1080 | 24 | 1.083333 |
| 4:3 | 1440 × 1080 | 25 | 1.120000 |
| 4:5 | 1080 × 1350 | 50 | 1.100000 |
| 9:16 | 2160 × 3840 | 30 | 1.100000 |

Release app compiled for ARM64 and passed code-sign verification. In the running app, a copy of the user's 14-second project was changed from 16:9 / 60 fps to 9:16 / 30 fps using the sheet, producing a portrait canvas and updated timecodes. One Undo restored both values and the clean document state; Redo reapplied them. Save and a complete app restart preserved 9:16 / 30 fps and all four linked video/audio clips. Export settings displayed `HD · 1080 × 1920` and `30 fps`. The original document was kept unchanged.

## Limits

The frame-rate change resamples the timeline; it does not create interpolated motion or change source media. Cuts can shift by less than one destination frame. Very short clips or constrained source ranges may require a higher frame rate. Custom pixel dimensions and HDR output are outside this change. Audio stream timing was measured; subjective listening and long-project performance were not re-tested here. macOS 15 remains the deployment target; these checks ran on the available Apple Silicon Mac.

## Export integration — 2026-09-26

Moved aspect ratio and frame rate into the Export sheet alongside Resolution. Apply updates project settings without exporting; Choose destination applies them only after the save location is accepted. Draft changes and destination cancellation leave the project unchanged. Export settings remain accessible in an empty project, with movie output disabled until a clip exists.

ARM64 release build and signing passed. Native UI verification confirmed all three pickers, removal of the timeline gear, and changing the draft from 16:9 / 60 fps to 9:16 / 30 fps. Canceling the destination panel restored the clean 16:9 / 60 fps state. Repeating the selection and saving produced `TestArtifacts/export-settings/relocated-portrait.mp4`; independent ffprobe inspection reported H.264, 1080×1920, 30/1 fps, duration 0.500000 s and AAC starting at zero with the same duration. One Undo restored both project settings. A new empty project opened the sheet with Apply enabled and Choose destination disabled. The original user document remained unchanged.

This relocation was verified with the release build and native UI/output flow; the 96-test result above belongs to the preceding video settings implementation and was not rerun for this UI move.

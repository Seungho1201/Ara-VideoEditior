# Preview direct manipulation — 2026-09-22

Implemented native AppKit interaction over the AVPlayerView: double-click hit selection, light-blue source outline, corner handles, move, aspect-preserving resize with the opposite corner anchored, pinch and Option-scroll scaling, Escape, and grouped Undo/Redo. The top visible V2 layer takes precedence over V1. Playback clears the transform overlay. Source image/text extents and oriented video metadata define the bounds; renderer and editor share `VisualGeometry`.

Transform gestures update the edit model and replace the current item's video composition instructions without reconstructing media tracks. This uses Apple's paused-frame refresh behavior documented in [QA1966](https://developer.apple.com/library/archive/qa/qa1966/_index.html). [AVPlayerView frame analysis](https://developer.apple.com/documentation/avkit/avplayerview/allowsvideoframeanalysis) is disabled so Live Text does not intercept editing gestures.

Validation:

- ARM64 Release build and 28 automated tests passed. Six new tests cover landscape/portrait bounds, render/view coordinate agreement, rotated corner anchoring, limits, text/4K scaling, timing/audio preservation, Undo/Redo and persistence.
- `FrameProbe snapshot` passed: eight composed 1080p PNGs match MP4 output (mean normalized difference 0–0.00270), including overlap, rotation, effects, text, image, gap and final frame. Cancellation/failure preservation and a one-frame 29.97 project also passed.
- Native UI double-click displayed the outline and selected the correct clip at the playhead. A 45×28-point drag produced X=0.0917119565 and Y=0.1014492754 in the inspector and moved the rendered footage immediately.
- A corner drag reduced scale from 1 to 0.7855438008, with X/Y=-0.1072280996, keeping the opposite corner fixed. Saved JSON retained the values. One ⌘Z restored X/Y=0, scale=1; ⇧⌘Z restored the transformed values.
- Orca's synthetic drag command did not deliver the expected mouse drag; native CGEvent left-down/dragged/up events were used for the successful movement/resize checks. Pinch and Option-scroll were implemented but not exercised with a physical trackpad/mouse in this run.

Test evidence is in `TestArtifacts/preview-transform/`. A separate project copy was used; edits made by the user in that running copy were preserved rather than replaced with the older original document.

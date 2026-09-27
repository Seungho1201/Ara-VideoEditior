# Transition drag and drop — 2026-09-26

## Change

Transition cards now start an AppKit dragging session from either the picture or name,
with an eagerly populated transition pasteboard type. A plain click still applies to
the selected clip edge. Cancelling a drag does not invoke that click action.

The timeline resolves the nearest edge of the hovered clip, or an edge within 24 points
of empty track space. An existing transition is also a replacement target. The blue
highlight shows the fitted transition window. Hover and mouse-up both validate against
the current project; failed drops cannot report success or leave a stale highlight.

## Verification

- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --arch arm64`:
  **69 tests passed**, including three new drop-target/timing/history tests. All 11 kinds
  retain clip timing and survive undo, redo, and project serialization.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --arch arm64 --product Ara`:
  passed. `scripts/build-app.sh release` packaged and signed `build/Ara.app`;
  `file` reports an ARM64 Mach-O executable.
- Actual native mouse drags in the release app, using a separate copy of a 60 fps
  project with linked audio and two clips meeting at **00:00:07:44**:
  - Image drag adds Cross Dissolve at the cut.
  - Name drag replaces it with Dip to White while horizontally scrolled and zoomed;
    the transition ID and original one-second duration remain unchanged.
  - The blue target window and effect label appear while the mouse is held down.
  - ⌘Z restores Cross Dissolve; ⇧⌘Z restores the exact project after replacement.
  - Dropping in the first clip's body adds its start fade; dropping at the final edge
    adds Dip to Black as an end fade.
  - Drops onto audio and distant empty space leave the entire project unchanged,
    including when a video clip is selected for click-to-apply.
  - Escape during a valid drag cancels without applying or replacing a transition.
  - Scrubbing to 00:00:07:44 displays the white midpoint of Dip to White in the preview.
- Saved JSON was compared after each operation: video/audio clips, source ranges,
  start times, durations, and styles remained unchanged. The original project was
  backed up and not used for test edits.
- `git diff --check`: passed.

Orca's synthetic drag command did not deliver a usable drag. Native CGEvent mouse
sequences were used instead, with an Ara-frontmost guard; screenshots and saved project
data were checked after delivery. A successful tool response alone was not counted.

The renderer/export pipeline was not changed. MP4 export and every individual effect's
visual appearance were not re-tested in this drag-and-drop fix.

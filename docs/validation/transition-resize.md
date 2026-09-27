# Timeline transition duration handles — 2026-09-26

## Behaviour

- Drag either edge of a cut transition to resize it around the same cut. Odd frame
  lengths retain the extra frame after the cut.
- Fade-in uses its right handle, fade-out its left; the clip boundary stays fixed.
- The timeline previews the fitted length in seconds and frames. Mouse-up commits
  one undo step and rebuilds the preview; Escape discards the pending change.
- Lengths snap to project frames and, unless Shift is held, nearby clip/playhead
  boundaries. Limits are one frame, five seconds, clip length and neighbouring
  transitions. Source ranges, clip positions and linked audio timing never move.
- A project change during the gesture invalidates the pending resize.

## Checks

- ARM64 release build and signed `build/Ara.app`: passed; executable identified as
  an ARM64 Mach-O binary.
- `swift test --arch arm64`: **74 tests passed**, including five new tests for both
  handles, odd lengths at every supported frame rate, fixed fade boundaries, limits,
  returning from a clamped drag, one-step history and serialization.
- Release-app native mouse verification in a separate copy of the user's 60 fps
  project (cut at 00:00:07:44):
  - Right handle: 1.00 s → 2.00 s; live badge displayed `2.00 s · 120f`.
  - Left handle: 2.00 s → 1.50 s.
  - Each ⌘Z undid one whole gesture (1.50 → 2.00 → 1.00); ⇧⌘Z restored both.
  - Escape during an active resize left the saved project exactly unchanged.
  - Dragging beyond the maximum stopped at 5.00 s.
  - Fade-in right edge: 1.00 → 2.00 s; fade-out left edge: 1.00 → 1.50 s.
  - The inspector updated after mouse-up; the longer fade-in was visible in the
    preview at 00:00:01:01, inside its new two-second range.
- Saved JSON comparisons confirmed unchanged clips (including linked audio),
  source ranges, styles, transition identity/kind/direction and adjacent transitions.
- `git diff --check`: passed.

Native CGEvent mouse sequences were used with an Ara-frontmost guard because Orca's
synthetic drag could not reliably deliver the gesture. Screenshots, inspector values
and saved project data were checked, not just tool return codes. The original project
was saved/backed up before testing; test edits used separate temporary project files.

The MP4 renderer/export path was not changed or re-tested for this UI addition.

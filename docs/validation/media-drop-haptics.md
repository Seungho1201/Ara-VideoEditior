# Media-library drag haptics — 2026-09-27

Library-to-timeline drops now request AppKit feedback at valid track entry/change
(`generic`), alignment with an existing clip edge, playhead or timeline start
(`alignment`), and successful placement (`generic`). Holding at the same alignment
and free movement within a track are silent. Brief boundary re-entry jitter is
coalesced, and a new alignment takes priority over the lighter entry cue.

The existing Timeline → Trackpad Haptics preference controls these cues as well as
scrubbing. Shift bypasses media-drop snapping. Mouse-up resolves and validates the
current location again; missing media, incompatible/occupied tracks and exports
cannot produce a successful drop or completion cue. Cancellation clears the ghost
and feedback latch without modifying the project. External file import and
transition-card drag behavior are unchanged.

Verification:

- `swift test --arch arm64`: 108 tests passed (91 core, 17 AppKit/store).
- Five new tests exercise actual AppKit drag-destination methods using a hidden
  window and private pasteboard, capture haptic requests instead of vibrating the
  device, and verify entry/alignment/commit, stationary updates, exact-edge snapping,
  invalid/stale drops, disabled haptics, final release location, cancellation and
  the next drag session. Linked A/V placement and one-step Undo are also checked.
- ARM64 release build and strict app-bundle signature verification passed.
- Updated `build/Ara.app` launched with the user's saved project; the two linked
  clip pairs and 00:00:05:34 playhead were restored. The saved project SHA-256 is
  unchanged (`c51eff254c06e38aa696d252247bbb0aae9eb6b3e0d4146c3cf3f8bdc9258037`).
- Trackpad Haptics remains enabled. Physical tactile sensation has not been
  measured; request dispatch is verified by the isolated input tests above.

Logs: `/tmp/ara-media-drop-haptics-{tests,build,package}.log`.

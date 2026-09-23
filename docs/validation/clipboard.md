# Timeline clipboard validation — 2026-09-22

- ARM64 Release build and ad-hoc app bundle succeeded. `file` identifies Ara as an ARM64 Mach-O executable.
- `swift test --arch arm64`: 22 tests passed, including 8 new clipboard tests.
- Domain tests cover linked A/V identity and sync, source trim and style retention, standalone text/image/audio, deleted or relinked source references, atomic overlap rejection, all supported frame grids, clipboard validation, Undo/Redo, and project serialization.
- Native Ara UI: selected a linked video, pressed ⌘C, moved to its end, then pressed ⌘V. New V1/A1 clips both start at 00:00:39:17, with duration 00:00:39:17; total duration is 00:01:19:04.
- Saved JSON confirms fresh clip/link IDs, one reused media reference, and unchanged originals. ⌘Z removes the pair; ⇧⌘Z restores the exact saved model.
- A second paste at the occupied position shows the expected overlap alert.
- Playback composition rendered the copied footage. No new MP4 export validation was run for this clipboard-only change.
- Inspector text copy/paste follows the native responder chain in code. End-to-end text-field shortcut verification was not completed: automated inspector scrolling/focus was unreliable while the live UI state was changing.

The native UI test used `TestArtifacts/clipboard-validation/Clipboard-UI.framestudio`, a separate copy of the saved user project. `pasted.json`, `undone.json`, and `redone.json` retain the comparison states. The user's project in Downloads was reopened afterwards.

Behavior: paste on the copied lanes at the playhead; reject occupied ranges as one edit. Cross-project paste requires the same project frame rate. Copying clip data does not copy the underlying media files.

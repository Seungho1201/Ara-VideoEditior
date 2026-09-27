# Project setup — 2026-09-27

`Add Project…`, `New Project`, the editor's New button, and ⌘N open the same setup
sheet: name, Full HD/4K quality, aspect ratio, and frame rate. Create opens an empty
timeline. Cancel leaves the current project loaded. Existing project files/folders can
still be dropped onto the start screen; Open continues to open project files.

Output resolution is now stored in the project and used by Export. Existing documents
without this optional field default to Full HD. Quality changes participate in Undo/Redo.
A newly configured project is unsaved even when empty, so its name and settings remain
available through Back and are included in the save-on-close flow. Preview stays at FHD.

Verified:

- ARM64 release build and ad hoc signature verification passed.
- 103 automated tests passed (91 model tests, 12 AppKit/store tests), including setup
  cancellation, invalid settings, new project state, settings round-trip, legacy defaults,
  and output quality through Undo/Redo.
- In the running app, Add Project opened the setup sheet instead of a file picker.
  An all-whitespace name disabled Create; Cancel returned to the project list, and a
  subsequent setup began with fresh defaults.
- Created `Project Setup QA`: 4K, 9:16, 24 fps. The editor opened the empty portrait
  timeline with the chosen name. Starting another project showed the existing save-changes
  confirmation. The saved QA document contains `outputResolution: 2160`, `aspectRatio:
  "9:16"`, and `frameRate: {numerator: 24, denominator: 1}`.
- Reopened that file and checked Export: **4K · 2160 × 3840**, **9:16**, **24 fps**.
  The source `Skimming QA` and Downloads `Untitled` project files retained their hashes.
- `git diff --check` passed. No movie export was run for this setup UI change.

Local screenshots and logs: ignored `TestArtifacts/new-project/`. The GUI-saved file is
`TestArtifacts/export-settings/Project Setup QA.framestudio`.

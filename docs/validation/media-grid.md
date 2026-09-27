# Two-column media library and panel sizing — 2026-09-26

- Library uses two flexible LazyVGrid columns and 16:9 thumbnail frames. Names
  truncate in the middle and expose their full text through help. Metadata, selection,
  native thumbnail drag handles, append buttons and relink actions are retained.
  The library minimum width is 340 points so both columns remain readable.
- Initial column proportions match the user's 1440-point window: 496 / 613.5 / 328.5
  points excluding dividers. The upper region/timeline default to equal height.
- A non-interactive AppKit view locates each enclosing native split view, applies
  initial or saved proportions once, and saves subsequent divider changes. The native
  split view still owns dragging, accessibility and minimum-size constraints.

## Verified

- ARM64 release build and strict app signature verification passed.
- A separate temporary project referencing the existing video three times displayed
  two cards on the first row and one on the next. The second card's light-blue
  selection outline was verified in a screenshot. Appending it changed duration from
  `00:00:14:16` to `00:00:28:32`, and Undo restored the clean project and original duration.
- Initial native splitter values were exactly 496 / 613.5 / 367 (library, PROGRAM,
  upper-region height) at 1440 × 856. At a library width of 340, both columns still fit;
  thumbnails, metadata and append controls remained visible.
- Changed widths to 340 / 769.5 and upper height to 380. Preferences reflected the
  normalized proportions. A full quit/relaunch restored those values exactly.
- Reopened the original project and restored the requested 496 / 613.5 / 367 layout.
  Temporary project entry was removed from Ara's project list. The user's project
  SHA-256 remained `c51eff254c06e38aa696d252247bbb0aae9eb6b3e0d4146c3cf3f8bdc9258037`.
- This pass verified layout and append/Undo in the running app. Media rendering,
  export, thumbnail dragging and double-click append were not separately re-tested.
  No new automated tests were added for this layout change.

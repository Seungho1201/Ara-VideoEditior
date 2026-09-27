# PROGRAM panel spacing — 2026-09-26

- Removed the 330/320-point maximum widths of the library and inspector. The
  native split view can now give them the space released by narrowing PROGRAM.
- The fitted 16:9 preview has 50-point horizontal padding on each side. A tall,
  narrow PROGRAM panel reduces the picture proportionally; a wide panel can still
  have more padding when picture height is the limiting dimension.
- ARM64 release build and strict app signature verification passed. This changes
  layout only; media composition and export were not re-tested, and no tests were added.
- Live native splitters accepted widths of 370 for the library and 589 for PROGRAM
  through AXSetValue, with the values read back as verified. The inspector occupied
  about 480 points. These widths exceed both previous side-panel maximums.
- At a 367-point upper-panel height, the screenshot showed a roughly 489 × 275
  preview inside the 589-point PROGRAM panel: approximately 50 points on each side.
  The transform outline remained aligned and the transport controls stayed visible.
- The open project was backed up, saved (preserving the user's removed transition),
  and reopened in the updated app. The saved document SHA-256 stayed unchanged during
  layout verification: `c51eff254c06e38aa696d252247bbb0aae9eb6b3e0d4146c3cf3f8bdc9258037`.

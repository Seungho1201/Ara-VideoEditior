# Timeline skimming, end snapping and trackpad haptics — 2026-09-26

## Behaviour

- Press and drag the timeline ruler or empty track space to scrub. Releasing stops
  pointer-following; moving without pressing never seeks or requests haptics.
  Clicking still positions the playhead. Clip/transition drags retain their edit actions.
- Hover skimming, its toolbar/menu toggle and S shortcut have been removed at the
  user's request. Existing `timeline.skimming` preferences no longer affect input.
- The nearest clip end within five project frames captures the playhead from either
  direction. Distances are measured before frame rounding and do not depend on zoom.
  Linked video/audio ends are one target; ties between tracks choose the earlier end.
  This is the exclusive cut boundary, not the preceding clip's last displayed frame.
- A light-blue `CLIP END` marker makes the snap visible. Leaving the five-frame zone
  releases it immediately. Shift temporarily bypasses it; N disables snapping.
  Keyboard frame stepping and playback do not use this magnetic navigation.
- The timeline and preview accept physical N as a fallback when an input source
  does not produce the Latin menu shortcut. Text responders retain their keys.
- Trackpad Haptics uses AppKit's `generic` pattern for movement (at most once per
  80 ms), and `alignment` on entering a clip-end zone. The boundary cue has priority;
  holding on the same boundary is silent, and rapid re-entry jitter is suppressed.
  Feedback is requested immediately (`.now`), without waiting for a display update.
  There are no deferred haptic timers. Timeline → Trackpad Haptics disables feedback.
- The haptic preference is stored separately from the project.

## Current verification — drag-only input

- `swift test --arch arm64`: **87 tests passed** (81 model tests, six AppKit
  responder tests). The input tests verify hover on the ruler/clip/empty lane keeps
  position, even with the legacy hover preference enabled; ruler dragging and
  release; empty-track drag snapping and Shift bypass; interrupted scrub/clip drag
  recovery; and hover while playing or paused. The revised six tests failed against
  the preceding hover implementation, then passed after the change.
- Release `build/Ara.app` built for ARM64 and passed strict signature verification.
  The original project was reopened, and the removed hover toggle was confirmed in
  the native UI. The saved project SHA-256 remained unchanged.
- A native ruler drag reached `00:00:06:13`. The following live hover checks were
  inconclusive: other pointer input appeared to overlap, and observed positions did
  not match the injected coordinates. Automated input was stopped; the live user's
  unsaved edits were left open. Post-release position retention is verified by the
  isolated responder tests above, not claimed as a passing live UI check.
- Haptic patterns/cadence and the five-frame snap calculation are unchanged. Physical
  feedback was previously confirmed by the user; it was not re-assessed in this pass.

## Earlier verification — hover version, superseded by drag-only input

- ARM64 release build and ad-hoc signed `build/Ara.app`: passed.
- `swift test --arch arm64`: **85 tests passed** (81 model tests and four AppKit
  responder tests), including seven model tests covering
  all eight supported frame rates, inclusive five-frame limits, subframe distances,
  linked/multitrack ends, deterministic ties, gaps, bypass, edited ends, unchanged
  models, haptic cadence, boundary priority, re-entry suppression and disabled cues.
- Native UI checks used a separate copy of the user's 60 fps project, with a cut at
  `00:00:07:44`. Pointer movement without a mouse-down produced these timecodes:
  - 4 or 5 frames before / 4 frames after the cut → `00:00:07:44`.
  - 6 frames before → `00:00:07:38`; 6 frames after → `00:00:07:50`.
  - Shift at 4 frames before → `00:00:07:40`.
  - N off at 4 frames before → `00:00:07:40`; N on restored end snapping.
  - With S off, hover did not move the playhead. Ruler dragging still moved it.
  - At 64 points/second and 19.3684 points/second, the same 4-frame capture and
    6-frame release were observed; the latter zoom was set by dragging the slider.
  - During playback started at 2 seconds, hovering at the 7:44 cut left playback
    advancing normally (`00:00:02:20` observed), rather than seeking to the cut.
  - Right-arrow from the snapped cut advanced to `00:00:07:45` and removed the entire
    boundary label without leaving a stale drawing.
- The haptics menu was toggled off and its checkmark and stored preference read back.
  Both Skimming and Trackpad Haptics remained off after quitting/relaunching. Both
  were then enabled again and confirmed on in the original project in the final build.
- Saving the QA document left its complete model identical to the original except
  for the QA document name. The user's saved project remained byte-for-byte identical
  to the backup taken before testing. Undo remained unavailable throughout navigation.

Orca accessibility snapshots/screenshots verified visible values. Guarded native
CGEvent sequences supplied hover and drag events. Tool success without a matching UI
state was not treated as verification. The initial slider AX value write was rejected;
the zoom test instead used a native drag and the actual resulting slider value.

## Earlier follow-up: missing hover and physical feedback

- Both Ara preferences were enabled, but macOS Trackpad → Point & Click → Force
  Click and haptic feedback was off (`ActuateDetents = 0`). Enabling the switch was
  verified in System Settings and its stored value (`1`). The existing three-finger
  lookup gesture was restored after macOS changed it while enabling Force Click.
- Before the code change, button-free native mouse moves already changed the
  playhead to `00:00:03:06` and `00:00:06:13`; leaving the timeline and returning also
  worked. After the system setting was enabled, the user explicitly confirmed that
  both hover skimming and trackpad vibration worked on their hardware.
- A separate interrupted-drag bug was reproduced in hidden AppKit windows: losing
  `mouseUp` left the timeline in drag mode, blocked later hover, and a late `mouseUp`
  could commit a stale clip move. Two regression tests failed before the fix.
  A subsequent button-free `mouseMoved` now discards that unfinished gesture and
  resumes hover without changing the project. All four responder tests now pass,
  including ordinary hover and playback/disabled-skimming guards. These tests call
  the view's responder methods; they do not simulate an actual macOS window interruption.
- The feedback timing was changed to `.now` after the user's hardware confirmation.
  Relative pattern strength and the new dispatch timing have not been separately
  assessed by physical touch.
- The updated ARM64 release was built, signature-verified, and relaunched with the
  original project. Two click-free pointer moves again displayed `00:00:03:06` and
  `00:00:06:13`; Undo stayed disabled. The saved project SHA-256 was unchanged.

## Hardware limits

AppKit exposes semantic patterns, not adjustable haptic intensity. `alignment` is
the documented boundary pattern; `levelChange` denotes pressure zones and is not used
as an intensity substitute. The system can suppress haptics, including when no finger
is touching a compatible Force Touch trackpad. Physical sensation cannot be measured
through synthetic pointer input; the user confirmed that vibration works. Relative
strength between the patterns remains unverified.

References: [Apple haptic design guidance](https://developer.apple.com/design/human-interface-guidelines/playing-haptics)
and [Trackpad settings](https://support.apple.com/en-qa/guide/mac-help/mchlp1226/mac),
plus the current SDK's AppKit `NSHapticFeedback.h` (`NSHapticFeedbackPerformer`).
The media renderer/export pipeline was unchanged and was not re-tested for this feature.

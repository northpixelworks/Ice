# Changelog

All notable changes to Ice are tracked here retroactively from the available git history. Older entries summarize release themes rather than every small refactor.

## Unreleased

### macOS 27 compatibility
- Distinguish denied Accessibility access from unreadable menu bar snapshots. Show repair guidance for an already-enabled but ineffective Accessibility entry, open the relevant Settings pane, and recheck access/setup before refreshing.
- Bound Accessibility snapshots and child reads, reject stale visibility replies, and preserve discovered items after incomplete move verification.
- Show status-item apps launched while hiding is active without a manual toggle. The allowlist check now compares running applications instead of observed items (hidden items are never observed), and Ice watches the running-application list because macOS posts no launch notification for menu-bar-only apps. Ice reapplies 250 ms after that list changes; in a probe the list changed about 0.4 s after launch, so expect roughly a second, not yet measured on the live menu bar. Background-only helpers never reset the assertion, and neither do quits or relaunches of apps in the Visible section. Quitting or relaunching a Hidden or Always-Hidden app while its section is concealed still replaces the assertion, or releases it when nothing else is hidden.
- Make smart rehide work without Screen Recording. When window titles are unavailable, Ice identifies the clicked window by owner, layer and bounds and skips accessory overlays. With Screen Recording and readable titles, the original title-based check is unchanged.
- Refresh from MenuBarAgent notifications with a 20-second backstop, suspend during screen sleep/inactive sessions, and cancel verification on stop. Coalesce wake refreshes.
- Remove legacy pointer/cover polling on macOS 27, cache the auto-hide preference, and keep one cancellable hover delay. The menu bar manager refreshes its copy every 30 seconds; the menu bar frame used by pointer and scroll handling reuses one read for up to a second instead of copying the global defaults domain on every event. A pending show-on-click tolerates up to four points of pointer jitter, including a small drag while the button is held and scroll events; a drag further than that cancels it, and the click still runs only if the pointer is within four points when it fires. Any drag or scroll cancels a pending hover. Explain that hiding app menus is unavailable on macOS 27.
- Recover automatically from sustained MenuBarAgent hangs, using repeated Accessibility timeouts plus resource pressure, active-session guards, exact process identity checks, and a persisted 30-minute restart cooldown. Preserve saved layout assignments and keep local recovery diagnostics.
- Remove the Input Menu host from the app allowlist when Input Menu is hidden. Previously its system assignment conflicted with the host exemption, causing verification failures, all hidden icons to return, and repeated menu bar reflow.
- Keep Itsycal’s identity stable across daily date changes to prevent duplicate layout entries and stale drag targets.
- Add recognizable system symbols, installed-app icon fallbacks, and a Move to menu on each layout tile; label controls whose hiding is managed by macOS.
- Support automatic menu bar retraction without treating application toolbars or cached off-screen icons as menu-bar space. Retry stationary hover during slide-down, query occupancy on the pointed-at display, and defer hiding verification until a bar is presented. Keep failed geometry reads on the bounded unreadable-snapshot path rather than mistaking them for normal retraction.
- Prevent clicks on multi-icon apps such as Claude Usage from toggling Hidden items: confirm empty space using fresh raw Accessibility geometry, reject incomplete/stale reads, and cancel delayed actions after newer input or visibility changes.
- Integrate the official 0.11.13-dev.2 beta while preserving custom macOS 27, Portworth and auxiliary-item behavior; protect this build from automatic upstream replacement.
- Verify hiding from complete Accessibility snapshots, retain assertions through temporary unreadable states, reject stale callbacks and bound automatic retries. Treat transport, role and PID read failures as incomplete evidence.
- Start timed rehide when the pointer is away from the menu bar, including reveals triggered away from it; preserve Always-Hidden toggle settings and section hotkeys.
- Document and verify that Menu Bar Layout temporarily reveals all items; leaving the pane restores saved hiding assignments, including BetterTouchTool.
- Restore hiding for supported system controls such as Wi-Fi, add grouped hiding for User, and let cross-section drops assign visibility without requiring a physical menu bar move.
- Add an Accessibility-based menu bar editor with app-icon fallbacks, search, verified native reordering, and per-app section assignments on macOS 27.
- Route reveal/rehide through MenuBarClientCore; stop stretching obsolete divider windows. Document system-item and separate-bar limitations in [macOS 27 notes](docs/MACOS_27.md).
- Replace the incompatible CompactSlider dependency with native SwiftUI sliders.
- Fix capture-buffer lifetime, initial image-cache sizing, and scene-window ID validation; keep setup idempotent and avoid deactivation on last-window close on macOS 27.
- Fix Settings window presentation with scene-bound window actions and native foreground ordering; restore minimized windows and reopen Settings when Ice is opened from Finder.

### Audit fixes
- Keep auxiliary spacing fixed during a reveal so Portworth movement cannot grow the divider and push hidden icons out of view.
- Respect the auto-rehide toggle for focused-app changes, including while a delayed hide is pending.
- Prevent a canceled Ice Bar opening from reappearing after a close or display/space change.
- Reset cached auxiliary spacing when the divider moves to another display.
- Make verbose diagnostics opt-in with `ICE_DIAGNOSTICS=1` and skip message construction otherwise.

### Added
- Added focused geometry tests for auxiliary status item reservations across left-hand and vertically offset displays.
- Added a manual GitHub Actions workflow for building app artifacts.
- Added shared Codex and Claude agent guidance through `AGENTS.md`, `CLAUDE.md`, and `docs/AGENT_GUIDE.md`.
- Added discovery for visible auxiliary status-level windows that are not returned by macOS's private menu bar item list. This covers apps such as Portworth that draw their own menu bar presentation window.
- Added support for showing and rehiding hidden items when macOS is configured to automatically hide and show the menu bar.
- Added visual cover panels for auxiliary status-level windows while the system menu bar is retracted, so app-owned status windows do not linger on the desktop.

### Changed
- Keep local build products and installer backups in `.noindex` directories so development copies do not appear as extra Ice installations in Spotlight.
- Pin SwiftLint 0.65.1 in CI, use the same tool locally, and resolve strict lint violations in the merged sources while preserving checked Core Foundation bridges.
- The GitHub Actions app artifact workflow now also runs on pushes to `main`, keeping the artifact install fallback fresh after shipped changes.
- The app artifact workflow now uses current major versions of the GitHub checkout and artifact upload actions to avoid the Node 20 actions deprecation path.
- `build-and-install.sh` now falls back to the latest successful GitHub Actions app artifact when full local Xcode is unavailable, then still installs and re-signs the app with the stable local identity.
- Local development signing now trims the default login keychain path before importing the self-signed identity, so stable local signing works with `security default-keychain` output that includes leading whitespace.
- Local development signing now exports the temporary PKCS#12 with a non-empty local password, matching what macOS `security import` expects.
- Local development installs now create and reuse a stable self-signed `Ice Local Development` code-signing identity when possible, so Accessibility approval survives normal rebuild/reinstall cycles instead of changing with every ad-hoc build hash.
- Bundle-identified auxiliary status windows now follow a read-only overlay contract: Ice keeps discovering them as menu bar layout items and spacing obstacles, but no longer creates visual cover or centering panels for them because the owning app is responsible for visibility and alignment.
- Auxiliary status item covers now cache and refresh their images only when needed, reducing flicker and avoiding unnecessary screen captures during pointer movement.
- Auxiliary status item covers now redraw shorter top-pinned auxiliary windows centered in the visible menu bar while still passing mouse events through to the owning app.
- Hidden-section reveal now reserves space from auxiliary status item frames captured while the hidden section is hidden, preventing native hidden items from sliding underneath app-owned overlays.
- Hidden-section reveal now also merges in live on-screen auxiliary status item frames when computing its reservation, so app-owned overlays such as Portworth are protected even if the cached visible-section list is stale during the reveal.
- Hidden-section reveal now reserves across the full auxiliary overlay frame when the divider frame lands inside that overlay, preventing newly revealed native items from flickering behind narrow app-owned windows such as Portworth's dot.
- Hidden-section reveal now falls back to reserving the full auxiliary overlay width when the divider frame is temporarily unavailable or outside the overlay during the first reveal layout pass.
- Hidden-section reveal now keeps the last valid auxiliary spacer through transient layout passes and uses a direct WindowServer fallback for app-owned status-level windows, reducing Portworth overlap during the reveal animation.
- Hidden-section reveal now primes the auxiliary spacer while the section is hidden and keeps that spacer from shrinking until the section hides again, reducing flicker while native items animate into place beside Portworth.
- Hidden-section reveal now includes the auxiliary spacer's full first-pass clearance in the fallback reservation, reducing the final one-step settle when hidden items first appear beside Portworth.
- Auxiliary status item reservation now preserves every auxiliary frame instead of collapsing windows with the same simplified identity.
- Ice Bar and Menu Bar Layout render auxiliary status item captures with transparent horizontal padding trimmed, so wide transparent app-owned windows do not appear oddly offset inside Ice's UI.
- Hidden-section hide/show updates now use the hiding state currently being applied when computing divider visibility and auxiliary reservation length.
- Control items now reapply their current status item state after the menu bar section graph is initialized, so startup length and icon updates run with a valid owning section.

### Fixed
- Fixed auxiliary status item reservations mixing frames from different displays, which could create an oversized hidden-section spacer when an overlay such as Portworth was on a left-hand display.
- Fixed a recursive status item frame/length update loop that could crash Ice with a main-thread stack overflow.
- Fixed startup behavior where items assigned to the Hidden Section could still appear in the native menu bar because the hidden spacer length was not reapplied.
- Fixed hidden section hide transitions that could leave items visible after clicking Hide.
- Fixed visible auxiliary status item cover flicker while expanded sections are shown in automatically hidden menu bars.
- Fixed auto-hidden menu bars immediately rehiding after the Show All control is clicked while the pointer is still in the revealed menu-bar strip.
- Fixed auto-hidden menu bars immediately rehiding when the pointer is inside a revealed menu-bar window outside the static top-edge reveal strip.
- Fixed auto-hidden menu bar hit testing so visible status item windows keep expanded sections from rehiding during the system reveal animation.
- Fixed a no-item auxiliary cover retry loop that could churn while the menu bar was hidden.
- Fixed delayed auxiliary status item reveal with auto-hidden menu bars by falling back to the top-edge reveal band when the transient menu bar window frame does not yet contain the pointer.
- Fixed auxiliary cover panels drawing stale menu-bar surfaces during system auto-hide retraction by waiting for both the Window Server menu bar and Ice's hidden control item to report that the bar is fully hidden before capturing cover images.
- Fixed auxiliary status item reveal anchoring when hidden native items appear next to app-owned overlay windows.
- Fixed auxiliary status item cover flicker after wake, unlock, or menu bar reconstruction.
- Fixed auxiliary status item layout detection so visible app-owned status windows are classified in the Visible Section instead of being missed or placed in a hidden section.
- Fixed menu bar item movement, move timeouts, and display names on macOS 26 Tahoe.
- Fixed macOS 26 compatibility where status item ownership and menu bar window behavior changed.

### Documentation
- Added a root architecture guide for app startup, manager boundaries, permissions, private API touchpoints, and verification.
- Documented the control-item startup ordering and status item length requirements that keep hidden items offscreen.
- Documented auxiliary status item behavior, Portworth centering integration notes, auto-hidden menu bar limitations, and local install permission behavior in `FREQUENT_ISSUES.md`.
- Documented automatically hidden menu bar support and auxiliary status-level item behavior in `README.md`.

## 0.11.13-dev.2 - 2025-09-16

### Changed
- Updated issue templates.

## 0.11.13-dev.1 - 2025-06-20

### Added
- Added Homebrew cask installation instructions.
- Added a configurable behavior for right-clicking in the menu bar.

### Changed
- Updated project files for newer Xcode versions.
- Reworked menus, pickers, and related settings UI.
- Moved the updates interface into the About page.
- Made minor UI refinements.

## 0.11.12 - 2024-10-29

### Added
- Added optional screen-recording-permission behavior so Ice can work without Screen Recording in supported flows.
- Added a more complete screen recording permissions implementation.

### Changed
- Improved modifier flag handling.
- Updated group box and related interface details.

### Fixed
- Fixed missing items from hidden sections.

## 0.11.11 - 2024-10-19

### Changed
- Updated the menu bar search panel and full-screen behavior.
- Adjusted isolation and search panel window style handling.

### Fixed
- Reverted an accessibility-title change that caused regressions in the search panel.

## 0.11.10 - 2024-10-14

### Added
- Added dynamic menu bar appearance support.
- Added live preview for dynamic menu bar appearance changes.

### Changed
- Reworked appearance editor UI and menu bar shape edge insets.
- Reworked object association storage into `ObjectStorage`.
- Refactored menu bar item info and related internals.
- Improved movement timing by waiting for mouse motion to settle.

## 0.11.9 - 2024-10-08

### Added
- Added a small delay before moving menu bar items.

### Changed
- Reworked item caching and temporarily shown item handling.
- Updated menu bar item cache when running applications change.
- Opened the settings window when checking for updates.

## 0.11.8.1 - 2024-10-05

### Added
- Added a setting to show all sections while dragging menu bar items.

### Changed
- Reworked cursor location handling.

### Fixed
- Fixed smart rehide behavior on macOS Sequoia.
- Removed a legacy inset option that should not have shipped.

## 0.11.8 - 2024-10-04

### Changed
- Reworked item clicking and application menu overlap handling.
- Improved behavior for long application menus while temporarily showing items.
- Removed 1px padding around menu bar shapes.
- Updated advanced settings and sidebar sizing.

## 0.11.7 - 2024-10-02

### Added
- Added update notifications.

### Changed
- Updated Ice Bar corner rounding.

## 0.11.6 - 2024-09-30

### Changed
- Maintenance release with version/build updates from the 0.11 line.

## 0.11.0 - 2024-09-15

### Changed
- Major 0.11 release line with menu bar management, appearance, search, and settings improvements accumulated through the beta cycle.

## 0.10.x - 2024-06-13 to 2024-08-16

### Changed
- 0.10 release line covering the previous generation of menu bar item management, appearance, and reliability improvements before the 0.11 beta series.

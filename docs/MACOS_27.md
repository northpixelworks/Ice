# macOS 27 compatibility

## MenuBarAgent hang recovery — 2026-09-26

Build `0.11.13-dev.2-macos27.4` adds automatic recovery for the observed
MenuBarAgent hang (unresponsive AX root, approximately 129% CPU and 5.2 GB
footprint). Restarting that service restored the existing Ice layout; the
initial trigger is unknown. This mitigates recurrence, not the underlying
macOS defect.

While the session is unlocked and active, a separate bounded AX probe runs
every 10 seconds. Recovery requires repeated root transport timeouts and at
least 30 seconds of sustained CPU use of 80% of one core or resident memory
of 1 GiB. Responsive high-resource processes, ordinary visibility verification
failures, and normal retracted menu bars do not trigger recovery. Lock/sleep,
missing Accessibility permission, layout editing, process replacement and
long observation gaps discard accumulated evidence. A 30-second grace period
follows startup and wake/unlock.

Only the current user's process at Apple's exact MenuBarAgent executable path
can receive SIGTERM, with PID and kernel start time rechecked after the asynchronous
probe. launchd replaces it; Ice's existing refresh restores/verifies hiding.
An attempted restart records `ModernMenuBarLastRecovery` before signalling,
limiting recovery to once per 30 minutes even across Ice relaunches. No force
kill or repeated escalation is used. Local `MenuBarRecovery` logs record
watchdog startup and recovery attempts. Saved layout assignments are unchanged.

Validation: 63 native XCTest cases, 19 standalone visibility/layout/geometry
checks, strict SwiftLint 0.65.1 across all 117 app files, and the universal
Release build passed. The local test host needed re-signing without hardened
runtime to load its test dylib, matching the existing local development setup.
The installed app uses the existing signing identity and passes strict recursive
signature verification. Startup logs confirm the watchdog is enabled, General
reports active hiding, and the saved layout hash is unchanged. The previous app
is retained at `/Applications/Ice-backups.noindex/Ice-20260926-before-watchdog.app`.
No artificial system hang or physical lock/unlock cycle was induced for testing;
the automatic trigger is covered by policy tests and normal live monitoring.

## Why the old layout pane was empty

On macOS 27.0 (26A428), Ice logged `Missing control item for hidden section` and cleared its entire item cache. MenuBarAgent now composites status items: the old `CGSGetProcessMenuBarWindowList` path does not supply the individual item windows Ice needs. The running app had Accessibility and Screen Recording permission, so resetting those permissions would not repair this discovery path.

## New backend

`AppState.modernMenuBarManager` owns the macOS 27 path. macOS 14–26 use the upstream 0.11.13-dev.2 implementation, including its menu bar item service on macOS 26.

- `ModernItemEnumerator` walks MenuBarAgent's Accessibility tree off the main actor, with bounded messaging timeouts, resolves app identities, and deduplicates display instances.
- The new layout editor displays application icons and names without requiring Screen Recording. Search filters the editor. It never fabricates CGWindowIDs for scene-based items.
- Dragging onto another item resolves fresh, on-screen frames, performs a native Command-drag, and checks the resulting relative order. macOS persists the physical order. A rejected or off-screen move is reported instead of silently treated as success.
- Dropping into a section changes the app's assignment. Third-party hiding is per application, so all of an app's status items share one section. Supported core system controls use separate `system:<raw identifier>` assignment keys; existing app assignments still decode unchanged. Assignments are stored separately under `Defaults.Key.modernMenuBarLayout`; existing settings are not overwritten.
- Opening the editor temporarily reveals items; leaving it restores concealment. Ice's section actions and rehide timers use the new backend.
- Section assignments save immediately, but the menu bar continues showing all items while Menu Bar Layout is open. Switch to General or Menu Bar Appearance, or close Settings, to see the saved hiding behavior. Returning to Menu Bar Layout reveals items again without changing any assignments.
- Concealment uses a process-bound MenuBarClientCore assertion. A missing completion callback alone no longer releases the assertion. Ice verifies a complete, nonempty Accessibility snapshot, keeps an unverified assertion when reads are temporarily unavailable, and retries confirmed failures with bounded backoff. Quitting Ice releases it. The allowlist includes other running applications. Anything unlisted is hidden and never appears in the Accessibility snapshot, so Ice decides from the running-application list, not observed items: when an application that can own a status item (not background-only) starts and is missing from the active allowlist, Ice reactivates the assertion after a 250 ms debounce. It observes `NSWorkspace.runningApplications` because macOS posts no launch notification for menu-bar-only (LSUIElement) apps. For apps in the Visible section, quitting never reactivates, and bundles allowed earlier stay allowed while their section is visible, so relaunches do not either. Hidden and Always-Hidden apps are part of the plan itself while their section is concealed: quitting or relaunching one replaces the assertion, and when nothing else is hidden after a quit, the assertion is released. An app that starts background-only and later becomes an accessory app waits for the 20-second refresh, which is the backstop. Keeping a quit app's bundle in the allowlist assumes MenuBarClientCore matches bundle identifiers whenever a status item appears, not only the processes running at activation; this has not been verified on the live menu bar.
- Scene dividers no longer expand to enormous widths. Search opens the new searchable editor. On macOS 27 the old separate Ice Bar falls back to the system menu bar, and the ineffective legacy spacing/relaunch control is not offered.

## Current limits

Input Menu requires excluding both the keyboard system identifier and its separate `com.apple.TextInputMenuAgent` host from the assertion allowlists. On 27.0 (26A428), allowing the host overrides the system-only hiding request. The September 24 repair keeps both lists consistent and restores the host when Input Menu is revealed. Before this repair, verification repeatedly found that single 35-point item, released the assertion, and brought every hidden item back. Accessibility reapproval alone did not resolve it.

Automatic menu bar hiding remains enabled during normal use and section assignment. Pointer checks use the live menu bar height, or only the one-pixel reveal edge while retracted, including fullscreen presentation. Stationary hover retries fresh geometry for up to 1.5 seconds after the configured delay, so slide-down does not require another pointer movement. Clicks are not retried. Occupancy is read on the display containing the pointer; stale editor frames cannot extend the interactive region into application toolbars. Concealment assertions are retained while all menu bars are retracted, and verification resumes from presented display observations on the next refresh. Physical reordering still requires visible endpoints.

- Tiles show application icons, not live captures of each status-item glyph.
- Move endpoints must be visible in the same menu bar. Expand macOS's overflow area before moving an off-screen item. Additional displays have not been manually verified.
- Wi-Fi, Battery, Sound, Bluetooth, Display, Input Menu, Clock and Screen Mirroring use individual system allowlist entries. SystemUIServer extras hide together by bundle. Control Center itself and helper overlays without a bundle identity cannot be hidden.
- User can be assigned to a hidden section, but it hides together with optional Control Center extras (including AirDrop and Focus). macOS also removes this group whenever any other hiding assertion is active, even if User is assigned Visible. Reveal all sections to restore the group. The User-only assignment activates an assertion with all supported core controls allowed.
- The assessment mechanism can also prevent clicking the clock from opening Notification Center while concealment is active. Reveal all sections first if affected; this backend does not yet provide a clock-click workaround.
- The original divider-based section assignments cannot be inferred reliably once macOS stops exposing those windows. Choose sections in the new editor; the old preferences remain intact for older macOS versions.
- The private concealment API can change between macOS releases. Availability and selector checks must remain in the Objective-C shim.

## Other fixes in this change

- Replace CompactSlider 1.x with native SwiftUI sliders; the dependency's `opacity` call is ambiguous in the macOS 27 SDK. Preserve continuous and stepped values and their labels.
- Avoid explicitly deactivating Ice when its last window closes on macOS 27.
- Capture window actions from live SwiftUI scenes. Settings commands reuse and raise the existing window, restore it when minimized, and request the active Space; reopening Ice from Finder opens Settings. macOS 27 activation no longer uses the legacy Dock hop.
- Make AppState setup idempotent.
- Validate NSWindow IDs against actual CoreGraphics windows, since a scene identifier can fit in UInt32 without being a CGWindowID. Use the primary display origin for AppKit-to-CoreGraphics conversion.
- Release the temporary capture-window buffer, reject empty captures, and publish legacy image scale metadata before publishing images.
- Use the actual Screen Recording preflight check on macOS 27; individual window titles no longer indicate that permission.
- Smart rehide works in limited mode. Other apps' window titles need Screen Recording, so without it Ice picks the frontmost window under the pointer whose owner is a regular app (or the Dock), skipping accessory overlays, and rehides when that app is active. With Screen Recording and titled windows present, the original title-based check is used.

## Verification

Build and the 17-test macOS suite passed locally with Xcode's macOS 27 SDK on 2026-09-15. Five tests cover new-app defaults, independent hidden/always-hidden reveal behavior, app identity across changing status titles, saved-layout round trips, and invalid saved sections. Five additional tests cover independent system assignments, persistence/reveal, User-only assertions, collateral User visibility, and backward compatibility. The seven existing auxiliary reservation tests also pass.

Commands (full Xcode required):

```sh
xcodebuild -project Ice.xcodeproj -scheme Ice -configuration Debug CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Ice.xcodeproj -scheme Ice -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO test
```

The developer installation on this Mac has pending setup/license and CoreDevice/CoreSimulator warnings. Calling Xcode's own `Contents/Developer/usr/bin/xcodebuild` directly completed these macOS builds/tests; no license was accepted or system developer configuration changed.

Live verification on this Mac confirmed that the new editor discovers and displays the installed menu bar applications. After the window fix, reopening Ice from Finder brought Settings to the front after both closing and minimizing it. The missing-permission launch also displayed the Permissions window. The window fix builds successfully; switching Spaces and the menu command itself have not been independently exercised.

The system-item update passed all 17 tests and was installed on 2026-09-15. After removing the stale Accessibility entry and adding `/Applications/Ice.app` again, Ice reported permission granted. Its granted-Accessibility / absent-Screen-Recording launch populated the editor. Both Wi-Fi and User were assigned Hidden through their context menus; MenuBarAgent AX confirmed that both disappeared after leaving the editor, while Battery, Clock and Control Center remained. Reopening the editor restored Wi-Fi and User. Both assignments are left in Hidden.

The September 15 rollback builds were archived as verified ZIPs under `archived-installs.noindex/` during the September 22 duplicate-install cleanup. Local ad-hoc rebuilds can require macOS to reapprove Accessibility; the latest installation has Accessibility restored. Screen Recording restoration requires a macOS Touch ID prompt. Remaining runtime verification includes a physical move and reverse move, search, and additional displays. Do not infer runtime success from compilation or unit tests.

## Follow-up verification — 2026-09-16

BetterTouchTool's Hidden assignment was confirmed in the running editor and saved preferences. Switching from Menu Bar Layout to General activated the visibility assertion successfully; after the menu bar settled, BetterTouchTool disappeared from MenuBarAgent's Accessibility tree. Returning to Menu Bar Layout revealed it again while its assignment remained Hidden. No code or assignments were changed during this investigation.

Before shipping, the Debug build and all 17 macOS tests passed again using Xcode's own `xcodebuild` with `-destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build test`. The existing CoreDevice/CoreSimulator environment warnings did not prevent the macOS build or test run. SwiftLint was not installed locally, so local lint verification was unavailable.

## Second-Mac verification — 2026-09-16

Pulled `f860519` into the clean checkout on the second Mac (macOS 27.0, build `26A428`). The compatibility files are present in that commit. Added a prominent editor notice explaining that assignments save immediately, switching to General or closing Settings restores saved hiding behavior, and reopening the editor temporarily reveals all sections again.

Full Xcode is absent on this Mac. The normal `xcodebuild` build/test commands cannot run. GitHub Actions run [35138416970](https://github.com/mariowabnig/Ice/actions/runs/35138416970) successfully built the exact commit. A local arm64 executable including the notice was then compiled and linked with Command Line Tools Swift 6.4, the installed macOS 26.5 SDK, and the pinned cached dependencies. Only two design-time `#Preview` registrations were omitted in temporary source copies because CLT lacks Xcode's preview plugin; runtime source was retained. Build commands and logs are under `build/macos27-local/`.

All 17 existing model/geometry test bodies passed in a standalone Swift assertion harness against unchanged production model sources. This is not an XCTest run: CLT also lacks the XCTest module. The complete Xcode-hosted suite still needs full Xcode.

The original installed app and exported preferences are backed up under `build/backups/2026-09-16-before-macos27/`. The local executable was packaged with resources from the exact-commit CI artifact and signed with the existing Ice Local Development identity. Its designated requirement matches the previous app, and strict recursive signature verification passed. Existing Accessibility and Screen Recording permissions remained granted; no permission reset or user approval prompt was needed.

Live checks confirmed that the installed editor discovers third-party applications and system controls, that the new notice renders correctly, and that the search field filters items. BetterTouchTool is not installed/running on this Mac and produced no search matches, so its specific Hidden assignment cannot be verified here.

To test concealment without changing another application's settings, created a temporary native status-item app (`local.ice.compatibility-check`, label `Ice QA`). The installed Ice app discovered it, and its context menu assigned it to Hidden. Reading saved preferences confirmed immediate persistence while MenuBarAgent's Accessibility tree still contained the item with the editor open. Switching to General removed it from that tree while Wi-Fi, Control Center and Itsycal remained. Returning to the editor revealed it with the Hidden assignment unchanged. Closing Settings concealed it; reopening Ice from Finder restored Settings and revealed it. Reopening minimized Settings also worked. The fixture was quit and its test-only assignment removed afterward.

The installed app is running the local build with the notice. User settings were preserved: icon/appearance data differed only in JSON serialization order, and window geometry updated normally. No user item assignments were changed. BetterTouchTool itself, physical drag/reverse-drag, section toggling through the menu bar/hotkeys, additional displays, and missing-permission startup have not been exercised on this second Mac. The existing reorder success check only verifies source-before-target; it can miss a rejected move if that relative order already held before dragging.

## Source attribution

The bounded AX enumerator, system identifier mappings and Objective-C MenuBarClientCore shim are adapted from [fif7y/Pelmet](https://github.com/fif7y/pelmet), revision `76db5715991a82e4583f93c360fba9807750d040`, licensed under GNU GPL v3. Ice is also GPL v3. The copied portions retain their original descriptive comments, with type/function names and logging adapted to Ice. The original GPL license is retained in `docs/licenses/Pelmet-GPL-3.0.txt`. The manager, editor, persistence model, and integration are specific to this fork.

Thaw's macOS 27 release notes were useful context, but the inspected public Thaw tag did not contain the advertised new backend; it was not used as the basis for this implementation.

## Beta integration and hiding repair — 2026-09-22

The official `0.11.13-dev.2` beta is integrated with this fork's macOS 27 backend, auxiliary overlay discovery/capture, reservation geometry, and settings behavior. The custom build is labelled `0.11.13-dev.2-macos27.1` (build `2026092201`). Sparkle does not start for a custom build; About and Check for Updates open this fork's update page so public releases cannot silently replace its additions.

Hiding now uses generation-scoped verification instead of treating a missing private-API callback as failure. Late callbacks cannot affect newer plans; automatic retries retain attempt history and stop after three retries. General shows the current state and a Retry hiding action. Timed rehide starts when the pointer leaves the live menu bar/reveal strip (or immediately when revealed while the pointer is already away), and delayed work rechecks the user's preference.

`build-and-install.sh` signs nested beta services before the containing app, verifies the signature recursively, and preserves the previous app. For staging without stopping or opening the running app, set `ICE_INSTALL_APP_PATH`, `ICE_INSTALL_NO_STOP=1`, and `ICE_INSTALL_NO_LAUNCH=1`; `ICE_INSTALL_SOURCE` may specify an already-built app. A failure to reuse an existing signing identity stops installation instead of silently changing its permission identity.

Final validation on 2026-09-22: Debug and Release builds and `build-for-testing` pass. The safe `scripts/run-modern-visibility-standalone-tests.sh` harness passes 12 grouped behavior checks against production sources; it does not launch the app or alter preferences. Hosted XCTest was compiled but not executed during this repair. SwiftLint remains unavailable, and the Xcode installation prints CoreDevice/CoreSimulator warnings.

Live installation reused the existing Ice Local Development certificate and preserved the designated requirement and all nine saved application assignments. General reports active hiding; MenuBarAgent no longer exposes Pure Paste while concealed. Opening Menu Bar Layout restores it and displays the running Always-Hidden apps, and leaving the editor conceals it again. The user's AutoRehide setting is enabled with Timed strategy and 15 seconds. The final ControlItem port keeps legacy dividers at zero width on macOS 27 and decouples section hotkeys from legacy divider visibility. Native menu-button/Carbon-shortcut automation has hosted-coordinate limitations in the current UI driver; do not infer physical shortcut or exact pointer-timing verification from the unit/build results. Additional displays and actual sleep/wake were not exercised.

The pre-ship adversarial review hardened Accessibility error handling: failed
transport, role and process reads cannot establish that an item was hidden.
Absent optional attributes remain acceptable. The lifecycle owns the only
verification generation counter. The standalone production-code harness now
covers 15 scenarios, including AX error classification and partial snapshots.


## Status-item click hit testing — 2026-09-22

The custom build `0.11.13-dev.2-macos27.2` (build `2026092202`) includes the
current beta and this fork's visibility fixes. Its empty-space click, context-menu
and hover decisions no longer use the layout editor's cached, deduplicated frames.
One app may own several status controls, and every raw frame must block an
empty-space action. Unknown groups, Ice itself and the overflow control count.

A separate actor reads current MenuBarAgent geometry with a 0.4-second total
deadline and bounded AX messages. Missing or invalid geometry, pointer movement,
newer input and visibility-generation changes prevent the action. Application
menus and the notch remain excluded. The original behavior remains on macOS 14–26.
The tracker's own variable-width indicators can still resize when fresh values
arrive; this repair targets Ice's unintended hide/reveal actions.

Local installer builds now use `build.noindex/`; previous installations go into
`Ice-backups.noindex/` beside the installation destination. On the development
Mac, nine obsolete loose bundles were replaced by extraction-verified ZIPs in
`archived-installs.noindex/`. Current development products were moved under
`build.noindex/`. Only `/Applications/Ice.app` is intended for normal launching.


Validation: all 44 native Debug XCTest cases, the 15-check standalone harness,
strict SwiftLint0.65.1, and the universal Release build pass. The installed
bundle passes recursive signature verification. Removing/re-adding its
Accessibility entry restored the grant. Live editor-to-General transitions
revealed then concealed BetterTouchTool and Wi-Fi. The beta still reports
active-but-unverified hiding after an incomplete discovery snapshot; the native
UI driver also cannot synthesize physical clicks on macOS 27's composited menu
bar. Physical tracker-click and additional-display validation remain incomplete.

## Automatic menu bar hiding follow-up — 2026-09-22

Build `0.11.13-dev.2-macos27.3` (`2026092203`) includes the retraction geometry,
stationary-hover retry and presented-display verification changes described
above. Debug build-for-testing, all 50 native XCTest cases, all 17 standalone
checks and the universal Release build pass. The unsigned XCTest host stalled
in dyld before tests began; signing the built Debug bundle with the existing
Ice Local Development identity allowed test-without-building to pass.

Installed `/Applications/Ice.app` passes strict recursive signature verification.
The stale Accessibility approval was removed using `tccutil reset Accessibility
com.jordanbaird.Ice`, and the exact installed app was re-added through System
Settings. The settings toggle was verified on; restarting Ice opened General
and reported active hiding. The nine saved assignments and automatic menu-bar
hiding preference are intact. Live physical hover/retract, fullscreen and
second-display interactions remain unverified by the native UI driver.

The follow-up adversarial review distinguishes positively observed retraction
from missing/invalid AX frames and failed display enumeration. Unknown geometry
uses the normal bounded unreadable-snapshot retries; it cannot silently pause
verification forever as though the user had hidden the menu bar.

### Layout editor identity and icons

Itsycal uses a stable single-item identity so daily date changes do not accumulate stale tiles or break drag lookup. System controls use named, colored symbols; app icons fall back to the installed bundle. Each tile exposes a Move to menu for section assignment, and unsupported items are labeled Managed by macOS.

### Input Menu allowlist repair — 2026-09-24

The installed universal app initially matched both Mach-O UUIDs of the successful GitHub artifact for `mariowabnig/Ice` commit `b688916` (run `36010740216`). Removed the existing Accessibility registration and re-added `/Applications/Ice.app`; the fresh launch passed all permission checks, but hiding still failed. Added `ModernVisibility` unified logging, which isolated `com.apple.TextInputMenuAgent::Item-0` as the remaining visible item at `(1474.5, 0, 35, 30)` after all other requested items were hidden.

Excluding that host when keyboard is concealed resolved the live failure. Release build and all 19 standalone visibility/layout/geometry checks passed, including host exclusion and restoration. The installed local repair is signed with the existing Ice Local Development identity and passes strict recursive signature verification. Three reveal/hide cycles (including closing the layout editor), sustained hiding, and a clean restart confirmed concealed items absent from the MenuBarAgent tree and `confirmedHidden` in runtime logs. All 15 saved assignments were preserved. The follow-up review passed all 52 native XCTest cases, including Hidden/Always Hidden reveal-state coverage, and strict SwiftLint 0.65.1. Diagnostic identifiers and verification results use private logging; the captured machine log stays local. The pre-repair GitHub build remains at `/Applications/Ice-backups.noindex/Ice-20260924-210248.app`.

For the Portworth check, temporarily changed macOS menu bar auto-hide from Always to Never. Portworth restored native rendering; its green dot returned to the same settled position after an additional Ice reveal/conceal cycle. Restored Always and verified the setting in System Settings. Direct pointer-driven auto-hide interaction remains unverified because the native UI driver cannot target the composited MenuBarAgent window. No Portworth code or preferences were changed.

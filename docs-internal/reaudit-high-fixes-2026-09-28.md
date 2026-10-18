# Ice re-audit High fixes — 2026-09-28

Scope: the two High findings for Ice in the workspace-level re-audit (`Coding/docs-internal/reaudit-2026-09-27/findings.md`, outside this repository), plus the Low finding that the 2026-09-26 report, CHANGELOG and docs overstated C2/C3/C4/C5/C7. Local commits only; nothing pushed, installed, or restarted.

## 1. C7 regression: apps launched while hiding is active stayed hidden

**Root cause (re-verified at `2d55998`).** The assertion is an allowlist: anything not listed is hidden. `applyVisibility` skipped reactivation when `allowed ∩ bundles(items) == applied ∩ bundles(items)`. `items` only contains observed status items, and an app launched after activation is hidden by the assertion, so it is never observed. Both sides of the check stayed equal forever.

A second, independent gap: the only launch trigger was `NSWorkspace.didLaunchApplicationNotification`. A scratch probe on this Mac (macOS 27.0, 26A428) showed that macOS posts **no** launch or termination notification for an LSUIElement app, which most status-item apps are. Only KVO on `NSWorkspace.runningApplications` fired (about 0.4 s after `openApplication`, on the main thread). So even a correct gate would have waited for the 20-second backstop.

**Fix.**

- `ModernAllowlistReapply.missingBundles` (in `ModernSystemItem.swift`): reapply when a running bundle that can own a status item (activation policy not `.prohibited`) is allowed by the plan but missing from the active assertion. Terminations never reapply.
- `ModernAllowlistReapply.candidateBundles`: bundles an assertion allowed earlier stay in later allowlists while their saved section is visible, so quitting and relaunching an app in the Visible section (or an accessory helper such as WebKit processes) does not reactivate the assertion. A helper bundle that is not background-only still reapplies once, at its first launch in the session. Reassigning such an app to Hidden removes it at the next assertion. **Correction (review follow-up):** this holds for Visible apps only. Hidden and Always-Hidden apps are part of the plan while their section is concealed, so quitting or relaunching one replaces the assertion, or releases it when nothing else is hidden (pinned by `testQuitAndRelaunchReactivateOnlyForConcealedApps`). Keeping a quit app's bundle allowed assumes MenuBarClientCore matches bundle identifiers whenever a status item appears; that is unverified live (manual check 2).
- `ModernMenuBarManager` observes the running-application list (debounced 250 ms) and calls `applyVisibility` directly, without waiting for an AX snapshot, then requests a refresh for discovery. Suspended managers ignore it; during a move it defers to the post-move refresh.
- `ModernMenuBarEnvironment` injects running applications, the layout store, and the assertion API. The live environment is unchanged behavior; tests use a fake so they neither read the saved layout nor create real assertions. The three existing manager tests now use the fake too (previously they could activate a real assertion from the test host if the saved layout had hidden items). Verification and retry snapshots now go through the same snapshot source as refresh.
- Debug logging: `[Ice ModernMenuBar] reapplying allowlist for N newly running application(s)` (NSLog) plus the bundle list at `info` level with private redaction; the activation line now includes `allowedApps=`.

**Tests.**

- `ModernVisibilityLifecycleTests.testAppLaunchedWhileHidingIsActiveBecomesVisiblePromptly` — manager-level, fake workspace/assertion API: activates hiding, launches an app absent from every snapshot, asserts a new assertion that allows it within 1 s, and the previous assertion released. Then asserts no reactivation for a background-only helper launch, or for a quit, a relaunch, or a relaunch after a reveal/conceal cycle of that Visible app, and that an app reassigned to Hidden is dropped from the next allowlist. The 1 s bound is fake-workspace timing (250 ms debounce, no real launch latency).
- Pure tests: `testNewStatusItemAppMissingFromSnapshotRequiresReapply`, `testTerminationRelaunchAndBackgroundHelpersDoNotRequireReapply`, `testConcealedLaunchIsLeftToThePlan`, `testPreviouslyAllowedBundlesStayAllowedUntilConcealed`, plus one standalone script check.
- Fails without the fix: restoring the old intersection gate made the manager test fail at 1.25 s (reapply never happened). Keeping the new gate but removing the running-application observer also failed ("A new status-item app must be allowed without a manual toggle").

## 2. Smart rehide never fired without Screen Recording

**Root cause (re-verified).** `handleSmartRehide` picked the first on-screen window under the pointer with a non-empty `kCGWindowName`. Without Screen Recording, other apps' names are nil. A probe on this Mac (preflight false) found no titled layer-0 window from any other app; the only titled windows were the Window Server menu bar strip (layer 24) and a WindowManager desktop-level window. So the lookup always failed and limited mode never rehid.

**Fix.** `Ice/Events/SmartRehidePolicy.swift` holds the decision:

- `titlesAvailable` requires both `ScreenCapture.checkPermissions()` and evidence: another process's normal-level (layer 0) window reporting a title. The WindowManager/Window Server titles seen without permission do not count.
- With titles: the original rule (first titled window under the pointer; owner must be active and regular; Dock excepted).
- Without titles: the first window under the pointer (below cursor level) whose owner is a regular app or the Dock, skipping accessory/background processes, which own nearly all overlays. It rehides when that app is active (or it is the Dock). Clicking the desktop resolves to Finder's desktop window.
- Debug logging: `[Ice SmartRehide] titlesAvailable=… layer=… policy=… active=… dock=… rehide=…` (no bundle IDs), and a line when no window is found.

**Tests.** `IceTests/SmartRehidePolicyTests.swift` (9 tests): title detection with and without permission/evidence; titled path skips untitled overlays, rejects inactive targets and ownerless windows; untitled path rehides for an active app, the desktop (Finder), and the Dock; does not rehide for an inactive target or when an accessory panel took focus; ignores cursor-level and Window Server windows. Forcing the title-only rule made the three positive untitled tests fail.

**Known difference.** Without titles, a click on a non-activating accessory panel (for example a launcher) floating over the active regular app now rehides, because the panel is skipped and the active app below is found. With titles it does not.

## 3. Documentation corrections

- `code-review-fixes-2026-09-26.md`: C2 (auto-hide preference still read per call in `NSScreen.appKitMenuBarFrame`), C3 (no manager-level plan-change/settle-window test), C4 (no `move()` test), C5 (drag and scroll still cancel pending clicks), C7 (the shipped gate was wrong; fixed here), and the test paragraph (only the two C6 tests were shown to fail first; the C3 stale-reply test passed on pre-fix code; the generation, settle-window, and merged-discovery tests predate the work).
- `CHANGELOG.md`: replaced "avoid unrelated application assertion resets" with the actual launch behavior, added the smart-rehide entry, and listed the C2/C5 gaps.
- `docs/MACOS_27.md`: describes the running-application gate and the limited-mode smart rehide.

Not fixed in this round (still open from the re-audit): the C2 per-call preference read, C5 drag/scroll cancellation, and the missing C3/C4/C5 tests.

## 4. Review follow-up: overstatements in the correction commit

An adversarial review of `66a49f5`, `360125d` and `dfe8023` found no code defects but judged the documentation fix partial: the correction commit added three new overstatements. Each was re-checked against the code and corrected.

- "Quits and relaunches do not reset the assertion" (CHANGELOG, `docs/MACOS_27.md`, section 1 above). True only for Visible-section apps. `ModernMenuBarLayout.visibilityPlan` puts running Hidden/Always-Hidden bundles into the plan, and `applyVisibility` reactivates whenever the plan differs from the applied one. So quitting or relaunching a concealed app replaces the assertion, and it is released when nothing else (no other app, no system control) stays hidden. New test `testQuitAndRelaunchReactivateOnlyForConcealedApps` pins both halves through the manager and the fake workspace. The docs now also state that a background-only-to-accessory switch waits for the 20-second backstop, and that retaining a quit app's bundle assumes MenuBarClientCore matches bundle identifiers dynamically, which is unverified live.
- "Within about a quarter second" (CHANGELOG). The 250 ms is only the debounce. It starts when `NSWorkspace.runningApplications` changes, which the probe measured about 0.4 s after launch. The CHANGELOG now says roughly a second and marks the live timing as unmeasured.
- "Stop pointer movement from cancelling pending clicks" (CHANGELOG). This contradicted its own known-gap note. `mouseMovedTap` cancels hover intents only, but it only sees moves with the button released. Moving while the button is held arrives as `leftMouseDragged`, and `mouseDraggedMonitor` still cancels every pending intent. The entry now says a pending click survives plain mouse-move events within four points, and that drags and scrolls still cancel it.
- Also tightened: "behavior with Screen Recording is unchanged" now reads "with Screen Recording and readable titles". `SmartRehidePolicy.titlesAvailable` also needs another app's titled normal-level window, so a permitted Ice with no such window uses the untitled path. The 2026-09-26 report's manual-acceptance line no longer says unrelated apps never cycle assertions.

Still open after that follow-up: the C2 per-call preference read, C5 drag/scroll cancellation, the missing C3/C4/C5 tests, and live verification of both fixes. Section 5 closes all but the C4 test and the live checks.

## 5. Second follow-up: remaining code gaps from the Low finding

The Low finding's suggested fix was to close the code gaps, not only to document them. The user's saved settings have show-on-click and show-on-scroll on, so both gaps below affect them directly. Each was re-verified against the code first.

- **C5 drag/scroll cancelled pending clicks.** `mouseDraggedMonitor` and `scrollWheelMonitor` called `cancelModernEmptySpaceAction()` unconditionally. A click intent waits 50 ms plus an Accessibility confirmation (up to 0.4 s), and pressing a button can report a one- or two-point `leftMouseDragged`, which dropped the click. Both monitors now call `EventManager.modernPointerEventOccurred(_:at:)`: any drag or scroll still cancels a hover intent, but a click intent is cancelled only once the pointer is more than four points away (the same tolerance the action checks when it fires). Moving back does not revive a cancelled click. The bookkeeping moved into `startModernIntent(at:isHover:body:)` unchanged, so tests can drive it. Debug log: `[Ice ShowOnClick] pending click kept through drag|scroll jitter` (once per click).
- **C2 per-call auto-hide read.** `NSScreen.appKitMenuBarFrame` copied the whole global defaults domain on every call; with show-on-scroll that is every scroll event (`handleShowOnScroll` → `isMouseInsideMenuBar`). It now calls `Defaults.MenuBarAutoHide.isEnabled()`, which reuses one read for up to a second. The cache is lock-guarded because the `NSScreen` extension is not main-actor isolated. Debug log: `[Ice MenuBarAutoHide] preference read as 0|1` when the value changes. `appKitMenuBarFrame` still lists on-screen windows (`WindowInfo.menuBarWindow`) per call; that is outside C2's scope and unmeasured.
- **C3 manager-level tests.** `testSnapshotStartedBeforePlanChangeIsDiscarded`: a snapshot read starts while an app is visible, the app is then assigned to Hidden and the new assertion is confirmed, and the stale reply arrives. It must not release the new assertion, set an error, or schedule a retry. `testVerificationCannotFailInsideSettleWindow`: snapshots that keep showing a concealed item must not fail verification (through the refresh path and the one-second retries) until three seconds after activation, and must fail after that.
- **C4** is still without a test: `move()` reads the live enumerator and posts real Command-drag events, so testing it safely needs injection first.

**Tests.** `IceTests/MenuBarPointerEventTests.swift` (5 tests) drives `EventManager` through the method both monitors call: jitter drags and scrolls keep a pending click, which still fires; a drag beyond four points or an unknown pointer location cancels it; any drag or scroll cancels a hover. It also calls the real `NSScreen.containsAppKitMenuBarPoint` 100 times and asserts one preference read, and checks re-reads after the maximum age. The standalone script gained one intent check (21 checks).

**Fails without the fix** (all four reverted together, then restored; targeted run): restoring the unconditional cancel, the direct `Defaults.globalDomain` read, the pre-C3 post-await generation/plan capture, and the retry's missing `elapsed >= 3` gate made the corresponding tests fail (details under Verification).

**Known difference.** A scroll that arrives while a click is pending no longer cancels it. With show-on-scroll, if the scroll changes the section first, the click action sees the changed state and does nothing, so there is no double toggle.

## Verification

Host: macOS 27.0 (26A428). Scratch paths are under the session scratchpad (`fix2/impl-ice/`).

```sh
TMPDIR=<scratch>/tmp bash scripts/run-modern-visibility-standalone-tests.sh
xcodebuild -project Ice.xcodeproj -scheme Ice -destination 'platform=macOS' \
  -derivedDataPath <scratch>/dd -resultBundlePath <scratch>/results-final.xcresult \
  CODE_SIGNING_ALLOWED=NO test
git diff --check
```

- Standalone: **20 passed** (19 before plus the allowlist check).
- IceTests: **86 passed, 0 failed, 0 skipped** (`xcresulttool get test-results summary`; 72 before, plus 5 lifecycle and 9 smart-rehide tests). No new compiler warnings in the touched files; SwiftLint is not installed locally, so strict lint was not run.
- `git diff --check`: clean.
- Settings safety: the xcodebuild test host shares `com.jordanbaird.Ice`. The domain was exported before the first run and after the final run; the exports are identical. No import or restore was done.

Review follow-up (scratch `fix2/fixup-ice/`, same commands):

- Standalone: **20 passed**.
- IceTests: **87 passed, 0 failed, 0 skipped** (86 plus `testQuitAndRelaunchReactivateOnlyForConcealedApps`).
- `git diff --check`: clean.
- Settings safety: this time the exports differ in one key. The test host rewrote `NSWindow Frame PermissionsWindow` from `22 17 550 820 …` to `22 -15 550 852 …`: the test-host copy opened its Permissions window (the known re-audit Low finding that IceTests runs a full Ice against the installed app's settings). No other key changed, and nothing was imported or restored.

Second follow-up (scratch `fix2/fixup-ice/run2/`, same commands):

- Standalone: **21 passed** (20 plus the intent jitter check).
- IceTests: **94 passed, 0 failed, 0 skipped** (87 plus 5 `MenuBarPointerEventTests` and 2 C3 manager tests). No compiler warnings in the touched files; the remaining warnings are the existing unstructured-throwing-task ones in untouched files.
- Fails without the fix (targeted `-only-testing` run with all four reverted, then restored): `testDragAndScrollJitterKeepPendingClick` ("Jitter within four points must keep the click"), `testMenuBarFrameReusesOneAutoHidePreferenceRead` (0 reads through the cache instead of 1), `testSnapshotStartedBeforePlanChangeIsDiscarded` (2 invalidations, "macOS did not apply menu bar hiding.", a third activation from the retry), `testVerificationCannotFailInsideSettleWindow` (the one-second retry had already failed verification and released the assertion before the 2.5 s check). The other three pointer tests passed, as expected: two cover cancellation, which the old code also did, and one exercises the cache directly.
- `git diff --check`: clean.
- Settings safety: exported before and after. The only difference is again `NSWindow Frame PermissionsWindow` (`22 155 550 682 …` before, `22 17 550 820 …` after), from the test host's Permissions window. The "before" value already differed from the previous run's "after" value, so the installed Ice also rewrites this key. Nothing was imported or restored.
- Final run on the committed tree: standalone **21 passed**; IceTests **93 passed, 1 skipped, 0 failed**. The skip was the unrelated `ModernMenuBarHealthTests.testRunningSystemAgentHasUsableKernelIdentity`, whose guard found no MenuBarAgent in that test host's running-application list at that moment (MenuBarAgent was running); two targeted reruns passed. Settings exports before and after this run, and after the reruns, were identical.

## Manual checks still required on the real Mac

1. Install a build with these commits (not done here). With a Hidden assignment active, launch a menu bar app that was not running (for example Dropbox or a VPN client). Its icon should appear within about a second without toggling, and `log stream --predicate 'process == "Ice"' | grep "reapplying allowlist"` should show one line.
2. Open and close Safari tabs and quit/relaunch that app: at most one "reapplying allowlist" line per helper bundle's first launch, none for the relaunch, no menu bar reflow, and the relaunched app's icon must come back. A missing icon would mean MenuBarClientCore binds the allowlist to the processes running at activation, and relaunches would then need a reapply. Quitting or relaunching a Hidden app while Hidden is concealed is expected to replace the assertion (one activation line, no "reapplying allowlist" line).
3. Limited mode (no Screen Recording), auto-rehide on, Smart strategy: reveal Hidden items, click into Safari or Finder, and confirm the items rehide after about 250 ms. `[Ice SmartRehide]` lines should show `titlesAvailable=0 … rehide=1`.
4. Same, clicking the desktop and the Dock (both should rehide), and clicking a Raycast/Spotlight-style panel (see the known difference above).
5. Optional: grant Screen Recording, relaunch Ice, and confirm `titlesAvailable=1` and unchanged behavior.
6. Show-on-click: press in empty menu bar space with a slight wobble (or a firm trackpad click) and while a scroll is still coasting. The Hidden section should toggle every time; `[Ice ShowOnClick] pending click kept through drag jitter` appears when a wobble was absorbed. Command-dragging a menu bar item must still not toggle sections.
7. Show-on-scroll: scroll continuously for about 10 seconds and run `sample Ice 10` meanwhile. `persistentDomain` should appear on the scroll path at most about once per second, not once per event; `[Ice MenuBarAutoHide]` should log only when the auto-hide setting changes.

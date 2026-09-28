# Ice re-audit High fixes — 2026-09-28

Scope: the two High findings for Ice in the workspace-level re-audit (`Coding/docs-internal/reaudit-2026-09-27/findings.md`, outside this repository), plus the Low finding that the 2026-09-26 report, CHANGELOG and docs overstated C2/C3/C4/C5/C7. Local commits only; nothing pushed, installed, or restarted.

## 1. C7 regression: apps launched while hiding is active stayed hidden

**Root cause (re-verified at `2d55998`).** The assertion is an allowlist: anything not listed is hidden. `applyVisibility` skipped reactivation when `allowed ∩ bundles(items) == applied ∩ bundles(items)`. `items` only contains observed status items, and an app launched after activation is hidden by the assertion, so it is never observed. Both sides of the check stayed equal forever.

A second, independent gap: the only launch trigger was `NSWorkspace.didLaunchApplicationNotification`. A scratch probe on this Mac (macOS 27.0, 26A428) showed that macOS posts **no** launch or termination notification for an LSUIElement app, which most status-item apps are. Only KVO on `NSWorkspace.runningApplications` fired (about 0.4 s after `openApplication`, on the main thread). So even a correct gate would have waited for the 20-second backstop.

**Fix.**

- `ModernAllowlistReapply.missingBundles` (in `ModernSystemItem.swift`): reapply when a running bundle that can own a status item (activation policy not `.prohibited`) is allowed by the plan but missing from the active assertion. Terminations never reapply.
- `ModernAllowlistReapply.candidateBundles`: bundles an assertion allowed earlier stay in later allowlists while their saved section is visible, so quitting and relaunching an app (or an accessory helper such as WebKit processes) does not reactivate the assertion. Reassigning such an app to Hidden removes it at the next assertion.
- `ModernMenuBarManager` observes the running-application list (debounced 250 ms) and calls `applyVisibility` directly, without waiting for an AX snapshot, then requests a refresh for discovery. Suspended managers ignore it; during a move it defers to the post-move refresh.
- `ModernMenuBarEnvironment` injects running applications, the layout store, and the assertion API. The live environment is unchanged behavior; tests use a fake so they neither read the saved layout nor create real assertions. The three existing manager tests now use the fake too (previously they could activate a real assertion from the test host if the saved layout had hidden items). Verification and retry snapshots now go through the same snapshot source as refresh.
- Debug logging: `[Ice ModernMenuBar] reapplying allowlist for N newly running application(s)` (NSLog) plus the bundle list at `info` level with private redaction; the activation line now includes `allowedApps=`.

**Tests.**

- `ModernVisibilityLifecycleTests.testAppLaunchedWhileHidingIsActiveBecomesVisiblePromptly` — manager-level, fake workspace/assertion API: activates hiding, launches an app absent from every snapshot, asserts a new assertion that allows it within 1 s, and the previous assertion released. Then asserts no reactivation for a background-only helper launch, a quit, a relaunch, or a relaunch after a reveal/conceal cycle, and that an app reassigned to Hidden is dropped from the next allowlist.
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

## Manual checks still required on the real Mac

1. Install a build with these commits (not done here). With a Hidden assignment active, launch a menu bar app that was not running (for example Dropbox or a VPN client). Its icon should appear within about a second without toggling, and `log stream --predicate 'process == "Ice"' | grep "reapplying allowlist"` should show one line.
2. Open and close Safari tabs and quit/relaunch that app: no further "reapplying allowlist" lines and no menu bar reflow.
3. Limited mode (no Screen Recording), auto-rehide on, Smart strategy: reveal Hidden items, click into Safari or Finder, and confirm the items rehide after about 250 ms. `[Ice SmartRehide]` lines should show `titlesAvailable=0 … rehide=1`.
4. Same, clicking the desktop and the Dock (both should rehide), and clicking a Raycast/Spotlight-style panel (see the known difference above).
5. Optional: grant Screen Recording, relaunch Ice, and confirm `titlesAvailable=1` and unchanged behavior.

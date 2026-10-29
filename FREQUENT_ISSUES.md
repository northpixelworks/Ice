# Frequent Issues <!-- omit in toc -->

- [Items are moved to the always-hidden section](#items-are-moved-to-the-always-hidden-section)
- [Ice removed an item](#ice-removed-an-item)
- [Ice does not remember the order of items](#ice-does-not-remember-the-order-of-items)
- [A visible app is missing from the Menu Bar Layout view](#a-visible-app-is-missing-from-the-menu-bar-layout-view)
- [A visible app remains onscreen when the menu bar auto-hides](#a-visible-app-remains-onscreen-when-the-menu-bar-auto-hides)
- [How do I solve the `Ice cannot arrange menu bar items in automatically hidden menu bars` error?](#how-do-i-solve-the-ice-cannot-arrange-menu-bar-items-in-automatically-hidden-menu-bars-error)
- [Why do local installs keep asking for Accessibility or Screen Recording permission?](#why-do-local-installs-keep-asking-for-accessibility-or-screen-recording-permission)

## Items are moved to the always-hidden section

By default, macOS adds new items to the far left of the menu bar, which is also the location of Ice's always-hidden section. Most apps are configured
to remember the positions of their items, but some are not. macOS treats the items of these apps as new items each time they appear. This results in
these items appearing in the always-hidden section, even if they have been previously been moved.

Ice does not currently manage individual items, and in fact cannot, as of the current release. Once issues
[#6](https://github.com/jordanbaird/Ice/issues/6) and [#26](https://github.com/jordanbaird/Ice/issues/26) are implemented, Ice will be able to
monitor the items in the menu bar, and move the ones it recognizes to their previous locations, even if macOS rearranges them.

## Ice removed an item

Ice does not have the ability to move or remove items. It likely got placed in the always-hidden section by macOS. Option + click the Ice icon to show
the always-hidden section, then Command + drag the item into a different section.

## Ice does not remember the order of items

This is not a bug, but a missing feature. It is being tracked in [#26](https://github.com/jordanbaird/Ice/issues/26).

## A visible app is missing from the Menu Bar Layout view

Some menu bar apps use a status-level overlay window when their native status item exists but is not visibly placed by macOS. Portworth is one example: it can show a portfolio title and sparkline in a Portworth-owned status-level window titled `com.portworth.app.statusItem`.

What failed:

1. Looking only at macOS's private menu bar item list missed these overlay-backed items.
2. Classifying sections only by Ice's divider item positions could place a real on-screen overlay into the wrong section when the overlay appeared left of the usual status cluster.
3. Letting the overlay app detect its own window as a native item caused brief hide/show flicker after wake or unlock.

What works:

Ice now merges the private menu bar item list with auxiliary on-screen status-level windows whose titles start with their owning app's bundle identifier, or the dashed form of that bundle identifier. Those bundle-identified windows are treated as read-only overlay-contract items: Ice shows them in layout views and reserves space around them, but the owning app remains responsible for drawing, positioning, and visibility. If macOS reports a scripted/helper app's status-level window without a bundle identifier or CoreGraphics title, Ice can still treat the top-pinned app-owned window as auxiliary by using its owner name while excluding known system owners. These auxiliary windows are cached as visible when they are on screen, because that matches what the user actually sees in the menu bar.

Ice treats auxiliary item frame changes as cache changes too. This is important for apps whose status-level windows move, resize, or change visibility without getting a new window identifier.

When the hidden section is shown in the native menu bar, Ice also keeps enough invisible divider width reserved for these auxiliary status windows. The reservation uses the auxiliary window frames captured while the hidden section is hidden and merges in live on-screen auxiliary frames when the cached visible-section list is stale, so newly shown native items are added to the left without pushing the auxiliary window around. Once the divider frame is available, only auxiliary frames on that divider's display participate in the reservation; overlays on a left-hand or vertically offset display cannot inflate another display's spacer. If the modeled menu bar item list temporarily misses an app-owned overlay, Ice falls back to directly scanning WindowServer for status-level windows owned by non-system apps. If the hidden-section divider frame lands inside an auxiliary overlay, Ice reserves across the full auxiliary frame instead of only reserving up to the divider edge. If the divider frame is temporarily unavailable during the first reveal layout pass, Ice still reserves the auxiliary overlay's full width plus the clearance the settled divider-frame calculation normally needs, and keeps the last valid reservation while macOS is reshuffling windows. The spacer is primed while the section is hidden and is allowed to grow, but not shrink, until the section hides again. This prevents hidden native menu bar items from sliding under an auxiliary overlay window that macOS does not manage as a normal status item.

When the system menu bar is configured to auto-hide, Ice ignores transient offscreen reports from its hidden-section control item while the pointer is still in the menu-bar strip. This keeps the Show All click from immediately rehiding the expanded items during the reveal animation.

Some auxiliary status windows are shorter than the system menu bar and are pinned by macOS to the menu bar's top edge. Ice cannot move those third-party windows directly, so it marks them as non-movable in the Menu Bar Layout view. For non-contract auxiliary windows, it can also place a pass-through visual cover over the item while the menu bar is visible, redraw the menu bar background, and paint the captured auxiliary item centered within the full menu bar height. Bundle-identified contract overlays are not covered or recentered by Ice. The cover ignores mouse events, so clicks still reach the owning app's real status window.

When Ice renders auxiliary windows inside Ice Bar or the Menu Bar Layout view, it trims transparent horizontal padding from the captured image. Some apps expose a much wider status-level window than the content they actually draw, and trimming keeps those items from appearing offset inside Ice's own UI.

Implementation note: Ice's hide/show control is driven by both the control item's published hiding state and the spacer length applied to the status item. When updating this flow, make length and auxiliary reservation calculations use the state value currently being applied, because reading the stored state during a publisher callback can be stale and can leave hidden items visible after the user clicks Hide.

Control items are constructed before `MenuBarManager.sections` has been assigned, so initial control item configuration cannot always resolve its owning section. After the section graph is assigned, reapply each control item's current state so the Ice icon and hidden-section spacer are configured from a valid section. Both `.hideItems` and `.showItems` updates must apply status item length changes; otherwise the layout view can show items in the Hidden Section while the native menu bar still displays them.

This is intentionally generic. It does not hardcode Portworth, but Portworth's stable `com.portworth.app.statusItem` window title, or its app owner name on systems where CoreGraphics reports an empty title, gives Ice enough identity to show it in the Visible Section.

## A visible app remains onscreen when the menu bar auto-hides

Some apps draw their own status-level window in the menu bar. Portworth is one example. These windows are owned by the app, not by Ice or the macOS menu bar, so Ice cannot move or hide them the same way it moves native status items.

When the macOS menu bar is configured to automatically hide and show, Ice handles non-contract auxiliary status-level windows by placing a cover window over each auxiliary item. The cover tracks the auxiliary item's current position and waits until the Window Server menu bar is gone and Ice's hidden control item is offscreen before capturing the hidden-state image. Ice refreshes the cover image when the cover appears, when the auxiliary item moves, and periodically while hidden, instead of recapturing it on every pointer movement.

The same cover mechanism may also be visible while the menu bar is shown for non-contract auxiliary windows that macOS pins to the top edge of the menu bar. In that case, Ice redraws the captured item centered in the menu bar instead of hiding it.

This cover is visual only. The app that owns the auxiliary window still owns its window and may update or animate it independently.

## How do I solve the `Ice cannot arrange menu bar items in automatically hidden menu bars` error?

Showing and rehiding hidden items is supported when the macOS menu bar is set to automatically hide and show. Arranging menu bar items still requires the menu bar to be permanently visible while you make layout changes:

1. Open `System Settings` on your Mac
2. Go to `Control Center`
3. Select `Never` as shown in the image below
4. Update your `Menu Bar Items` in `Ice`
5. Return `Automatically hide and show the menu bar` to your preferred settings

![Disable Menu Bar Hiding](https://github.com/user-attachments/assets/74c1fde6-d310-4fe3-9f2b-703d8ccb636a)

## Why do local installs keep asking for Accessibility or Screen Recording permission?

macOS stores Accessibility and Screen Recording grants against the installed app's identity. Ad-hoc local builds are identified by build-specific code hashes, so macOS can treat a rebuilt app as a new app after signing, bundle contents, or install path changes.

The `build-and-install.sh` helper preserves existing TCC permissions. It no longer calls `tccutil reset` for Accessibility or Screen Recording during install. It builds locally when full Xcode is available; otherwise it downloads the latest successful `build-artifact.yml` GitHub Actions artifact with `gh`. In both paths it creates or reuses a self-signed `Ice Local Development` code-signing identity in the login keychain, then signs the embedded Sparkle framework and Ice app with that stable identity before launching the new build. If the identity cannot be created or cannot sign, the script stops and leaves the installed app unchanged; set `ICE_ADHOC_SIGNING=1` only if you accept an ad-hoc install that needs a new Accessibility approval.

The certificate is intentionally **not** trusted: Keychain Access shows it as untrusted and `security find-identity -v` reports 0 valid identities. That is expected. `codesign` can still sign with it, and macOS ties the Accessibility grant to the certificate's fingerprint, so do not trust the certificate or add `-v` back to the lookup. The script exports the certificate as SHA1/3DES PKCS#12 because OpenSSL 3+ defaults to a format `security import` rejects ("MAC verification failed").

The first install signed with a new `Ice Local Development` certificate requires one new Accessibility approval. Remove Ice from `System Settings` > `Privacy & Security` > `Accessibility` with **−**, add `/Applications/Ice.app` again and switch it on; only switching an old entry back on is not enough, because that entry still remembers the old signature. Later local rebuilds or artifact installs keep that grant as long as `/Applications/Ice.app`, the bundle identifier, and the local certificate remain stable. To confirm after an install, run `/usr/bin/log stream --debug --style compact --predicate 'process == "Ice" AND subsystem == "com.jordanbaird.Ice"'` while Ice launches and look for "Passed all permissions checks". Stable Developer ID signing is still the best long-term distribution identity outside local development.

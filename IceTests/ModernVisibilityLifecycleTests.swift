import Combine
import XCTest
@testable import Ice

final class ModernVisibilityLifecycleTests: XCTestCase {
    func testHiddenInputMenuCannotBeAllowedThroughItsHostBundle() {
        let running: Set<String> = ["com.apple.TextInputMenuAgent", "example.visible", "example.hidden", "ice"]
        var plan = ModernVisibilityPlan(bundles: ["example.hidden"], systemItems: [.keyboard])
        XCTAssertEqual(plan.allowedBundles(runningBundles: running, ownBundle: "ice"), ["example.visible", "ice"])
        XCTAssertFalse(plan.allowedSystemItems.contains(.keyboard))
        plan.systemItems = []
        XCTAssertTrue(plan.allowedBundles(runningBundles: running, ownBundle: "ice").contains("com.apple.TextInputMenuAgent"))
    }

    func testInputMenuAllowlistFollowsSavedSectionAndRevealState() {
        let host = "com.apple.TextInputMenuAgent"
        let running: Set<String> = [host, "example.visible"]
        for section in ModernMenuBarLayout.Section.allCases {
            var layout = ModernMenuBarLayout()
            layout.assignments[ModernSystemItem.keyboard.assignmentKey] = section
            for revealed: Set<ModernMenuBarLayout.Section> in [[], [.hidden], [.hidden, .alwaysHidden]] {
                let plan = layout.visibilityPlan(revealing: revealed, runningBundles: running, ownBundle: "ice")
                let shouldShow = section == .visible || revealed.contains(section)
                let allowed = plan.allowedBundles(runningBundles: running, ownBundle: "ice")
                XCTAssertEqual(allowed.contains(host), shouldShow)
                XCTAssertEqual(plan.allowedSystemItems.contains(.keyboard), shouldShow)
                XCTAssertTrue(allowed.contains("example.visible"))
                XCTAssertTrue(allowed.contains("ice"))
            }
        }
        let wifiOnly = ModernVisibilityPlan(systemItems: [.wifi])
        XCTAssertTrue(wifiOnly.allowedBundles(runningBundles: running, ownBundle: "ice").contains(host))
        XCTAssertEqual(wifiOnly.allowedBundles(runningBundles: [], ownBundle: "ice"), ["ice"])
    }

    private func item(_ bundle: String, title: String = "Item", x: CGFloat = 0, pid: pid_t = 100) -> ModernMenuBarItem {
        ModernMenuBarItem(
            id: .status(bundle: bundle, title: title),
            frame: CGRect(x: x, y: 0, width: 22, height: 22),
            appName: bundle,
            hostIsBundleless: false,
            pid: pid
        )
    }

    private func systemAnchor() -> ModernMenuBarItem {
        ModernMenuBarItem(
            id: .status(bundle: "com.apple.MenuBarAgent", title: "com.apple.menuextra.controlcenter"),
            frame: CGRect(x: 40, y: 0, width: 22, height: 22),
            appName: nil,
            hostIsBundleless: false,
            pid: 200
        )
    }

    func testReadableSnapshotConfirmsHiddenWhenTargetsAreGone() {
        var plan = ModernVisibilityPlan()
        plan.bundles = ["example.hidden"]
        let snapshot = ModernMenuBarSnapshot(items: [item("example.visible"), systemAnchor()], isReadable: true)
        XCTAssertEqual(ModernVisibilityVerifier.verify(plan, in: snapshot), .confirmedHidden)
    }

    func testEmptyReadableSnapshotDoesNotConfirmHidden() {
        var plan = ModernVisibilityPlan()
        plan.bundles = ["example.hidden"]
        let snapshot = ModernMenuBarSnapshot(items: [], isReadable: true)
        XCTAssertEqual(ModernVisibilityVerifier.verify(plan, in: snapshot), .unreadable)
    }

    func testRetractedBarCannotConfirmOrFailHidingFromCachedItems() {
        var plan = ModernVisibilityPlan()
        plan.bundles = ["example.hidden"]
        for observed in [[systemAnchor()], [item("example.hidden"), systemAnchor()]] {
            let snapshot = ModernMenuBarSnapshot(items: observed, isReadable: true, isMenuBarPresented: false)
            XCTAssertEqual(ModernVisibilityVerifier.verify(plan, in: snapshot), .unreadable)
            XCTAssertFalse(snapshot.canVerifyVisibility)
        }
    }

    func testRetractedDisplayDoesNotInvalidateHidingOnPresentedDisplay() {
        var plan = ModernVisibilityPlan()
        plan.bundles = ["example.hidden"]
        let snapshot = ModernMenuBarSnapshot(
            items: [item("example.hidden"), systemAnchor()],
            isReadable: true,
            presentedItems: [systemAnchor()]
        )
        XCTAssertEqual(ModernVisibilityVerifier.verify(plan, in: snapshot), .confirmedHidden)
        let missingVisibleAnchor = ModernMenuBarSnapshot(
            items: [systemAnchor()], isReadable: true, presentedItems: []
        )
        XCTAssertFalse(missingVisibleAnchor.canVerifyVisibility)
    }

    func testStillVisibleTargetFailsVerification() {
        var plan = ModernVisibilityPlan()
        plan.bundles = ["example.hidden"]
        let snapshot = ModernMenuBarSnapshot(items: [item("example.hidden"), systemAnchor()], isReadable: true)
        XCTAssertEqual(ModernVisibilityVerifier.verify(plan, in: snapshot), .stillVisible([item("example.hidden").id]))
    }

    func testPartialSnapshotWithoutSystemAnchorDoesNotConfirmHidden() {
        var plan = ModernVisibilityPlan()
        plan.bundles = ["example.hidden"]
        let snapshot = ModernMenuBarSnapshot(items: [item("example.visible")], isReadable: true)
        XCTAssertEqual(ModernVisibilityVerifier.verify(plan, in: snapshot), .unreadable)
    }

    func testSnapshotWithReadErrorsDoesNotConfirmHiddenEvenWithAnchor() {
        var plan = ModernVisibilityPlan()
        plan.bundles = ["example.hidden"]
        let snapshot = ModernMenuBarSnapshot(
            items: [item("example.visible"), systemAnchor()],
            isReadable: true,
            hasReadErrors: true
        )
        XCTAssertEqual(ModernVisibilityVerifier.verify(plan, in: snapshot), .unreadable)
    }

    func testPartialDiscoveryRetainsAliveUnobservedItemsAndAcceptsNewObservedItems() {
        let retainedVisible = item("example.visible", x: 30, pid: 101)
        let retainedHidden = item("example.hidden", x: 20, pid: 102)
        let droppedDead = item("example.dead", x: 10, pid: 103)
        let observedNew = item("example.new", x: 40, pid: 104)
        let ownItem = item(Constants.bundleIdentifier, x: 50, pid: 105)
        var plan = ModernVisibilityPlan()
        plan.bundles = ["example.hidden"]

        let merged = ModernItemDiscovery.mergedItems(
            previous: [retainedVisible, retainedHidden, droppedDead],
            observed: [observedNew, ownItem],
            appliedVisibility: plan,
            retainAllUnobserved: true,
            ownBundle: Constants.bundleIdentifier,
            isAlive: { $0 != droppedDead.pid }
        )

        XCTAssertEqual(merged.map(\.id), [retainedHidden.id, retainedVisible.id, observedNew.id])
    }

    func testCompleteDiscoveryOnlyRetainsConcealedAliveItems() {
        let visible = item("example.visible", x: 10, pid: 101)
        let hidden = item("example.hidden", x: 20, pid: 102)
        let observed = item("example.observed", x: 30, pid: 103)
        var plan = ModernVisibilityPlan()
        plan.bundles = ["example.hidden"]

        let merged = ModernItemDiscovery.mergedItems(
            previous: [visible, hidden],
            observed: [observed],
            appliedVisibility: plan,
            retainAllUnobserved: false,
            ownBundle: Constants.bundleIdentifier,
            isAlive: { _ in true }
        )

        XCTAssertEqual(merged.map(\.id), [hidden.id, observed.id])
    }

    func testMissingCallbackCanStillConfirmFromSnapshot() {
        var lifecycle = ModernVisibilityLifecycle()
        let generation = lifecycle.beginActivation()
        let outcome = lifecycle.verify(generation: generation, result: .confirmedHidden, allowFailure: true)
        XCTAssertEqual(outcome, .confirmed)
        XCTAssertEqual(lifecycle.state, .active)
    }

    func testLateCallbackAfterSnapshotConfirmationIsIgnored() {
        var lifecycle = ModernVisibilityLifecycle()
        let generation = lifecycle.beginActivation()
        XCTAssertEqual(lifecycle.verify(generation: generation, result: .confirmedHidden, allowFailure: true), .confirmed)
        XCTAssertFalse(lifecycle.handleCallback(generation: generation))
    }

    func testStaleGenerationVerificationIsIgnored() {
        var lifecycle = ModernVisibilityLifecycle()
        let staleGeneration = lifecycle.beginActivation()
        _ = lifecycle.beginActivation()
        XCTAssertEqual(
            lifecycle.verify(generation: staleGeneration, result: .confirmedHidden, allowFailure: true),
            .ignoredStale
        )
        XCTAssertTrue(lifecycle.isPending)
    }

    func testPendingObservationCannotFailBeforeDeadline() {
        var lifecycle = ModernVisibilityLifecycle()
        let generation = lifecycle.beginActivation()
        let hidden = ModernItemID.status(bundle: "example.hidden", title: "Item")
        XCTAssertEqual(
            lifecycle.verify(generation: generation, result: .stillVisible([hidden]), allowFailure: false),
            .keepWaiting
        )
        XCTAssertEqual(lifecycle.generation, generation)
        XCTAssertTrue(lifecycle.isPending)
    }

    func testUnreadableVerificationRetriesAreBoundedWithoutDroppingAssertion() {
        var lifecycle = ModernVisibilityLifecycle(unreadableRetryLimit: 2)
        let generation = lifecycle.beginActivation()
        XCTAssertEqual(lifecycle.verify(generation: generation, result: .unreadable, allowFailure: true), .keepWaiting)
        XCTAssertEqual(lifecycle.verify(generation: generation, result: .unreadable, allowFailure: true), .keepWaiting)
        XCTAssertEqual(
            lifecycle.verify(generation: generation, result: .unreadable, allowFailure: true),
            .activeButUnverified
        )
        XCTAssertEqual(lifecycle.state, .activeUnverified)
    }

    func testConfirmedAssertionFailsIfConcealedTargetLaterReappears() {
        var lifecycle = ModernVisibilityLifecycle()
        let generation = lifecycle.beginActivation()
        XCTAssertEqual(lifecycle.verify(generation: generation, result: .confirmedHidden, allowFailure: true), .confirmed)
        let hidden = ModernItemID.status(bundle: "example.hidden", title: "Item")
        XCTAssertEqual(
            lifecycle.observeActive(.stillVisible([hidden])),
            .failed(message: "macOS did not apply menu bar hiding.")
        )
        XCTAssertEqual(lifecycle.generation, generation + 1)
    }

    func testConsecutiveFailuresForSamePlanIncrementAttemptHistory() {
        var plan = ModernVisibilityPlan()
        plan.bundles = ["example.hidden"]
        let first = ModernVisibilityFailure.record(previous: nil, plan: plan, message: "failed")
        let second = ModernVisibilityFailure.record(previous: first, plan: plan, message: "failed")
        let third = ModernVisibilityFailure.record(previous: second, plan: plan, message: "failed")
        let fourth = ModernVisibilityFailure.record(previous: third, plan: plan, message: "failed")
        let policy = ModernVisibilityRetryPolicy(maxAutomaticRetries: 3, initialDelay: 0.5)
        XCTAssertEqual(first.failureCount, 1)
        XCTAssertEqual(second.failureCount, 2)
        XCTAssertEqual(third.failureCount, 3)
        XCTAssertEqual(fourth.failureCount, 4)
        XCTAssertNotNil(policy.delay(afterFailureCount: third.failureCount))
        XCTAssertNil(policy.delay(afterFailureCount: fourth.failureCount))
    }

    func testDifferentPlanResetsAttemptHistory() {
        var firstPlan = ModernVisibilityPlan()
        firstPlan.bundles = ["example.hidden"]
        var secondPlan = ModernVisibilityPlan()
        secondPlan.bundles = ["example.other"]
        let first = ModernVisibilityFailure.record(previous: nil, plan: firstPlan, message: "failed")
        let reset = ModernVisibilityFailure.record(previous: first, plan: secondPlan, message: "failed")
        XCTAssertEqual(reset.failureCount, 1)
    }

    func testAutomaticRetryBackoffIsBounded() {
        let policy = ModernVisibilityRetryPolicy(maxAutomaticRetries: 3, initialDelay: 0.5)
        XCTAssertEqual(policy.delay(afterFailureCount: 1), 0.5)
        XCTAssertEqual(policy.delay(afterFailureCount: 2), 1.0)
        XCTAssertEqual(policy.delay(afterFailureCount: 3), 2.0)
        XCTAssertNil(policy.delay(afterFailureCount: 4))
    }

    func testMoveVerificationRejectsUnchangedAlreadyBeforeOrder() {
        let source = ModernItemID.status(bundle: "example.source", title: "Item")
        let middle = ModernItemID.status(bundle: "example.middle", title: "Item")
        let target = ModernItemID.status(bundle: "example.target", title: "Item")
        let before = [
            ModernMoveVerificationItem(id: source, midX: 10),
            ModernMoveVerificationItem(id: middle, midX: 20),
            ModernMoveVerificationItem(id: target, midX: 30),
        ]
        XCTAssertFalse(
            ModernMoveVerification.acceptedMoveBefore(source, targetID: target, before: before, after: before)
        )
    }

    func testMoveVerificationAcceptsNewBeforeTargetOrder() {
        let source = ModernItemID.status(bundle: "example.source", title: "Item")
        let target = ModernItemID.status(bundle: "example.target", title: "Item")
        let before = [
            ModernMoveVerificationItem(id: target, midX: 10),
            ModernMoveVerificationItem(id: source, midX: 20),
        ]
        let after = [
            ModernMoveVerificationItem(id: source, midX: 10),
            ModernMoveVerificationItem(id: target, midX: 20),
        ]
        XCTAssertTrue(
            ModernMoveVerification.acceptedMoveBefore(source, targetID: target, before: before, after: after)
        )
    }
}

/// Stands in for NSWorkspace, saved defaults, and the private assertion API,
/// so manager tests never read the user's layout or hide real menu bar items.
private final class FakeModernWorkspace {
    var applications: [ModernRunningApplication]
    var layout = ModernMenuBarLayout()
    private(set) var activatedAllowlists: [Set<String>] = []
    private(set) var invalidations = 0
    private let changes = PassthroughSubject<Void, Never>()

    init(applications: [ModernRunningApplication] = []) {
        self.applications = applications
    }

    func launch(_ bundleID: String, canOwnStatusItem: Bool = true) {
        applications.append(ModernRunningApplication(bundleID: bundleID, canOwnStatusItem: canOwnStatusItem))
        changes.send()
    }

    func terminate(_ bundleID: String) {
        applications.removeAll { $0.bundleID == bundleID }
        changes.send()
    }

    var environment: ModernMenuBarEnvironment {
        ModernMenuBarEnvironment(
            canHide: true,
            loadLayout: { [self] in layout },
            saveLayout: { [self] in layout = $0 },
            runningApplications: { [self] in applications },
            runningApplicationsChanged: changes.eraseToAnyPublisher(),
            makeConfiguration: { _, bundles in Set(bundles) as NSSet },
            activateAssertion: { [self] configuration, _ in
                activatedAllowlists.append(configuration as? Set<String> ?? [])
                return NSObject()
            },
            invalidateAssertion: { [self] assertion in
                if assertion != nil { invalidations += 1 }
            },
            startsWatchdog: false
        )
    }
}

@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async throws -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() {
        guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
        try await Task.sleep(for: .milliseconds(10))
    }
    return true
}

extension ModernVisibilityLifecycleTests {
    func testNewStatusItemAppMissingFromSnapshotRequiresReapply() {
        let running = [
            ModernRunningApplication(bundleID: "example.visible", canOwnStatusItem: true),
            ModernRunningApplication(bundleID: "example.new", canOwnStatusItem: true),
        ]
        // example.new is hidden by the assertion, so no snapshot contains it.
        XCTAssertEqual(
            ModernAllowlistReapply.missingBundles(
                allowed: ["example.visible", "example.new", "ice"],
                applied: ["example.visible", "ice"],
                running: running
            ),
            ["example.new"]
        )
    }

    func testTerminationRelaunchAndBackgroundHelpersDoNotRequireReapply() {
        let applied: Set<String> = ["example.visible", "example.relaunched", "example.quit", "ice"]
        let running = [
            ModernRunningApplication(bundleID: "example.visible", canOwnStatusItem: true),
            ModernRunningApplication(bundleID: "example.relaunched", canOwnStatusItem: true),
            ModernRunningApplication(bundleID: "example.helper", canOwnStatusItem: false),
        ]
        let allowed = applied.subtracting(["example.quit"]).union(["example.helper"])
        XCTAssertEqual(
            ModernAllowlistReapply.missingBundles(allowed: allowed, applied: applied, running: running),
            []
        )
    }

    func testConcealedLaunchIsLeftToThePlan() {
        let running = [ModernRunningApplication(bundleID: "example.hidden", canOwnStatusItem: true)]
        XCTAssertEqual(
            ModernAllowlistReapply.missingBundles(allowed: ["ice"], applied: ["ice"], running: running),
            []
        )
    }

    func testPreviouslyAllowedBundlesStayAllowedUntilConcealed() {
        XCTAssertEqual(
            ModernAllowlistReapply.candidateBundles(
                running: ["example.running"],
                previouslyAllowed: ["example.quit", "example.reassigned"],
                concealedAssignments: ["example.reassigned"]
            ),
            ["example.running", "example.quit"]
        )
    }

    /// Regression: with the allowlist compared only over observed items, an
    /// app launched after activation stayed hidden until an unrelated change.
    @MainActor
    func testAppLaunchedWhileHidingIsActiveBecomesVisiblePromptly() async throws {
        let workspace = FakeModernWorkspace(applications: [
            ModernRunningApplication(bundleID: Constants.bundleIdentifier, canOwnStatusItem: true),
            ModernRunningApplication(bundleID: "example.hidden", canOwnStatusItem: true),
            ModernRunningApplication(bundleID: "example.visible", canOwnStatusItem: true),
        ])
        workspace.layout.assignments["example.hidden"] = .hidden
        let observed = [item("example.visible"), systemAnchor()]
        let manager = ModernMenuBarManager(
            snapshotOverride: { ModernMenuBarSnapshot(items: observed, isReadable: true) },
            environment: workspace.environment
        )
        manager.performSetup()
        defer { manager.stop() }

        let activated = try await waitUntil { workspace.activatedAllowlists.count == 1 }
        XCTAssertTrue(activated, "Hiding never activated")
        guard activated else { return }
        XCTAssertFalse(workspace.activatedAllowlists[0].contains("example.hidden"))
        XCTAssertFalse(workspace.activatedAllowlists[0].contains("example.new"))

        let launchedAt = ProcessInfo.processInfo.systemUptime
        workspace.launch("example.new")
        let reapplied = try await waitUntil(timeout: 1) { workspace.activatedAllowlists.count == 2 }
        XCTAssertTrue(reapplied, "A new status-item app must be allowed without a manual toggle")
        guard reapplied else { return }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - launchedAt, 1)
        XCTAssertTrue(workspace.activatedAllowlists[1].contains("example.new"))
        XCTAssertFalse(workspace.activatedAllowlists[1].contains("example.hidden"))
        XCTAssertEqual(workspace.invalidations, 1, "The previous assertion is released after its replacement")

        // Background helpers, quitting, and relaunching cause no churn.
        workspace.launch("example.helper", canOwnStatusItem: false)
        try await Task.sleep(for: .milliseconds(500))
        workspace.terminate("example.new")
        try await Task.sleep(for: .milliseconds(500))
        workspace.launch("example.new")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(workspace.activatedAllowlists.count, 2)
        XCTAssertEqual(workspace.invalidations, 1)

        // A reveal/conceal cycle while the app is not running keeps it allowed.
        workspace.terminate("example.new")
        manager.reveal(.hidden)
        manager.conceal(.hidden)
        XCTAssertEqual(workspace.activatedAllowlists.count, 3)
        XCTAssertTrue(workspace.activatedAllowlists[2].contains("example.new"))
        workspace.launch("example.new")
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(workspace.activatedAllowlists.count, 3)

        // A retained app reassigned to Hidden is dropped at the next assertion.
        workspace.terminate("example.new")
        manager.assign(item("example.new"), to: .hidden)
        manager.reveal(.hidden)
        manager.conceal(.hidden)
        XCTAssertEqual(workspace.activatedAllowlists.count, 4)
        XCTAssertFalse(workspace.activatedAllowlists[3].contains("example.new"))
        XCTAssertEqual(workspace.layout.section(for: "example.new"), .hidden)
    }
}

private actor DelayedReviewSnapshot {
    var started = false
    var calls = 0
    var continuation: CheckedContinuation<ModernMenuBarSnapshot, Never>?
    func snapshot() async -> ModernMenuBarSnapshot {
        started = true
        calls += 1
        if calls > 1 { return .unreadable }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ value: ModernMenuBarSnapshot) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

extension ModernVisibilityLifecycleTests {
    @MainActor
    func testStoppedManagerDiscardsInFlightSnapshot() async throws {
        let gate = DelayedReviewSnapshot()
        let manager = ModernMenuBarManager(
            snapshotOverride: { await gate.snapshot() },
            environment: FakeModernWorkspace().environment
        )
        let refresh = Task { await manager.refresh() }
        for _ in 0..<100 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let started = await gate.started
        XCTAssertTrue(started)
        manager.stop()
        await gate.release(ModernMenuBarSnapshot(items: [item("example.late"), systemAnchor()], isReadable: true))
        await refresh.value
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertNil(manager.errorMessage)
    }
}

extension ModernVisibilityLifecycleTests {
    @MainActor
    func testWakeDuringSnapshotQueuesImmediateRefresh() async throws {
        let gate = DelayedReviewSnapshot()
        let manager = ModernMenuBarManager(
            snapshotOverride: { await gate.snapshot() },
            environment: FakeModernWorkspace().environment
        )
        manager.performSetup()
        defer { manager.stop() }
        for _ in 0..<100 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        center.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        await gate.release(.unreadable)
        try await Task.sleep(for: .milliseconds(50))
        let calls = await gate.calls
        XCTAssertEqual(calls, 2, "Wake must not wait for the 20-second backstop")
    }

    @MainActor
    func testSessionActivationDoesNotResumeSleepingScreens() async throws {
        let gate = DelayedReviewSnapshot()
        let manager = ModernMenuBarManager(
            snapshotOverride: { await gate.snapshot() },
            environment: FakeModernWorkspace().environment
        )
        manager.performSetup()
        defer { manager.stop() }
        for _ in 0..<100 {
            if await gate.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        await gate.release(.unreadable)
        try await Task.sleep(for: .milliseconds(20))
        let center = NSWorkspace.shared.notificationCenter
        center.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        center.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(20))
        center.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        let calls = await gate.calls
        XCTAssertEqual(calls, 1, "Session activation cannot override screen sleep")
    }
}

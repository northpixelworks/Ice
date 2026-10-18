//
//  ModernMenuBarManager.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// The macOS 27 status-item backend. AppState owns it alongside the legacy managers.
@MainActor
final class ModernMenuBarManager: ObservableObject {
    private let diagnosticLogger = Logger(subsystem: "com.jordanbaird.Ice", category: "ModernVisibility")
    @Published private(set) var items: [ModernMenuBarItem] = []
    @Published private(set) var layout: ModernMenuBarLayout
    @Published private(set) var isRefreshing = false
    @Published private(set) var isMoving = false
    @Published var errorMessage: String?
    @Published private(set) var revealed = Set<ModernMenuBarLayout.Section>()
    @Published private(set) var visibilityStatus = "Menu bar hiding is idle."
    @Published private(set) var isEditing = false

    let canHide = iceModern_assessmentModeAvailable()
    private let enumerator = ModernItemEnumerator()
    private let occupancyEnumerator = ModernItemEnumerator()
    private var timer: AnyCancellable?
    private var appLaunchObserver: AnyCancellable?
    private var assertion: AnyObject?
    private var appliedVisibility = ModernVisibilityPlan()
    private var appliedAllowedBundles = Set<String>()
    private var visibilityFailure: ModernVisibilityFailure?
    private let visibilityRetryPolicy = ModernVisibilityRetryPolicy()
    private var visibilityRetryTask: Task<Void, Never>?
    private var awaitingVisibility = false
    private var visibilityLifecycle = ModernVisibilityLifecycle()
    private var lastObservedIDs = Set<ModernItemID>()
    private lazy var watchdog = ModernMenuBarWatchdog { [weak self] in
        guard let self else { return false }
        return !self.isEditing && !self.isMoving
    }

    init() {
        layout = Defaults.data(forKey: .modernMenuBarLayout)
            .flatMap { try? JSONDecoder().decode(ModernMenuBarLayout.self, from: $0) } ?? .init()
    }

    func performSetup() {
        guard timer == nil else { return }
        watchdog.start()
        timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in Task { await self?.refresh() } }
        // macOS takes an allowlist, so an app launched after the last
        // activation stays hidden until Ice re-applies. Re-apply on launch
        // instead of waiting for the next refresh and its menu bar snapshot.
        let center = NSWorkspace.shared.notificationCenter
        appLaunchObserver = center.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .merge(with: center.publisher(for: NSWorkspace.didTerminateApplicationNotification))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyVisibility() }
        Task { await refresh() }
    }

    /// Routine hiding steps are logged only when the user turns on
    /// Advanced > Detailed menu bar logging. Failures are always logged.
    private var logsDetails: Bool {
        Defaults.bool(forKey: .detailedMenuBarLogging)
    }

    func refresh() async {
        guard !isRefreshing, !isMoving else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let snapshot = await enumerator.snapshot()
        if snapshot.isReadable, !snapshot.items.isEmpty {
            updateKnownItems(from: snapshot)
        }
        guard snapshot.canVerifyVisibility else {
            applyVisibility()
            if awaitingVisibility, !snapshot.isMenuBarPresented {
                visibilityStatus = "Menu bar hiding is active; verification resumes when the menu bar is shown."
            }
            return
        }
        lastObservedIDs = Set(snapshot.verificationItems.map(\.id))
        if awaitingVisibility {
            finishVisibilityVerification(snapshot, generation: visibilityLifecycle.generation, plan: appliedVisibility, allowFailure: false)
        } else if assertion != nil, appliedVisibility.requiresAssertion, !isEditing {
            checkActiveVisibility(snapshot, plan: appliedVisibility)
        }
        applyVisibility()
    }

    private func updateKnownItems(from snapshot: ModernMenuBarSnapshot) {
        items = ModernItemDiscovery.mergedItems(
            previous: items,
            observed: snapshot.items,
            appliedVisibility: appliedVisibility,
            retainAllUnobserved: !snapshot.canVerifyVisibility,
            ownBundle: Constants.bundleIdentifier,
            isAlive: { pid in
                NSRunningApplication(processIdentifier: pid)?.isTerminated == false
            }
        )
    }

    /// Never approve an empty-space action from the editor's cached/deduplicated
    /// frames. The actor serializes readers; a new click may wait for a canceled
    /// hover read, but that wait still consumes the new click's own deadline.
    func confirmsEmptySpace(at point: CGPoint) async -> Bool {
        let visibilityGeneration = visibilityLifecycle.generation
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let snapshot = await occupancyEnumerator.snapshotOccupancy(
            at: point,
            deadline: requestedAt + ModernMenuBarOccupancy.maximumSnapshotDuration
        )
        guard !Task.isCancelled, visibilityLifecycle.generation == visibilityGeneration else { return false }
        return snapshot.confirmsEmptySpace(
            at: point, requestedAt: requestedAt, now: ProcessInfo.processInfo.systemUptime
        )
    }

    func beginEditing() {
        isEditing = true
        visibilityFailure = nil
        applyVisibility()
        Task { await refresh() }
    }

    func endEditing() {
        isEditing = false
        visibilityFailure = nil
        applyVisibility()
    }

    func reveal(_ section: ModernMenuBarLayout.Section) {
        visibilityFailure = nil
        revealed.insert(.hidden)
        if section == .alwaysHidden { revealed.insert(.alwaysHidden) }
        applyVisibility()
        Task { await refresh() }
    }

    func conceal(_ section: ModernMenuBarLayout.Section) {
        visibilityFailure = nil
        if section == .alwaysHidden {
            revealed.remove(.alwaysHidden)
        } else {
            revealed.removeAll()
        }
        applyVisibility()
    }

    func retryHiding() {
        visibilityRetryTask?.cancel()
        visibilityRetryTask = nil
        visibilityFailure = nil
        errorMessage = nil
        revealed.removeAll()
        applyVisibility(forceRetry: true)
        Task { await refresh() }
    }

    func canAssign(_ item: ModernMenuBarItem) -> Bool {
        canHide && item.id.supportsHiding && !item.hostIsBundleless
    }

    func assign(_ item: ModernMenuBarItem, to section: ModernMenuBarLayout.Section) {
        guard section == .visible || canAssign(item) else {
            errorMessage = "macOS cannot hide this item through Ice."
            return
        }
        errorMessage = nil
        layout.assignments[item.id.assignmentKey] = section
        visibilityFailure = nil
        if let data = try? JSONEncoder().encode(layout) {
            Defaults.set(data, forKey: .modernMenuBarLayout)
        }
        applyVisibility()
    }

    func items(in section: ModernMenuBarLayout.Section) -> [ModernMenuBarItem] {
        items.filter { layout.section(for: $0.id) == section }
    }

    func isConcealed(_ item: ModernMenuBarItem) -> Bool {
        appliedVisibility.conceals(item.id)
    }

    func visibilityReality(for section: ModernMenuBarLayout.Section) -> (requested: Int, stillVisible: Int, concealed: Int) {
        let runningBundles = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let requestedPlan = layout.visibilityPlan(
            revealing: isEditing ? Set(ModernMenuBarLayout.Section.allCases) : revealed,
            runningBundles: runningBundles,
            ownBundle: Constants.bundleIdentifier
        )
        let requested = items.filter { layout.section(for: $0.id) == section && requestedPlan.conceals($0.id) }
        let stillVisible = requested.filter { lastObservedIDs.contains($0.id) }
        return (requested.count, stillVisible.count, max(0, requested.count - stillVisible.count))
    }

    private func applyVisibility(forceRetry: Bool = false) {
        let runningBundles = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let effective = layout.visibilityPlan(
            revealing: isEditing ? Set(ModernMenuBarLayout.Section.allCases) : revealed,
            runningBundles: runningBundles,
            ownBundle: Constants.bundleIdentifier
        )
        let allowed = effective.allowedBundles(runningBundles: runningBundles, ownBundle: Constants.bundleIdentifier)
        if let failure = visibilityFailure, failure.plan == effective, !forceRetry {
            visibilityStatus = failure.canRetryAutomatically
                ? "Menu bar hiding is waiting to retry."
                : "Menu bar hiding needs a retry."
            return
        }
        if !forceRetry,
           effective == appliedVisibility,
           !effective.requiresAssertion || allowed == appliedAllowedBundles,
           assertion != nil || !effective.requiresAssertion {
            updateVisibilityStatus(for: effective)
            return
        }
        visibilityLifecycle.markIdle()
        let previousAssertion = assertion
        awaitingVisibility = false
        guard effective.requiresAssertion else {
            iceModern_invalidateAssertion(previousAssertion)
            assertion = nil
            appliedVisibility = ModernVisibilityPlan()
            appliedAllowedBundles = []
            visibilityFailure = nil
            updateVisibilityStatus(for: effective)
            return
        }
        guard canHide else {
            errorMessage = "Menu bar hiding is unavailable on this macOS build."
            visibilityStatus = "Menu bar hiding is unavailable on this macOS build."
            return
        }
        // Include every running bundle, not only AX-visible apps. This keeps
        // unrelated and newly discovered applications visible.
        guard let config = iceModern_makeConfiguration(effective.allowedSystemItems.map { NSNumber(value: $0.rawValue) }, Array(allowed)) else {
            recordVisibilityFailure(effective, message: "macOS could not prepare menu bar hiding.")
            return
        }
        let activationGeneration = visibilityLifecycle.beginActivation()
        if logsDetails {
            NSLog("[Ice ModernMenuBar] activation generation=%ld hiddenApps=%ld hiddenSystemItems=%ld", activationGeneration, effective.bundles.count, effective.systemItems.count)
        }
        guard let newAssertion = iceModern_activateAssertion(config, { [weak self] error in
            Task { @MainActor in
                guard let self, self.visibilityLifecycle.handleCallback(generation: activationGeneration) else { return }
                if let error {
                    NSLog("[Ice ModernMenuBar] assertion callback reported error: %@", error.localizedDescription)
                    self.errorMessage = "macOS reported a hiding issue; Ice is verifying the menu bar."
                }
            }
        }) as AnyObject? else {
            visibilityLifecycle.markFailed(message: "Menu bar hiding is unavailable on this macOS build.")
            recordVisibilityFailure(effective, message: "Menu bar hiding is unavailable on this macOS build.")
            return
        }
        assertion = newAssertion
        appliedVisibility = effective
        appliedAllowedBundles = allowed
        awaitingVisibility = true
        visibilityStatus = "Waiting for macOS to confirm menu bar hiding..."
        if let previousAssertion {
            iceModern_invalidateAssertion(previousAssertion)
        }
        Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let snapshot = await self.enumerator.snapshot()
            await MainActor.run {
                self.finishVisibilityVerification(snapshot, generation: activationGeneration, plan: effective)
            }
        }
    }

    private func finishVisibilityVerification(
        _ snapshot: ModernMenuBarSnapshot,
        generation: Int,
        plan: ModernVisibilityPlan,
        allowFailure: Bool = true
    ) {
        guard visibilityLifecycle.generation == generation, awaitingVisibility, appliedVisibility == plan else { return }
        // Retraction is normal, not an assertion failure or an unreadable-AX
        // retry. Keep the assertion and verify on a subsequent visible refresh.
        guard snapshot.isMenuBarPresented else {
            visibilityStatus = "Menu bar hiding is active; verification resumes when the menu bar is shown."
            return
        }
        let result = ModernVisibilityVerifier.verify(plan, in: snapshot)
        if logsDetails {
            diagnosticLogger.info("Verification generation=\(generation) result=\(String(describing: result), privacy: .private)")
            for item in snapshot.verificationItems where plan.conceals(item.id) {
                diagnosticLogger.info("Remaining item \(item.id.bundleID, privacy: .private) frame=\(String(describing: item.frame), privacy: .public)")
            }
        }
        switch visibilityLifecycle.verify(generation: generation, result: result, allowFailure: allowFailure) {
        case .confirmed:
            if logsDetails {
                NSLog("[Ice ModernMenuBar] verified hiding generation=%ld", generation)
            }
            awaitingVisibility = false
            visibilityFailure = nil
            errorMessage = nil
            updateVisibilityStatus(for: plan)
        case .keepWaiting:
            visibilityStatus = "Menu bar hiding is active, but Ice could not verify it yet."
            errorMessage = "Ice could not read a nonempty macOS menu bar snapshot to confirm hiding."
            scheduleVerificationRetry(generation: generation, plan: plan)
        case .activeButUnverified:
            NSLog("[Ice ModernMenuBar] verification unavailable generation=%ld; retaining assertion", generation)
            awaitingVisibility = false
            visibilityStatus = "Menu bar hiding is active, but Ice could not verify it."
            errorMessage = "Ice could not read a complete macOS menu bar snapshot to confirm hiding."
        case .failed(let message):
            awaitingVisibility = false
            iceModern_invalidateAssertion(assertion)
            assertion = nil
            appliedVisibility = ModernVisibilityPlan()
            appliedAllowedBundles = []
            recordVisibilityFailure(plan, message: message)
        case .ignoredStale:
            return
        }
    }

    private func checkActiveVisibility(_ snapshot: ModernMenuBarSnapshot, plan: ModernVisibilityPlan) {
        let result = ModernVisibilityVerifier.verify(plan, in: snapshot)
        if case .stillVisible = result {
            diagnosticLogger.warning("Active hiding changed: \(String(describing: result), privacy: .private)")
        }
        switch visibilityLifecycle.observeActive(result) {
        case .confirmed:
            errorMessage = nil
            updateVisibilityStatus(for: plan)
        case .keepWaiting, .activeButUnverified, .ignoredStale:
            return
        case .failed(let message):
            iceModern_invalidateAssertion(assertion)
            assertion = nil
            appliedVisibility = ModernVisibilityPlan()
            appliedAllowedBundles = []
            recordVisibilityFailure(plan, message: message)
        }
    }

    private func scheduleVerificationRetry(generation: Int, plan: ModernVisibilityPlan) {
        visibilityRetryTask?.cancel()
        visibilityRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let snapshot = await self.enumerator.snapshot()
            await MainActor.run {
                self.finishVisibilityVerification(snapshot, generation: generation, plan: plan)
            }
        }
    }

    private func recordVisibilityFailure(_ plan: ModernVisibilityPlan, message: String) {
        visibilityFailure = ModernVisibilityFailure.record(previous: visibilityFailure, plan: plan, message: message)
        NSLog("[Ice ModernMenuBar] hiding failure attempt=%ld: %@", visibilityFailure?.failureCount ?? 0, message)
        errorMessage = message
        visibilityStatus = visibilityRetryPolicy.delay(afterFailureCount: visibilityFailure?.failureCount ?? 0) == nil
            ? "\(message) Use Retry hiding to try again."
            : "\(message) Ice will retry shortly."
        scheduleAutomaticRetryIfNeeded(for: plan, failureCount: visibilityFailure?.failureCount ?? 0)
    }

    private func scheduleAutomaticRetryIfNeeded(for plan: ModernVisibilityPlan, failureCount: Int) {
        visibilityRetryTask?.cancel()
        guard let delay = visibilityRetryPolicy.delay(afterFailureCount: failureCount) else { return }
        visibilityRetryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.visibilityFailure?.plan == plan else { return }
                self.applyVisibility(forceRetry: true)
            }
        }
    }

    private func updateVisibilityStatus(for plan: ModernVisibilityPlan) {
        if isEditing {
            visibilityStatus = "Menu Bar Layout is showing all items."
        } else if awaitingVisibility {
            visibilityStatus = "Waiting for macOS to confirm menu bar hiding..."
        } else if visibilityLifecycle.isActiveUnverified {
            visibilityStatus = "Menu bar hiding is active, but Ice could not verify it."
        } else if !plan.requiresAssertion {
            visibilityStatus = "No menu bar items are hidden."
        } else {
            visibilityStatus = "Menu bar hiding is active."
        }
    }

    func stop() {
        watchdog.stop()
        timer?.cancel()
        timer = nil
        appLaunchObserver?.cancel()
        appLaunchObserver = nil
        visibilityRetryTask?.cancel()
        visibilityRetryTask = nil
        visibilityLifecycle.markIdle()
        iceModern_invalidateAssertion(assertion)
        assertion = nil
        appliedVisibility = ModernVisibilityPlan()
        appliedAllowedBundles = []
        awaitingVisibility = false
        updateVisibilityStatus(for: ModernVisibilityPlan())
    }

    /// Resolve both endpoints immediately before dragging, then verify the
    /// resulting order. No old window numbers or guessed off-screen targets.
    func move(_ id: ModernItemID, before targetID: ModernItemID) async {
        guard !isMoving, id != targetID else { return }
        // A drop into another section changes visibility even when macOS pins
        // the source's physical position (e.g. system controls).
        if layout.section(for: id) != layout.section(for: targetID),
           let item = items.first(where: { $0.id == id }) {
            assign(item, to: layout.section(for: targetID))
            return
        }
        isMoving = true
        defer { isMoving = false }
        errorMessage = nil
        let fresh = await enumerator.snapshotItems()
            .sorted { $0.frame.minX < $1.frame.minX }
        guard let item = fresh.first(where: { $0.id == id }),
              let target = fresh.first(where: { $0.id == targetID }),
              let display = NSScreen.screens.first(where: {
                  let bounds = CGDisplayBounds($0.displayID)
                  return bounds.contains(item.frame) && bounds.contains(target.frame)
              }),
              item.frame.width > 0, target.frame.width > 0,
              abs(item.frame.midY - target.frame.midY) < 3
        else {
            errorMessage = "Show both items in the same menu bar before moving them. Expand the macOS overflow menu if needed."
            return
        }
        let displayBounds = CGDisplayBounds(display.displayID)
        guard item.frame.minY >= displayBounds.minY, item.frame.maxY <= displayBounds.minY + 80 else {
            errorMessage = "The menu bar is not currently visible."
            return
        }
        let destinationX = item.frame.minX < target.frame.minX ? target.frame.minX + 1 : target.frame.minX - 1
        let from = CGPoint(x: item.frame.midX, y: item.frame.midY)
        let to = CGPoint(x: destinationX, y: target.frame.midY)
        guard await ModernMenuBarMover.drag(from: from, to: to) else {
            errorMessage = "Could not move the item. Check Ice’s Accessibility permission."
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        let after = await enumerator.snapshotItems()
            .sorted { $0.frame.minX < $1.frame.minX }
        items = after.filter { $0.id.bundleID != Constants.bundleIdentifier }
        let beforeVerification = fresh.map { ModernMoveVerificationItem(id: $0.id, midX: $0.frame.midX) }
        let afterVerification = after.map { ModernMoveVerificationItem(id: $0.id, midX: $0.frame.midX) }
        guard ModernMoveVerification.acceptedMoveBefore(id, targetID: targetID, before: beforeVerification, after: afterVerification) else {
            errorMessage = "macOS did not accept this move. The item may be fixed in place."
            return
        }
    }
}

private enum ModernMenuBarMover {
    // Runs outside the main actor so AppKit can continue handling the editor
    // and any status-item tracking loop throughout the physical drag.
    static func drag(from: CGPoint, to: CGPoint) async -> Bool {
        guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let original = CGEvent(source: nil)?.location
        func event(_ type: CGEventType, _ point: CGPoint) -> CGEvent? {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = .maskCommand
            return event
        }
        guard let down = event(.leftMouseDown, from), let up = event(.leftMouseUp, to) else { return false }
        // Wait for the editor's own mouse-up to finish before beginning a new drag.
        try? await Task.sleep(for: .milliseconds(180))
        down.post(tap: .cghidEventTap)
        defer {
            up.post(tap: .cghidEventTap)
            if let original { CGWarpMouseCursorPosition(original) }
        }
        try? await Task.sleep(for: .milliseconds(180))
        let steps = min(32, max(8, Int(abs(to.x - from.x) / 25)))
        for index in 1...steps {
            let fraction = CGFloat(index) / CGFloat(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
            event(.leftMouseDragged, point)?.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(25))
        }
        return true
    }
}

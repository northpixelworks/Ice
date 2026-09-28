//
//  ModernMenuBarManager.swift
//  Ice
//

import Cocoa
import Combine
import OSLog

/// System services the macOS 27 backend reads and drives. Tests substitute
/// fakes so they never read saved assignments or create real assertions.
struct ModernMenuBarEnvironment {
    var canHide: Bool
    var loadLayout: () -> ModernMenuBarLayout
    var saveLayout: (ModernMenuBarLayout) -> Void
    var runningApplications: () -> [ModernRunningApplication]
    /// NSWorkspace posts no launch or termination notification for LSUIElement
    /// apps, which most status-item apps are. Observing the running set does.
    var runningApplicationsChanged: AnyPublisher<Void, Never>
    var makeConfiguration: (_ allowedSystemItems: [NSNumber], _ allowedBundles: [String]) -> AnyObject?
    var activateAssertion: (_ configuration: AnyObject, _ completion: @escaping (Error?) -> Void) -> AnyObject?
    var invalidateAssertion: (AnyObject?) -> Void
    var startsWatchdog: Bool

    static var live: Self {
        Self(
            canHide: iceModern_assessmentModeAvailable(),
            loadLayout: {
                Defaults.data(forKey: .modernMenuBarLayout)
                    .flatMap { try? JSONDecoder().decode(ModernMenuBarLayout.self, from: $0) } ?? .init()
            },
            saveLayout: { layout in
                if let data = try? JSONEncoder().encode(layout) {
                    Defaults.set(data, forKey: .modernMenuBarLayout)
                }
            },
            runningApplications: {
                NSWorkspace.shared.runningApplications.compactMap { app in
                    app.bundleIdentifier.map {
                        ModernRunningApplication(bundleID: $0, canOwnStatusItem: app.activationPolicy != .prohibited)
                    }
                }
            },
            runningApplicationsChanged: NSWorkspace.shared.publisher(for: \.runningApplications, options: [.new])
                .map { _ in () }
                .eraseToAnyPublisher(),
            makeConfiguration: { iceModern_makeConfiguration($0, $1) as AnyObject? },
            activateAssertion: { iceModern_activateAssertion($0, $1) as AnyObject? },
            invalidateAssertion: { iceModern_invalidateAssertion($0) },
            startsWatchdog: true
        )
    }
}

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

    let canHide: Bool
    private let environment: ModernMenuBarEnvironment
    private let enumerator = ModernItemEnumerator()
    private let snapshotOverride: (@Sendable () async -> ModernMenuBarSnapshot)?
    private var refreshTask: Task<Void, Never>?
    private var refreshEpoch = 0
    private var refreshPending = false
    private var suspensionReasons = Set<Notification.Name>()
    private let occupancyEnumerator = ModernItemEnumerator()
    private var timer: AnyCancellable?
    private var verificationTask: Task<Void, Never>?
    private var workspaceObservers = Set<AnyCancellable>()
    private var isSuspended = false
    private var axObserver: AXObserver?
    private var observedAgentPID: pid_t = 0
    private static let axChanged = Notification.Name("IceModernAXChanged")
    private var assertion: AnyObject?
    private var appliedVisibility = ModernVisibilityPlan()
    private var appliedAllowedBundles = Set<String>()
    /// Every bundle any assertion allowed since setup; see `candidateBundles`.
    private var retainedAllowedBundles = Set<String>()
    private var visibilityFailure: ModernVisibilityFailure?
    private let visibilityRetryPolicy = ModernVisibilityRetryPolicy()
    private var visibilityRetryTask: Task<Void, Never>?
    private var awaitingVisibility = false
    private var visibilityActivatedAt: TimeInterval = 0
    private var visibilityLifecycle = ModernVisibilityLifecycle()
    private var lastObservedIDs = Set<ModernItemID>()
    private lazy var watchdog = ModernMenuBarWatchdog { [weak self] in
        guard let self else { return false }
        return !self.isSuspended && !self.isEditing && !self.isMoving
    }

    init(
        snapshotOverride: (@Sendable () async -> ModernMenuBarSnapshot)? = nil,
        environment: ModernMenuBarEnvironment = .live
    ) {
        self.snapshotOverride = snapshotOverride
        self.environment = environment
        canHide = environment.canHide
        layout = environment.loadLayout()
    }

    func performSetup() {
        guard timer == nil else { return }
        if environment.startsWatchdog { watchdog.start() }
        isSuspended = !suspensionReasons.isEmpty
        NotificationCenter.default.publisher(for: Self.axChanged)
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.requestRefresh() }
            .store(in: &workspaceObservers)
        timer = Timer.publish(every: 20, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.requestRefresh() }
        let center = NSWorkspace.shared.notificationCenter
        let suspensionNotifications = [
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)
        ]
        for (suspend, resume) in suspensionNotifications {
            center.publisher(for: suspend).receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                suspensionReasons.insert(suspend)
                isSuspended = true
                refreshEpoch += 1
                refreshTask?.cancel()
                removeAXObserver()
                verificationTask?.cancel()
                visibilityRetryTask?.cancel()
                NSLog("[Ice ModernAX] suspended: %@", suspend.rawValue)
            }.store(in: &workspaceObservers)
            center.publisher(for: resume).receive(on: DispatchQueue.main).sink { [weak self] _ in
                guard let self else { return }
                suspensionReasons.remove(suspend)
                isSuspended = !suspensionReasons.isEmpty
                if !isSuspended {
                    NSLog("[Ice ModernAX] resumed: %@", resume.rawValue)
                    requestRefresh()
                }
            }.store(in: &workspaceObservers)
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.requestRefresh()
            }.store(in: &workspaceObservers)
        }
        // A short debounce folds a burst of launches into one reactivation
        // while keeping a new app's items hidden for well under a second.
        environment.runningApplicationsChanged
            .receive(on: DispatchQueue.main)
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.runningApplicationsDidChange() }
            .store(in: &workspaceObservers)
        requestRefresh()
    }

    /// Allows newly launched status-item apps without an AX snapshot. Hidden
    /// items never appear in a snapshot, so waiting for one cannot work.
    private func runningApplicationsDidChange() {
        guard !isSuspended else { return }
        guard !isMoving else {
            refreshPending = true
            return
        }
        guard applyVisibility() else { return }
        requestRefresh()
    }

    private func requestRefresh() {
        guard !isSuspended else { return }
        guard !isRefreshing, !isMoving else {
            refreshPending = true
            return
        }
        refreshPending = false
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }

    func refresh() async {
        guard !isSuspended, !isRefreshing, !isMoving else { return }
        if snapshotOverride == nil { installAXObserverIfNeeded() }
        isRefreshing = true
        defer {
            isRefreshing = false
            if refreshPending { requestRefresh() }
        }
        let generation = visibilityLifecycle.generation
        let plan = appliedVisibility
        let epoch = refreshEpoch
        let snapshot = await takeSnapshot()
        guard !Task.isCancelled, !isSuspended, epoch == refreshEpoch,
              generation == visibilityLifecycle.generation, plan == appliedVisibility else { return }
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
            finishVisibilityVerification(snapshot, generation: generation, plan: plan, allowFailure: false)
        } else if assertion != nil, appliedVisibility.requiresAssertion, !isEditing {
            checkActiveVisibility(snapshot, plan: appliedVisibility)
        }
        applyVisibility()
    }

    /// Refresh, verification, and retry all read through the same source.
    private func takeSnapshot() async -> ModernMenuBarSnapshot {
        if let snapshotOverride { return await snapshotOverride() }
        return await enumerator.snapshot()
    }

    private func updateKnownItems(from snapshot: ModernMenuBarSnapshot) {
        guard snapshot.isReadable, !snapshot.items.isEmpty else { return }
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
        guard !isSuspended else { return false }
        let epoch = refreshEpoch
        let visibilityGeneration = visibilityLifecycle.generation
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let snapshot = await occupancyEnumerator.snapshotOccupancy(
            at: point,
            deadline: requestedAt + ModernMenuBarOccupancy.maximumSnapshotDuration
        )
        guard !Task.isCancelled, !isSuspended, epoch == refreshEpoch,
              visibilityLifecycle.generation == visibilityGeneration else { return false }
        return snapshot.confirmsEmptySpace(
            at: point, requestedAt: requestedAt, now: ProcessInfo.processInfo.systemUptime
        )
    }

    func beginEditing() {
        isEditing = true
        visibilityFailure = nil
        applyVisibility()
        requestRefresh()
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
        requestRefresh()
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
        requestRefresh()
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
        environment.saveLayout(layout)
        applyVisibility()
    }

    func items(in section: ModernMenuBarLayout.Section) -> [ModernMenuBarItem] {
        items.filter { layout.section(for: $0.id) == section }
    }

    func isConcealed(_ item: ModernMenuBarItem) -> Bool {
        appliedVisibility.conceals(item.id)
    }

    func visibilityReality(for section: ModernMenuBarLayout.Section) -> (requested: Int, stillVisible: Int, concealed: Int) {
        let runningBundles = Set(environment.runningApplications().map(\.bundleID))
        let requestedPlan = layout.visibilityPlan(
            revealing: isEditing ? Set(ModernMenuBarLayout.Section.allCases) : revealed,
            runningBundles: runningBundles,
            ownBundle: Constants.bundleIdentifier
        )
        let requested = items.filter { layout.section(for: $0.id) == section && requestedPlan.conceals($0.id) }
        let stillVisible = requested.filter { lastObservedIDs.contains($0.id) }
        return (requested.count, stillVisible.count, max(0, requested.count - stillVisible.count))
    }

    /// Returns true when the assertion was replaced or released.
    @discardableResult
    private func applyVisibility(forceRetry: Bool = false) -> Bool {
        let running = environment.runningApplications()
        let runningBundles = Set(running.map(\.bundleID))
        let revealing = isEditing ? Set(ModernMenuBarLayout.Section.allCases) : revealed
        let effective = layout.visibilityPlan(
            revealing: revealing,
            runningBundles: runningBundles,
            ownBundle: Constants.bundleIdentifier
        )
        let allowed = effective.allowedBundles(
            runningBundles: ModernAllowlistReapply.candidateBundles(
                running: runningBundles,
                previouslyAllowed: retainedAllowedBundles,
                concealedAssignments: layout.concealedBundles(revealing: revealing)
            ),
            ownBundle: Constants.bundleIdentifier
        )
        if let failure = visibilityFailure, failure.plan == effective, !forceRetry {
            visibilityStatus = failure.canRetryAutomatically
                ? "Menu bar hiding is waiting to retry."
                : "Menu bar hiding needs a retry."
            return false
        }
        // Compare against running applications, never observed items: the
        // assertion hides an unlisted app, so its item never gets observed.
        let missingBundles = ModernAllowlistReapply.missingBundles(
            allowed: allowed,
            applied: appliedAllowedBundles,
            running: running
        )
        if !forceRetry,
           effective == appliedVisibility,
           !effective.requiresAssertion || missingBundles.isEmpty,
           assertion != nil || !effective.requiresAssertion {
            updateVisibilityStatus(for: effective)
            return false
        }
        if effective == appliedVisibility, assertion != nil, !missingBundles.isEmpty {
            NSLog("[Ice ModernMenuBar] reapplying allowlist for %ld newly running application(s)", missingBundles.count)
            diagnosticLogger.info("Allowlist adds \(missingBundles.sorted().joined(separator: ","), privacy: .private)")
        }
        visibilityLifecycle.markIdle()
        verificationTask?.cancel()
        visibilityRetryTask?.cancel()
        let previousAssertion = assertion
        awaitingVisibility = false
        guard effective.requiresAssertion else {
            environment.invalidateAssertion(previousAssertion)
            assertion = nil
            appliedVisibility = ModernVisibilityPlan()
            appliedAllowedBundles = []
            visibilityFailure = nil
            updateVisibilityStatus(for: effective)
            return true
        }
        guard canHide else {
            errorMessage = "Menu bar hiding is unavailable on this macOS build."
            visibilityStatus = "Menu bar hiding is unavailable on this macOS build."
            return false
        }
        // Include every running bundle, not only AX-visible apps, plus visible
        // bundles allowed earlier. Anything unlisted is hidden by macOS.
        guard let config = environment.makeConfiguration(effective.allowedSystemItems.map { NSNumber(value: $0.rawValue) }, Array(allowed)) else {
            recordVisibilityFailure(effective, message: "macOS could not prepare menu bar hiding.")
            return false
        }
        let activationGeneration = visibilityLifecycle.beginActivation()
        NSLog("[Ice ModernMenuBar] activation generation=%ld hiddenApps=%ld hiddenSystemItems=%ld allowedApps=%ld", activationGeneration, effective.bundles.count, effective.systemItems.count, allowed.count)
        guard let newAssertion = environment.activateAssertion(config, { [weak self] error in
            Task { @MainActor in
                guard let self, self.visibilityLifecycle.handleCallback(generation: activationGeneration) else { return }
                if let error {
                    NSLog("[Ice ModernMenuBar] assertion callback reported error: %@", error.localizedDescription)
                    self.errorMessage = "macOS reported a hiding issue; Ice is verifying the menu bar."
                }
            }
        }) else {
            visibilityLifecycle.markFailed(message: "Menu bar hiding is unavailable on this macOS build.")
            recordVisibilityFailure(effective, message: "Menu bar hiding is unavailable on this macOS build.")
            return false
        }
        assertion = newAssertion
        appliedVisibility = effective
        appliedAllowedBundles = allowed
        retainedAllowedBundles.formUnion(allowed)
        awaitingVisibility = true
        visibilityActivatedAt = ProcessInfo.processInfo.systemUptime
        visibilityStatus = "Waiting for macOS to confirm menu bar hiding..."
        if let previousAssertion {
            environment.invalidateAssertion(previousAssertion)
        }
        verificationTask?.cancel()
        verificationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            let snapshot = await self.takeSnapshot()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.finishVisibilityVerification(snapshot, generation: activationGeneration, plan: effective)
            }
        }
        return true
    }

    private func finishVisibilityVerification(
        _ snapshot: ModernMenuBarSnapshot,
        generation: Int,
        plan: ModernVisibilityPlan,
        allowFailure: Bool = true
    ) {
        guard !isSuspended, visibilityLifecycle.generation == generation, awaitingVisibility, appliedVisibility == plan else { return }
        // Retraction is normal, not an assertion failure or an unreadable-AX
        // retry. Keep the assertion and verify on a subsequent visible refresh.
        guard snapshot.isMenuBarPresented else {
            visibilityStatus = "Menu bar hiding is active; verification resumes when the menu bar is shown."
            return
        }
        let result = ModernVisibilityVerifier.verify(plan, in: snapshot)
        diagnosticLogger.info("Verification generation=\(generation) result=\(String(describing: result), privacy: .private)")
        for item in snapshot.verificationItems where plan.conceals(item.id) {
            diagnosticLogger.info("Remaining item \(item.id.bundleID, privacy: .private) frame=\(String(describing: item.frame), privacy: .public)")
        }
        switch visibilityLifecycle.verify(generation: generation, result: result, allowFailure: allowFailure && ProcessInfo.processInfo.systemUptime - visibilityActivatedAt >= 3) {
        case .confirmed:
            NSLog("[Ice ModernMenuBar] verified hiding generation=%ld", generation)
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
            environment.invalidateAssertion(assertion)
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
            environment.invalidateAssertion(assertion)
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
            let snapshot = await self.takeSnapshot()
            guard !Task.isCancelled else { return }
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

    private func removeAXObserver() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        }
        axObserver = nil
        observedAgentPID = 0
    }

    private func installAXObserverIfNeeded() {
        guard !isSuspended, let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.MenuBarAgent"
        }) else { return }
        guard axObserver == nil || observedAgentPID != agent.processIdentifier else { return }
        removeAXObserver()
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, _ in
            NotificationCenter.default.post(name: Notification.Name("IceModernAXChanged"), object: nil)
        }
        guard AXObserverCreate(agent.processIdentifier, callback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.2)
        // Notification support varies by macOS build; polling remains a backstop.
        for name in [kAXCreatedNotification, kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification] {
            AXObserverAddNotification(observer, element, name as CFString, nil)
        }
        axObserver = observer
        observedAgentPID = agent.processIdentifier
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    func stop() {
        watchdog.stop()
        timer?.cancel()
        timer = nil
        isSuspended = true
        refreshEpoch += 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshPending = false
        workspaceObservers.removeAll()
        removeAXObserver()
        verificationTask?.cancel()
        verificationTask = nil
        visibilityRetryTask?.cancel()
        visibilityRetryTask = nil
        visibilityLifecycle.markIdle()
        environment.invalidateAssertion(assertion)
        assertion = nil
        appliedVisibility = ModernVisibilityPlan()
        appliedAllowedBundles = []
        retainedAllowedBundles = []
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
        defer {
            isMoving = false
            if refreshPending { requestRefresh() }
        }
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
        let snapshot = await enumerator.snapshot()
        let after = snapshot.items.sorted { $0.frame.minX < $1.frame.minX }
        updateKnownItems(from: snapshot)
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

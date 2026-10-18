//
//  AppState.swift
//  Ice
//

import Combine
import OSLog
import SwiftUI

/// The model for app-wide state.
@MainActor
final class AppState: ObservableObject {
    /// Information for the active space.
    @Published private(set) var activeSpace = SpaceInfo.activeSpace()

    /// A Boolean value that indicates whether the user is dragging a menu bar item.
    @Published private(set) var isDraggingMenuBarItem = false

    /// Model for the app's settings.
    let settings = AppSettings()

    /// Model for the app's permissions.
    let permissions = AppPermissions()

    /// Model for app-wide navigation.
    let navigationState = AppNavigationState()

    /// Manager for the state of the menu bar.
    let menuBarManager = MenuBarManager()

    /// Manager for the menu bar's appearance.
    let appearanceManager = MenuBarAppearanceManager()

    /// Manager for menu bar item spacing.
    let spacingManager = MenuBarItemSpacingManager()

    /// Manager for menu bar items.
    let itemManager = MenuBarItemManager()

    /// Manager for scene-based menu bar items on macOS 27.
    let modernMenuBarManager = ModernMenuBarManager()

    /// Global cache for menu bar item images.
    let imageCache = MenuBarItemImageCache()

    /// Manager for events received by the app.
    let eventManager = EventManager()

    /// Manager for app updates.
    let updatesManager = UpdatesManager()

    /// Manager for user notifications.
    let userNotificationManager = UserNotificationManager()

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// The window that contains the settings interface.
    private weak var settingsWindow: NSWindow?

    /// The window that contains the permissions interface.
    private weak var permissionsWindow: NSWindow?

    /// Scene-bound window action used for reliable SwiftUI window presentation.
    private var openWindowAction: OpenWindowAction?

    /// Scene-bound window action used for reliable SwiftUI window dismissal.
    private var dismissWindowAction: DismissWindowAction?

    /// The window currently waiting for SwiftUI to create or reattach its NSWindow.
    private var pendingWindowID: IceWindowIdentifier?

    /// Logger for the app state.
    private let logger = Logger(category: "AppState")

    /// Async setup actions, run once on first access.
    private lazy var setupTask = Task {
        permissions.stopAllChecks()

        settings.performSetup(with: self)
        menuBarManager.performSetup(with: self)

        if #available(macOS 27.0, *) {
            modernMenuBarManager.performSetup()
        } else if #available(macOS 26.0, *) {
            await MenuBarItemService.Connection.shared.start()
        }

        appearanceManager.performSetup(with: self)
        eventManager.performSetup(with: self)
        // MenuBarAgent no longer exposes the individual CG windows that the
        // legacy item manager and image cache depend on, starting with macOS 27.
        if #unavailable(macOS 27.0) {
            await itemManager.performSetup(with: self)
            imageCache.performSetup(with: self)
        }
        updatesManager.performSetup(with: self)
        userNotificationManager.performSetup(with: self)

        configureCancellables()
    }

    /// Performs app state setup.
    ///
    /// - Parameter hasPermissions: If `true`, continues with setup normally.
    ///   If `false`, prompts the user to grant permissions.
    func performSetup(hasPermissions: Bool) {
        if hasPermissions {
            Task {
                logger.debug("Setting up app state")
                await setupTask.value
                logger.debug("Finished setting up app state")
            }
        } else {
            Task {
                // Delay to prevent conflicts with the app delegate.
                try? await Task.sleep(for: .milliseconds(100))
                activate(withPolicy: .regular)
                dismissWindow(.settings) // Shouldn't be open anyway.
                openWindow(.permissions)
            }
        }
    }

    /// A settings window can be reopened before permission-gated setup has run.
    /// Retrying access must complete that setup before asking managers to refresh.
    func retryPermissionSetup() async -> Bool {
        guard permissions.recheckPermissions() else { return false }
        await setupTask.value
        return true
    }

    /// Configures the internal observers for the app state.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        // Listen for changes to the active space. We need handle some special
        // cases that NSWorkspace.shared.notificationCenter seems to miss.
        //
        // Special cases:
        //
        // * Changes to the frontmost application -- may indicate that a space
        //   on another display was made active.
        // * Left mouse down -- user may have clicked into a fullscreen space.
        //   To account for variations in system timing, we publish a value
        //   immediately upon receipt of the event, then publish another value
        //   after a delay.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .discardMerge(NSWorkspace.shared.publisher(for: \.frontmostApplication))
            .discardMerge(EventMonitor.publish(events: .leftMouseDown, scope: .universal).flatMap { _ in
                let initial = Just(())
                let delayed = initial.delay(for: 0.1, scheduler: DispatchQueue.main)
                return Publishers.Merge(initial, delayed)
            })
            .replace { Bridging.getActiveSpaceID() }
            .removeDuplicates()
            .sink { [weak self] spaceID in
                self?.activeSpace = SpaceInfo(spaceID: spaceID)
            }
            .store(in: &c)

        NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .receive(on: DispatchQueue.main)
            .map { $0 == .current }
            .removeDuplicates()
            .sink { [weak self] isFrontmost in
                self?.navigationState.isAppFrontmost = isFrontmost
            }
            .store(in: &c)

        publisherForWindow(.settings)
            .removeNil()
            .flatMap { $0.publisher(for: \.isVisible) }
            .replaceEmpty(with: false)
            .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
            .removeDuplicates()
            .sink { [weak self] isPresented in
                self?.navigationState.isSettingsPresented = isPresented
            }
            .store(in: &c)

        eventManager.$isDraggingMenuBarItem
            .removeDuplicates()
            .sink { [weak self] isDragging in
                self?.isDraggingMenuBarItem = isDragging
            }
            .store(in: &c)

        Publishers.CombineLatest(
            navigationState.$isAppFrontmost,
            navigationState.$isSettingsPresented
        )
        .map { $0 && $1 }
        .throttle(for: 0.1, scheduler: DispatchQueue.main, latest: true)
        .merge(with: Just(true).delay(for: 1, scheduler: DispatchQueue.main))
        .sink { [weak self] shouldUpdate in
            guard let self, shouldUpdate else {
                return
            }
            Task {
                if #available(macOS 27.0, *) {
                    return
                }
                await self.imageCache.updateCacheWithoutChecks(sections: MenuBarSection.Name.allCases)
            }
        }
        .store(in: &c)

        menuBarManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        permissions.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        settings.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)
        updatesManager.objectWillChange
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns a Boolean value indicating whether the app has been
    /// granted the permission associated with the given key.
    func hasPermission(_ key: AppPermissions.PermissionKey) -> Bool {
        switch key {
        case .accessibility:
            permissions.accessibility.hasPermission
        case .screenRecording:
            permissions.screenRecording.hasPermission
        }
    }

    /// Returns a publisher for the window with the given identifier.
    func publisherForWindow(_ id: IceWindowIdentifier) -> some Publisher<NSWindow?, Never> {
        NSApp.publisher(for: \.windows).mergeMap { window in
            window.publisher(for: \.identifier)
                .map { [weak window] identifier in
                    guard identifier?.rawValue == id.rawValue else {
                        return nil
                    }
                    return window
                }
                .first { $0 != nil }
                .replaceEmpty(with: nil)
        }
    }

    /// Assigns a SwiftUI-created window to the app state.
    func assignWindow(_ window: NSWindow, id: IceWindowIdentifier) {
        guard window.identifier?.rawValue == id.rawValue else {
            logger.warning("Window \(window.identifier?.rawValue ?? "<NIL>", privacy: .public) is not \(id.rawValue, privacy: .public)")
            return
        }

        switch id {
        case .settings:
            settingsWindow = window
        case .permissions:
            permissionsWindow = window
        }

        finishPendingPresentation(window, id: id)
    }

    /// Actions must come from a live SwiftUI scene; a new EnvironmentValues
    /// instance has no reliable connection to the app's window lifecycle.
    func assignWindowActions(open: OpenWindowAction, dismiss: DismissWindowAction) {
        openWindowAction = open
        dismissWindowAction = dismiss

        if let pendingWindowID {
            DispatchQueue.main.async { [weak self] in
                guard self?.pendingWindowID == pendingWindowID else {
                    return
                }
                self?.logger.debug("Retrying pending window open for id: \(pendingWindowID, privacy: .public)")
                open(id: pendingWindowID)
            }
        }
    }

    /// Opens the window with the given identifier.
    func openWindow(_ id: IceWindowIdentifier) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            logger.debug("Opening window with id: \(id, privacy: .public)")
            presentWindow(id)
        }
    }

    /// Dismisses the window with the given identifier.
    func dismissWindow(_ id: IceWindowIdentifier) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            logger.debug("Dismissing window with id: \(id, privacy: .public)")
            window(for: id)?.orderOut(nil)
            dismissWindowAction?(id: id)
        }
    }

    private func presentWindow(_ id: IceWindowIdentifier) {
        pendingWindowID = id
        if let window = window(for: id) ?? NSApp.windows.first(where: { $0.identifier?.rawValue == id.rawValue }) {
            finishPendingPresentation(window, id: id)
        } else {
            openWindowAction?(id: id)
        }
    }

    private func window(for id: IceWindowIdentifier) -> NSWindow? {
        switch id {
        case .settings:
            settingsWindow
        case .permissions:
            permissionsWindow
        }
    }

    private func finishPendingPresentation(_ window: NSWindow, id: IceWindowIdentifier) {
        guard pendingWindowID == id else {
            return
        }
        pendingWindowID = nil

        // Menu tracking and SwiftUI's window attachment must finish before
        // activation. Native ordering also restores a closed/minimized window.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else {
                return
            }
            self.activate(withPolicy: .regular)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            let behavior = window.collectionBehavior
            if !behavior.contains(.canJoinAllSpaces) {
                window.collectionBehavior.insert(.moveToActiveSpace)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            window.collectionBehavior = behavior
        }
    }

    /// Activates the app and sets its activation policy.
    func activate(withPolicy policy: NSApplication.ActivationPolicy? = nil) {
        if let policy {
            NSApp.setActivationPolicy(policy)
        }
        if #available(macOS 27.0, *) {
            NSApp.activate()
            return
        }
        // NSApplication.activate(ignoringOtherApps:) is deprecated, with
        // no suitable alternative for explicit activation, so we activate
        // through NSRunningApplication.current for now.
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            NSRunningApplication.current.activate()
            return
        }
        NSRunningApplication.current.activate(from: frontmost)
    }

    /// Deactivates the app and sets its activation policy.
    func deactivate(withPolicy policy: NSApplication.ActivationPolicy? = nil) {
        if let policy {
            NSApp.setActivationPolicy(policy)
        }
        NSApp.deactivate()
    }
}

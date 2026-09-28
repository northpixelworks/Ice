//
//  EventManager.swift
//  Ice
//

import Cocoa
import Combine

/// Manager for the various event monitors maintained by the app.
@MainActor
final class EventManager: ObservableObject {
    /// A Boolean value that indicates whether the user is dragging a menu bar item.
    @Published private(set) var isDraggingMenuBarItem = false

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    private var modernInteractionGeneration: UInt64 = 0
    private var modernEmptySpaceTask: Task<Void, Never>?
    private var modernIntentIsHover = false
    private var rehideTask: Task<Void, Never>?

    // MARK: Monitors

    /// Monitor for mouse down events.
    private(set) lazy var mouseDownMonitor = EventMonitor.universal(
        for: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] event in
        guard let self, let appState, let screen = bestScreen(appState: appState) else {
            return event
        }
        cancelModernEmptySpaceAction()
        switch event.type {
        case .leftMouseDown:
            handleShowOnClick(appState: appState, screen: screen)
            handleSmartRehide(with: event, appState: appState, screen: screen)
        case .rightMouseDown:
            handleShowSecondaryContextMenu(appState: appState, screen: screen)
        default:
            return event
        }
        handlePreventShowOnHover(with: event, appState: appState, screen: screen)
        return event
    }

    /// Monitor for mouse up events.
    private(set) lazy var mouseUpMonitor = EventMonitor.universal(
        for: .leftMouseUp
    ) { [weak self] event in
        self?.handleLeftMouseUp()
        return event
    }

    /// Monitor for mouse dragged events.
    private(set) lazy var mouseDraggedMonitor = EventMonitor.universal(
        for: .leftMouseDragged
    ) { [weak self] event in
        if let self, let appState, let screen = bestScreen(appState: appState) {
            cancelModernEmptySpaceAction()
            handleLeftMouseDragged(with: event, appState: appState, screen: screen)
        }
        return event
    }

    /// Tap for mouse moved events.
    private(set) lazy var mouseMovedTap = EventTap(
        type: .mouseMoved,
        location: .hidEventTap,
        placement: .tailAppendEventTap,
        option: .listenOnly
    ) { [weak self] _, event in
        if let self, let appState, let screen = bestScreen(appState: appState) {
            if modernIntentIsHover { cancelModernEmptySpaceAction() }
            handleShowOnHover(appState: appState, screen: screen)
        }
        return event
    }

    /// Monitor for scroll wheel events.
    private(set) lazy var scrollWheelMonitor = EventMonitor.universal(
        for: .scrollWheel
    ) { [weak self] event in
        if let self, let appState, let screen = bestScreen(appState: appState) {
            cancelModernEmptySpaceAction()
            handleShowOnScroll(with: event, appState: appState, screen: screen)
        }
        return event
    }

    // MARK: All Monitors

    /// All monitors maintained by the manager.
    private lazy var allMonitors: [any EventMonitorProtocol] = [
        mouseDownMonitor,
        mouseUpMonitor,
        mouseDraggedMonitor,
        mouseMovedTap,
        scrollWheelMonitor,
    ]

    // MARK: Setup

    /// Sets up the manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        startAll()
        configureCancellables()
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        if let appState, let hiddenSection = appState.menuBarManager.section(withName: .hidden) {
            // In fullscreen mode, the menu bar slides down from the top on hover. Observe the
            // frame of the hidden section's control item, which we know will always be in the
            // menu bar, and run the show-on-hover check when it changes.
            Publishers.CombineLatest3(
                hiddenSection.controlItem.$frame,
                appState.$activeSpace.map(\.isFullscreen),
                appState.menuBarManager.$isMenuBarHiddenBySystem
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak appState] _, isFullscreen, isMenuBarHiddenBySystem in
                guard let self, let appState, isFullscreen || isMenuBarHiddenBySystem else {
                    return
                }
                if let screen = bestScreen(appState: appState) {
                    handleShowOnHover(appState: appState, screen: screen)
                }
            }
            .store(in: &c)
        }

        cancellables = c
    }

    // MARK: Start/Stop

    /// Starts all monitors.
    func startAll() {
        for monitor in allMonitors {
            monitor.start()
        }
    }

    /// Stops all monitors.
    func stopAll() {
        rehideTask?.cancel()
        rehideTask = nil
        cancelModernEmptySpaceAction()
        for monitor in allMonitors {
            monitor.stop()
        }
    }
}

// MARK: - Handler Methods

extension EventManager {

    // MARK: Handle Show On Click

    private func handleShowOnClick(appState: AppState, screen: NSScreen) {
        if #available(macOS 27, *) {
            guard appState.settings.general.showOnClick else { return }
            let modifiers = NSEvent.modifierFlags
            if modifiers == .control {
                handleShowSecondaryContextMenu(appState: appState, screen: screen)
                return
            }
            let section: MenuBarSection?
            if modifiers == .option, appState.settings.advanced.canToggleAlwaysHiddenSection,
               let alwaysHidden = appState.menuBarManager.section(withName: .alwaysHidden), alwaysHidden.isEnabled {
                section = alwaysHidden
            } else {
                section = appState.menuBarManager.section(withName: .hidden)
            }
            guard let section, section.isEnabled else { return }
            let wasHidden = section.isHidden
            scheduleModernEmptySpaceAction(appState: appState, screen: screen, delay: 0.05) {
                guard appState.settings.general.showOnClick, section.isEnabled, section.isHidden == wasHidden else { return }
                section.toggle()
            }
            return
        }
        guard
            appState.settings.general.showOnClick,
            isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen)
        else {
            return
        }

        Task {
            // Short delay helps the toggle action feel more natural.
            try await Task.sleep(for: .milliseconds(50))

            if NSEvent.modifierFlags == .control {
                handleShowSecondaryContextMenu(appState: appState, screen: screen)
                return
            }

            let targetSection: MenuBarSection

            if
                NSEvent.modifierFlags == .option,
                appState.settings.advanced.canToggleAlwaysHiddenSection,
                let alwaysHiddenSection = appState.menuBarManager.section(withName: .alwaysHidden),
                alwaysHiddenSection.isEnabled
            {
                targetSection = alwaysHiddenSection
            } else if
                let hiddenSection = appState.menuBarManager.section(withName: .hidden),
                hiddenSection.isEnabled
            {
                targetSection = hiddenSection
            } else {
                return
            }

            targetSection.toggle()
        }
    }

    // MARK: Handle Smart Rehide

    private func handleSmartRehide(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            appState.settings.general.autoRehide,
            case .smart = appState.settings.general.rehideStrategy
        else {
            return
        }

        // Make sure clicking the Ice icon doesn't trigger rehide.
        if let iceIcon = appState.menuBarManager.controlItem(withName: .visible) {
            guard event.window !== iceIcon.window else {
                return
            }
        }

        // Make sure clicking the Ice Bar doesn't trigger rehide.
        guard event.window !== appState.menuBarManager.iceBarPanel else {
            return
        }

        // Only continue if at least one section is visible.
        guard appState.menuBarManager.hasVisibleSection else {
            return
        }

        // Make sure the mouse is not in the menu bar.
        guard !isMouseInsideMenuBar(appState: appState, screen: screen) else {
            return
        }

        let initialSpaceID = Bridging.getActiveSpaceID()

        Task {
            // Wait for a bit to give the window under the mouse a chance to focus.
            try await Task.sleep(for: .milliseconds(250))

            guard
                appState.settings.general.autoRehide,
                case .smart = appState.settings.general.rehideStrategy
            else {
                return
            }

            // If clicking caused a space change, don't bother with the window check.
            if Bridging.getActiveSpaceID() != initialSpaceID {
                for section in appState.menuBarManager.sections {
                    section.hide()
                }
                return
            }

            // Get the window that the user has clicked into. Titles need Screen
            // Recording, so limited mode falls back to owner and layer data.
            guard let mouseLocation = MouseHelpers.locationCoreGraphics else {
                return
            }
            let windows = WindowInfo.createWindows(option: .onScreen).map(SmartRehidePolicy.Window.init)
            let titlesAvailable = SmartRehidePolicy.titlesAvailable(
                permissionGranted: ScreenCapture.checkPermissions(),
                windows: windows,
                ownPID: ProcessInfo.processInfo.processIdentifier
            )
            guard let target = SmartRehidePolicy.clickedWindow(
                in: windows,
                at: mouseLocation,
                titlesAvailable: titlesAvailable,
                maximumLayer: Int(CGWindowLevelForKey(.cursorWindow)),
                owner: SmartRehidePolicy.Owner.init(pid:)
            ) else {
                NSLog("[Ice SmartRehide] no clicked window found titlesAvailable=%d windows=%ld", titlesAvailable ? 1 : 0, windows.count)
                return
            }

            // Only continue if the user has clicked into an active window with a
            // regular activation policy. The Dock is an exception.
            let shouldRehide = SmartRehidePolicy.shouldRehide(owner: target.owner)
            NSLog(
                "[Ice SmartRehide] titlesAvailable=%d layer=%ld policy=%ld active=%d dock=%d rehide=%d",
                titlesAvailable ? 1 : 0,
                target.window.layer,
                target.owner.activationPolicy.rawValue,
                target.owner.isActive ? 1 : 0,
                target.owner.bundleIdentifier == SmartRehidePolicy.dockBundleIdentifier ? 1 : 0,
                shouldRehide ? 1 : 0
            )
            guard shouldRehide else {
                return
            }

            // All checks have passed, so hide the sections.
            for section in appState.menuBarManager.sections {
                section.hide()
            }
        }
    }

    // MARK: Handle Show Secondary Context Menu

    private func handleShowSecondaryContextMenu(appState: AppState, screen: NSScreen) {
        if #available(macOS 27, *) {
            guard appState.settings.advanced.enableSecondaryContextMenu else { return }
            scheduleModernEmptySpaceAction(appState: appState, screen: screen, delay: 0.1) {
                guard appState.settings.advanced.enableSecondaryContextMenu,
                      let location = MouseHelpers.locationAppKit else { return }
                appState.menuBarManager.showSecondaryContextMenu(at: location)
            }
            return
        }
        Task {
            guard
                appState.settings.advanced.enableSecondaryContextMenu,
                isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen),
                let mouseLocation = MouseHelpers.locationAppKit
            else {
                return
            }
            // This delay prevents the menu from immediately closing.
            try await Task.sleep(for: .milliseconds(100))
            appState.menuBarManager.showSecondaryContextMenu(at: mouseLocation)
        }
    }

    // MARK: Handle Prevent Show On Hover

    private func handlePreventShowOnHover(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            appState.settings.general.showOnHover,
            !appState.settings.general.useIceBar
        else {
            return
        }

        guard isMouseInsideMenuBar(appState: appState, screen: screen) else {
            return
        }

        if isMouseInsideMenuBarItem(appState: appState, screen: screen) {
            switch event.type {
            case .leftMouseDown:
                if appState.menuBarManager.hasVisibleSection {
                    break
                }
                if isMouseInsideIceIcon(appState: appState) {
                    break
                }
                return
            case .rightMouseDown:
                if appState.menuBarManager.hasVisibleSection {
                    break
                }
                return
            default:
                return
            }
        } else if isMouseInsideApplicationMenu(appState: appState, screen: screen) {
            return
        }

        // Mouse is inside the menu bar, outside an item or application
        // menu, so it must be inside an empty menu bar space.
        appState.menuBarManager.showOnHoverAllowed = false
    }

    // MARK: Handle Left Mouse Up

    private func handleLeftMouseUp() {
        isDraggingMenuBarItem = false
    }

    // MARK: Handle Left Mouse Dragged

    private func handleLeftMouseDragged(with event: NSEvent, appState: AppState, screen: NSScreen) {
        guard
            event.modifierFlags.contains(.command),
            isMouseInsideMenuBar(appState: appState, screen: screen)
        else {
            return
        }

        isDraggingMenuBarItem = true

        if appState.settings.advanced.showAllSectionsOnUserDrag {
            if #available(macOS 27.0, *) {
                for section in appState.menuBarManager.sections {
                    section.show()
                }
            } else {
                for section in appState.menuBarManager.sections {
                    section.controlItem.state = .showSection
                }
            }
        }
    }

    // MARK: Handle Show On Hover

    private func handleShowOnHover(appState: AppState, screen: NSScreen) {
        rehideTask?.cancel()
        rehideTask = nil
        if modernEmptySpaceTask != nil && !modernIntentIsHover { return }
        // Make sure the "ShowOnHover" feature is enabled and allowed.
        guard
            appState.settings.general.showOnHover,
            appState.menuBarManager.showOnHoverAllowed
        else {
            return
        }

        // Only continue if we have a hidden section (we should).
        guard let hiddenSection = appState.menuBarManager.section(withName: .hidden) else {
            return
        }

        let delay = appState.settings.advanced.showOnHoverDelay

        if #available(macOS 27, *), hiddenSection.isHidden {
            scheduleModernEmptySpaceAction(appState: appState, screen: screen, delay: delay, waitsForMenuBar: true) {
                guard appState.settings.general.showOnHover,
                      appState.menuBarManager.showOnHoverAllowed, hiddenSection.isHidden else { return }
                hiddenSection.show()
            }
            return
        }

        if hiddenSection.isHidden {
            guard isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen) else {
                return
            }
            rehideTask = Task {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                // Make sure the feature is still enabled and the mouse is still inside.
                guard
                    appState.settings.general.showOnHover,
                    isMouseInsideEmptyMenuBarSpace(appState: appState, screen: screen)
                else {
                    return
                }
                hiddenSection.show()
            }
        } else {
            guard
                !isMouseInsideMenuBar(appState: appState, screen: screen),
                !isMouseInsideIceBar(appState: appState)
            else {
                return
            }
            rehideTask = Task {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                // Make sure the feature is still enabled and the mouse is still outside.
                guard
                    appState.settings.general.showOnHover,
                    appState.settings.general.autoRehide,
                    !isMouseInsideMenuBar(appState: appState, screen: screen),
                    !isMouseInsideIceBar(appState: appState)
                else {
                    return
                }
                hiddenSection.hide()
            }
        }
    }

    // MARK: Handle Show On Scroll

    private func handleShowOnScroll(with event: NSEvent, appState: AppState, screen: NSScreen) {
        // Make sure the "ShowOnScroll" feature is enabled.
        guard appState.settings.general.showOnScroll else {
            return
        }

        // Make sure the mouse is inside the menu bar.
        guard isMouseInsideMenuBar(appState: appState, screen: screen) else {
            return
        }

        // Only continue if we have a hidden section (we should).
        guard let hiddenSection = appState.menuBarManager.section(withName: .hidden) else {
            return
        }

        let averageDelta = (event.scrollingDeltaX + event.scrollingDeltaY) / 2

        if averageDelta > 5 {
            hiddenSection.show()
        } else if averageDelta < -5 {
            hiddenSection.hide()
        }
    }
}

// MARK: - Helper Methods

extension EventManager {
    private func cancelModernEmptySpaceAction() {
        modernInteractionGeneration &+= 1
        modernEmptySpaceTask?.cancel()
        modernEmptySpaceTask = nil
    }

    /// Check cheap menu bounds before querying the application menu. Status-item
    /// absence is established separately by fresh, complete raw AX geometry.
    private func isModernEmptySpaceCandidate(appState: AppState, screen: NSScreen) -> Bool {
        guard isMouseInsideMenuBar(appState: appState, screen: screen),
              !isMouseInsideNotch(appState: appState, screen: screen),
              let point = MouseHelpers.locationCoreGraphics,
              var appMenuFrame = screen.getApplicationMenuFrame(),
              ModernMenuBarOccupancy.isUsable(appMenuFrame) else { return false }
        let displayBounds = CGDisplayBounds(screen.displayID)
        appMenuFrame.size.width += appMenuFrame.origin.x - displayBounds.minX
        appMenuFrame.origin.x = displayBounds.minX
        return !appMenuFrame.contains(point)
    }

    private func scheduleModernEmptySpaceAction(
        appState: AppState,
        screen: NSScreen,
        delay: TimeInterval,
        waitsForMenuBar: Bool = false,
        action: @escaping @MainActor () -> Void
    ) {
        // Hover can begin on the reveal strip before macOS has slid the bar
        // into place. Clicks still require a visible, readable bar immediately.
        guard isMouseInsideMenuBar(appState: appState, screen: screen),
              !isMouseInsideNotch(appState: appState, screen: screen),
              waitsForMenuBar || isModernEmptySpaceCandidate(appState: appState, screen: screen),
              let point = MouseHelpers.locationCoreGraphics else { return }
        cancelModernEmptySpaceAction()
        modernIntentIsHover = waitsForMenuBar
        let intent = ModernMenuBarInteractionIntent(point: point, generation: modernInteractionGeneration)
        modernEmptySpaceTask = Task { [weak self] in
            defer {
                if self?.modernInteractionGeneration == intent.generation { self?.modernEmptySpaceTask = nil }
            }
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
            guard let self else { return }
            // Bounded retries allow a stationary pointer to survive the reveal
            // animation. Each attempt uses new AX geometry and its own deadline.
            let deadline = ProcessInfo.processInfo.systemUptime + (waitsForMenuBar ? 1.5 : 0)
            repeat {
                guard !Task.isCancelled,
                      intent.isCurrent(point: MouseHelpers.locationCoreGraphics, generation: modernInteractionGeneration),
                      isMouseInsideMenuBar(appState: appState, screen: screen) else { return }
                if isModernEmptySpaceCandidate(appState: appState, screen: screen),
                   await appState.modernMenuBarManager.confirmsEmptySpace(at: point) {
                    guard !Task.isCancelled,
                          intent.isCurrent(point: MouseHelpers.locationCoreGraphics, generation: modernInteractionGeneration),
                          isModernEmptySpaceCandidate(appState: appState, screen: screen) else { return }
                    action()
                    return
                }
                guard waitsForMenuBar, ProcessInfo.processInfo.systemUptime < deadline else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            } while ProcessInfo.processInfo.systemUptime < deadline
        }
    }

    /// Returns the best screen to use for event manager calculations.
    func bestScreen(appState: AppState) -> NSScreen? {
        if #available(macOS 27, *) {
            return NSScreen.screenWithMouse ?? NSScreen.main
        }
        guard
            appState.activeSpace.isFullscreen,
            let screen = NSScreen.screenWithMouse
        else {
            return NSScreen.main
        }
        return screen
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the menu bar.
    func isMouseInsideMenuBar(appState: AppState, screen: NSScreen) -> Bool {
        if let mouseLocation = MouseHelpers.locationAppKit,
           screen.containsAppKitMenuBarPoint(mouseLocation) {
            return true
        }
        // Cached editor frames can still describe a bar that has retracted.
        if #available(macOS 27, *) { return false }
        return isMouseInsideMenuBarItem(appState: appState, screen: screen)
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the current application menu.
    func isMouseInsideApplicationMenu(appState: AppState, screen: NSScreen) -> Bool {
        guard
            let mouseLocation = MouseHelpers.locationCoreGraphics,
            var applicationMenuFrame = screen.getApplicationMenuFrame()
        else {
            return false
        }
        applicationMenuFrame.size.width += applicationMenuFrame.origin.x - screen.frame.origin.x
        applicationMenuFrame.origin.x = screen.frame.origin.x
        return applicationMenuFrame.contains(mouseLocation)
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of a menu bar item.
    func isMouseInsideMenuBarItem(appState: AppState, screen: NSScreen) -> Bool {
        guard let mouseLocation = MouseHelpers.locationCoreGraphics else {
            return false
        }
        if #available(macOS 27.0, *) {
            return appState.modernMenuBarManager.items.contains { item in
                !appState.modernMenuBarManager.isConcealed(item) && item.frame.contains(mouseLocation)
            }
        }
        let windowIDs = Bridging.getMenuBarWindowList(option: [.onScreen, .activeSpace, .itemsOnly])
        return windowIDs.contains { windowID in
            guard let bounds = Bridging.getWindowBounds(for: windowID) else {
                return false
            }
            return bounds.contains(mouseLocation)
        }
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the screen's notch, if it has one.
    ///
    /// If the screen does not have a notch, this property returns `false`.
    func isMouseInsideNotch(appState: AppState, screen: NSScreen) -> Bool {
        guard
            let mouseLocation = MouseHelpers.locationAppKit,
            var frameOfNotch = screen.frameOfNotch
        else {
            return false
        }
        frameOfNotch.size.height += 1
        return frameOfNotch.contains(mouseLocation)
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of an empty space in the menu bar.
    func isMouseInsideEmptyMenuBarSpace(appState: AppState, screen: NSScreen) -> Bool {
        isMouseInsideMenuBar(appState: appState, screen: screen) &&
        !isMouseInsideApplicationMenu(appState: appState, screen: screen) &&
        !isMouseInsideMenuBarItem(appState: appState, screen: screen) &&
        !isMouseInsideNotch(appState: appState, screen: screen)
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the Ice Bar panel.
    func isMouseInsideIceBar(appState: AppState) -> Bool {
        guard let mouseLocation = MouseHelpers.locationAppKit else {
            return false
        }
        let panel = appState.menuBarManager.iceBarPanel
        // Pad the frame to be more forgiving if the user accidentally
        // moves their mouse outside of the Ice Bar.
        let paddedFrame = panel.frame.insetBy(dx: -10, dy: -10)
        return paddedFrame.contains(mouseLocation)
    }

    /// A Boolean value that indicates whether the mouse pointer is within
    /// the bounds of the Ice icon.
    func isMouseInsideIceIcon(appState: AppState) -> Bool {
        guard
            let visibleSection = appState.menuBarManager.section(withName: .visible),
            let iceIconFrame = visibleSection.controlItem.frame,
            let mouseLocation = MouseHelpers.locationAppKit
        else {
            return false
        }
        return iceIconFrame.contains(mouseLocation)
    }
}

// MARK: - EventMonitor Helpers

/// Helper protocol to enable group operations across event
/// monitoring types.
@MainActor
private protocol EventMonitorProtocol {
    func start()
    func stop()
}

extension EventMonitor: EventMonitorProtocol { }

extension EventTap: EventMonitorProtocol {
    fileprivate func start() {
        enable()
    }

    fileprivate func stop() {
        disable()
    }
}

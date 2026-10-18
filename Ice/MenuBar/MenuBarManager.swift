//
//  MenuBarManager.swift
//  Ice
//

import Combine
import OSLog
import SwiftUI

/// Manager for the state of the menu bar.
@MainActor
final class MenuBarManager: ObservableObject {
    /// Information for the menu bar's average color.
    @Published private(set) var averageColorInfo: MenuBarAverageColorInfo?

    /// A Boolean value that indicates whether the menu bar is either always hidden
    /// by the system, or automatically hidden and shown by the system based on the
    /// location of the mouse.
    @Published private(set) var isMenuBarHiddenBySystem = false

    /// A Boolean value that indicates whether the menu bar is hidden by the system
    /// according to a value stored in UserDefaults.
    @Published private(set) var isMenuBarHiddenBySystemUserDefaults = false

    /// A Boolean value that indicates whether the "ShowOnHover" feature is allowed.
    @Published var showOnHoverAllowed = true

    /// Reference to the settings window.
    @Published private var settingsWindow: NSWindow?

    /// Logger for the menu bar manager.
    private let logger = Logger(category: "MenuBarManager")

    /// The shared app state.
    private weak var appState: AppState?

    /// Storage for internal observers.
    private var cancellables = Set<AnyCancellable>()

    /// A Boolean value that indicates whether the application menus are hidden.
    private var isHidingApplicationMenus = false

    /// Panels that cover non-contract auxiliary status item windows while the system menu bar is hidden.
    private var auxiliaryStatusItemCoverPanels = [CGWindowID: NSPanel]()

    /// The last visible/hidden state resolved for auxiliary status item cover panels.
    private var auxiliaryStatusItemCoversAreVisible = false

    /// The last CoreGraphics frames applied to auxiliary status item cover panels.
    private var auxiliaryStatusItemCoverFrames = [CGWindowID: CGRect]()

    /// The last display mode applied to auxiliary status item cover panels.
    private var auxiliaryStatusItemCoverModes = [CGWindowID: AuxiliaryStatusItemCoverMode]()

    /// A delayed task used to avoid drawing cover panels during the menu bar's auto-hide retraction animation.
    private var auxiliaryStatusItemCoverTask: Task<Void, Never>?

    /// The delay used before retrying cover creation while the system menu bar is retracting.
    private let auxiliaryStatusItemCoverRetryDelay: Duration = .milliseconds(120)

    /// The panel that contains the Ice Bar interface.
    let iceBarPanel = IceBarPanel()

    /// The panel that contains the menu bar search interface.
    let searchPanel = MenuBarSearchPanel()

    /// The panel that contains a portable version of the menu bar
    /// appearance editor interface
    let appearanceEditorPanel = MenuBarAppearanceEditorPanel()

    /// The managed sections in the menu bar.
    let sections = [
        MenuBarSection(name: .visible),
        MenuBarSection(name: .hidden),
        MenuBarSection(name: .alwaysHidden),
    ]

    /// A Boolean value that indicates whether at least one of the manager's
    /// sections is visible.
    var hasVisibleSection: Bool {
        sections.contains { !$0.isHidden }
    }

    /// A Boolean value that indicates whether Ice is currently showing managed sections in the native menu bar.
    private var isShowingMenuBarSections: Bool {
        sections.contains { $0.controlItem.state == .showSection }
    }

    /// A Boolean value that indicates whether the system menu bar is configured to auto-hide.
    private var isMenuBarConfiguredToAutoHide: Bool {
        isMenuBarHiddenBySystemUserDefaults
    }

    /// A visual mode for an auxiliary status item cover panel.
    private enum AuxiliaryStatusItemCoverMode: Equatable {
        case hide
        case center(itemFrame: CGRect)
    }

    /// Performs the initial setup of the menu bar manager.
    func performSetup(with appState: AppState) {
        self.appState = appState
        configureCancellables()
        iceBarPanel.performSetup(with: appState)
        searchPanel.performSetup(with: appState)
        appearanceEditorPanel.performSetup(with: appState)
        for section in sections {
            section.performSetup(with: appState)
        }
    }

    /// Configures the internal observers for the manager.
    private func configureCancellables() {
        var c = Set<AnyCancellable>()

        NSApp.publisher(for: \.currentSystemPresentationOptions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] options in
                guard let self else {
                    return
                }
                let hidden = options.contains(.hideMenuBar) || options.contains(.autoHideMenuBar)
                isMenuBarHiddenBySystem = hidden
                updateAuxiliaryStatusItemCovers()
            }
            .store(in: &c)

        if
            let hiddenSection = section(withName: .alwaysHidden),
            let window = hiddenSection.controlItem.window
        {
            window.publisher(for: \.frame)
                .map { $0.origin.y }
                .removeDuplicates()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard
                        let self,
                        let isMenuBarHidden = Defaults.globalDomain["_HIHideMenuBar"] as? Bool
                    else {
                        return
                    }
                    isMenuBarHiddenBySystemUserDefaults = isMenuBarHidden
                    updateAuxiliaryStatusItemCovers()
                }
                .store(in: &c)
        }

        if
            let hiddenSection = section(withName: .hidden),
            let window = hiddenSection.controlItem.window
        {
            window.publisher(for: \.frame)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateAuxiliaryStatusItemCovers()
                }
                .store(in: &c)
        }

        isMenuBarHiddenBySystemUserDefaults = Defaults.globalDomain["_HIHideMenuBar"] as? Bool ?? false
        Timer.publish(every: 30, on: .main, in: .default).autoconnect()
            .sink { [weak self] _ in
                self?.isMenuBarHiddenBySystemUserDefaults = Defaults.globalDomain["_HIHideMenuBar"] as? Bool ?? false
            }.store(in: &c)
        if #unavailable(macOS 27) {
            EventMonitor.publish(events: [.mouseMoved, .leftMouseDragged, .rightMouseDragged], scope: .universal)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.updateAuxiliaryStatusItemCoversForPointerChange()
                }
                .store(in: &c)

            Timer.publish(every: 1, on: .main, in: .default)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self else { return }
                    updateAuxiliaryStatusItemCovers(refreshImages: true)
                }
                .store(in: &c)
        }

        // Handle the `focusedApp` rehide strategy.
        NSWorkspace.shared.publisher(for: \.frontmostApplication)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if
                    let self,
                    let appState,
                    case .focusedApp = appState.settings.general.rehideStrategy,
                    let hiddenSection = section(withName: .hidden),
                    let screen = appState.eventManager.bestScreen(appState: appState),
                    !appState.eventManager.isMouseInsideMenuBar(appState: appState, screen: screen)
                {
                    Task {
                        try await Task.sleep(for: .seconds(0.1))
                        hiddenSection.hide()
                    }
                }
            }
            .store(in: &c)

        appState?.publisherForWindow(.settings)
            .sink { [weak self] window in
                self?.settingsWindow = window
            }
            .store(in: &c)

        if #unavailable(macOS 27) {
            $settingsWindow
                .removeNil()
                .flatMap { $0.publisher(for: \.isVisible) }
                .discardMerge(Timer.publish(every: 5, on: .main, in: .default).autoconnect())
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in
                    self?.updateAverageColorInfo()
                }
                .store(in: &c)
        }

        // Hide application menus when a section is shown (if applicable).
        Publishers.MergeMany(sections.map { $0.controlItem.$state })
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if #available(macOS 27, *) { return }
                guard let self, let appState else {
                    return
                }

                // Don't continue if:
                //   * The "HideApplicationMenus" setting isn't enabled.
                //   * Using the Ice Bar.
                //   * The menu bar is hidden by the system.
                //   * The active space is fullscreen.
                //   * The settings window is visible.
                guard
                    appState.settings.advanced.hideApplicationMenus,
                    !appState.settings.general.useIceBar,
                    !isMenuBarHiddenBySystem,
                    !appState.activeSpace.isFullscreen,
                    !appState.navigationState.isSettingsPresented
                else {
                    return
                }

                if sections.contains(where: { $0.controlItem.state == .showSection }) {
                    guard let screen = NSScreen.main else {
                        return
                    }

                    // Get the application menu frame for the display.
                    guard let applicationMenuFrame = screen.getApplicationMenuFrame() else {
                        return
                    }

                    Task {
                        // Get all items.
                        var items = await MenuBarItem.getMenuBarItems(on: screen.displayID, option: .activeSpace)

                        // Filter the items down according to the currently enabled/shown sections.
                        if
                            let alwaysHiddenSection = self.section(withName: .alwaysHidden),
                            alwaysHiddenSection.isEnabled
                        {
                            if alwaysHiddenSection.controlItem.state == .hideSection {
                                if let alwaysHiddenControlItem = items.firstIndex(matching: .alwaysHiddenControlItem).map({ items.remove(at: $0) }) {
                                    items.trimPrefix { $0.bounds.maxX <= alwaysHiddenControlItem.bounds.minX }
                                }
                            }
                        } else {
                            if let hiddenControlItem = items.firstIndex(matching: .hiddenControlItem).map({ items.remove(at: $0) }) {
                                items.trimPrefix { $0.bounds.maxX <= hiddenControlItem.bounds.minX }
                            }
                        }

                        // Get the leftmost item on the screen.
                        guard let leftmostItem = items.min(by: { $0.bounds.minX < $1.bounds.minX }) else {
                            return
                        }

                        // If the minX of the item is less than or equal to the maxX of the
                        // application menu frame, activate the app to hide the menu.
                        if leftmostItem.bounds.minX <= applicationMenuFrame.maxX {
                            self.hideApplicationMenus()
                        }
                    }
                } else if isHidingApplicationMenus {
                    showApplicationMenus()
                }
                updateAuxiliaryStatusItemCovers()
            }
            .store(in: &c)

        cancellables = c
    }

    /// Returns whether auxiliary status item windows should currently be covered.
    private func shouldCoverAuxiliaryStatusItems(appState: AppState) -> Bool {
        guard isMenuBarConfiguredToAutoHide else {
            return false
        }
        let screen = appState.eventManager.bestScreen(appState: appState) ?? NSScreen.screenWithMouse ?? NSScreen.main
        guard let screen else {
            return false
        }
        return !appState.eventManager.isMouseInsideMenuBar(appState: appState, screen: screen)
    }

    /// Returns whether the system menu bar has retracted far enough for clean cover captures.
    private func canDrawHiddenAuxiliaryStatusItemCovers() -> Bool {
        let windows = WindowInfo.createWindows(option: .onScreen)
        let menuBarWindowIsOnScreen = NSScreen.screens.contains { screen in
            WindowInfo.menuBarWindow(from: windows, for: screen.displayID) != nil
        }

        guard !menuBarWindowIsOnScreen else {
            return false
        }

        guard
            let hiddenSection = section(withName: .hidden),
            let window = hiddenSection.controlItem.window,
            let windowNumber = window.windowNumber as Int?,
            let info = WindowInfo(windowID: CGWindowID(windowNumber))
        else {
            return true
        }

        return !info.isOnScreen
    }

    /// Schedules a cover update without extending an already-pending retry.
    private func scheduleAuxiliaryStatusItemCoverUpdate(after delay: Duration) {
        guard auxiliaryStatusItemCoverTask == nil else {
            return
        }

        auxiliaryStatusItemCoverTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.auxiliaryStatusItemCoverTask = nil
                self?.updateAuxiliaryStatusItemCovers(refreshImages: true, deferNewCovers: false)
            }
        }
    }

    /// Updates cover panels after pointer movement, without refreshing images unless visibility changes.
    private func updateAuxiliaryStatusItemCoversForPointerChange() {
        if #available(macOS 27, *) { return }
        guard let appState else {
            closeAuxiliaryStatusItemCoverPanels()
            return
        }

        let shouldCoverItems = shouldCoverAuxiliaryStatusItems(appState: appState)
        guard shouldCoverItems != auxiliaryStatusItemCoversAreVisible else {
            return
        }

        updateAuxiliaryStatusItemCovers(refreshImages: shouldCoverItems)
    }

    /// Updates panels that hide non-contract app-owned auxiliary status item windows while macOS retracts an auto-hidden menu bar.
    private func updateAuxiliaryStatusItemCovers(refreshImages: Bool = false, deferNewCovers: Bool = true) {
        if #available(macOS 27.0, *) {
            auxiliaryStatusItemCoverTask?.cancel()
            auxiliaryStatusItemCoverTask = nil
            closeAuxiliaryStatusItemCoverPanels()
            return
        }

        guard let appState else {
            auxiliaryStatusItemCoverTask?.cancel()
            auxiliaryStatusItemCoverTask = nil
            closeAuxiliaryStatusItemCoverPanels()
            return
        }

        Task { [weak self] in
            let items = await MenuBarItem.getMenuBarItems(option: [.onScreen, .activeSpace])
            await MainActor.run {
                self?.applyAuxiliaryStatusItemCovers(
                    items: items,
                    appState: appState,
                    refreshImages: refreshImages,
                    deferNewCovers: deferNewCovers
                )
            }
        }
    }

    private func applyAuxiliaryStatusItemCovers(
        items: [MenuBarItem],
        appState: AppState,
        refreshImages: Bool,
        deferNewCovers: Bool
    ) {
        let shouldCoverItems = shouldCoverAuxiliaryStatusItems(appState: appState)
        let shouldSuppressVisibleCenteringCovers = !shouldCoverItems && isShowingMenuBarSections

        if
            !refreshImages,
            auxiliaryStatusItemCoverTask == nil,
            auxiliaryStatusItemCoverPanels.isEmpty,
            shouldCoverItems == auxiliaryStatusItemCoversAreVisible
        {
            return
        }

        if !shouldCoverItems {
            auxiliaryStatusItemCoverTask?.cancel()
            auxiliaryStatusItemCoverTask = nil
        }

        let coverContexts = items
            .filter { $0.isAuxiliaryStatusItem && !$0.isBundleIdentifiedAuxiliaryStatusItem }
            .compactMap { item -> (item: MenuBarItem, frame: CGRect, mode: AuxiliaryStatusItemCoverMode)? in
                if shouldCoverItems {
                    return (item, item.bounds, .hide)
                }
                guard !shouldSuppressVisibleCenteringCovers else {
                    return nil
                }
                guard let centeringFrame = auxiliaryStatusItemCenteringCoverFrame(for: item) else {
                    return nil
                }
                return (item, centeringFrame, .center(itemFrame: item.bounds))
            }

        guard !coverContexts.isEmpty else {
            closeAuxiliaryStatusItemCoverPanels()
            auxiliaryStatusItemCoversAreVisible = shouldCoverItems
            auxiliaryStatusItemCoverTask = nil
            return
        }

        if shouldCoverItems {
            guard canDrawHiddenAuxiliaryStatusItemCovers() else {
                closeAuxiliaryStatusItemCoverPanels()
                scheduleAuxiliaryStatusItemCoverUpdate(after: auxiliaryStatusItemCoverRetryDelay)
                return
            }
        }

        if shouldCoverItems, !auxiliaryStatusItemCoversAreVisible, deferNewCovers {
            closeAuxiliaryStatusItemCoverPanels()
            scheduleAuxiliaryStatusItemCoverUpdate(after: auxiliaryStatusItemCoverRetryDelay)
            return
        }

        let itemWindowIDs = Set(coverContexts.map(\.item.windowID))
        for windowID in auxiliaryStatusItemCoverPanels.keys where !itemWindowIDs.contains(windowID) {
            auxiliaryStatusItemCoverPanels.removeValue(forKey: windowID)?.close()
            auxiliaryStatusItemCoverFrames.removeValue(forKey: windowID)
            auxiliaryStatusItemCoverModes.removeValue(forKey: windowID)
        }

        for context in coverContexts {
            let item = context.item
            let coverFrame = context.frame
            guard let frame = appKitFrame(for: coverFrame) else {
                continue
            }
            let panel = auxiliaryStatusItemCoverPanels[item.windowID] ?? createAuxiliaryStatusItemCoverPanel()
            let imageView = panel.contentView as? NSImageView

            let needsImageRefresh =
                refreshImages ||
                auxiliaryStatusItemCoverFrames[item.windowID] != coverFrame ||
                auxiliaryStatusItemCoverModes[item.windowID] != context.mode ||
                imageView?.image == nil

            if needsImageRefresh, let imageView {
                guard let image = auxiliaryStatusItemCoverImage(for: item, coverFrame: coverFrame, mode: context.mode, size: frame.size) else {
                    continue
                }
                imageView.image = image
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                panel.setFrame(frame, display: true)
                panel.alphaValue = 1
            }

            panel.orderFrontRegardless()
            auxiliaryStatusItemCoverPanels[item.windowID] = panel
            auxiliaryStatusItemCoverFrames[item.windowID] = coverFrame
            auxiliaryStatusItemCoverModes[item.windowID] = context.mode
        }

        auxiliaryStatusItemCoversAreVisible = shouldCoverItems
        auxiliaryStatusItemCoverTask = nil
    }

    /// Returns the menu bar-height frame needed to visually center an auxiliary status item.
    private func auxiliaryStatusItemCenteringCoverFrame(for item: MenuBarItem) -> CGRect? {
        guard
            let screen = NSScreen.screens.first(where: { CGDisplayBounds($0.displayID).intersects(item.bounds) }),
            let menuBarHeight = WindowInfo.menuBarWindow(for: screen.displayID)?.bounds.height ?? screen.getMenuBarHeight()
        else {
            return nil
        }

        let displayBounds = CGDisplayBounds(screen.displayID)
        let centeredMinY = displayBounds.minY + ((menuBarHeight - item.bounds.height) / 2)

        guard
            item.bounds.height < menuBarHeight - 1,
            abs(item.bounds.minY - centeredMinY) > 1
        else {
            return nil
        }

        return CGRect(
            x: item.bounds.minX,
            y: displayBounds.minY,
            width: item.bounds.width,
            height: menuBarHeight
        )
    }

    /// Creates the image displayed by an auxiliary status item cover panel.
    private func auxiliaryStatusItemCoverImage(
        for item: MenuBarItem,
        coverFrame: CGRect,
        mode: AuxiliaryStatusItemCoverMode,
        size: CGSize
    ) -> NSImage? {
        guard let backgroundImage = ScreenCapture.captureScreenBelowWindow(
            with: item.windowID,
            screenBounds: coverFrame,
            option: [.boundsIgnoreFraming, .bestResolution]
        ) else {
            return nil
        }

        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        NSImage(cgImage: backgroundImage, size: size).draw(in: CGRect(origin: .zero, size: size))

        if
            case .center(let itemFrame) = mode,
            let itemImage = ScreenCapture.captureWindow(with: item.windowID, option: [.boundsIgnoreFraming, .bestResolution])
        {
            let itemSize = CGSize(width: itemFrame.width, height: itemFrame.height)
            let itemOrigin = CGPoint(
                x: itemFrame.minX - coverFrame.minX,
                y: (coverFrame.height - itemFrame.height) / 2
            )
            NSImage(cgImage: itemImage, size: itemSize).draw(in: CGRect(origin: itemOrigin, size: itemSize))
        }

        return image
    }

    /// Closes all cover panels for app-owned auxiliary status item windows.
    private func closeAuxiliaryStatusItemCoverPanels() {
        for panel in auxiliaryStatusItemCoverPanels.values {
            panel.close()
        }
        auxiliaryStatusItemCoverPanels.removeAll()
        auxiliaryStatusItemCoverFrames.removeAll()
        auxiliaryStatusItemCoverModes.removeAll()
        auxiliaryStatusItemCoversAreVisible = false
    }

    /// Creates a panel that visually covers an auxiliary status item window.
    private func createAuxiliaryStatusItemCoverPanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Auxiliary Status Item Cover"
        panel.level = .mainMenu + 2
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .moveToActiveSpace]
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isOpaque = false

        let imageView = NSImageView()
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleAxesIndependently
        panel.contentView = imageView

        return panel
    }

    /// Converts a CoreGraphics-coordinate frame into AppKit screen coordinates.
    private func appKitFrame(for coreGraphicsFrame: CGRect) -> CGRect? {
        guard
            let screen = NSScreen.screens.first(where: { screen in
                CGDisplayBounds(screen.displayID).intersects(coreGraphicsFrame)
            })
        else {
            return nil
        }

        let displayBounds = CGDisplayBounds(screen.displayID)
        return CGRect(
            x: screen.frame.minX + coreGraphicsFrame.minX - displayBounds.minX,
            y: screen.frame.maxY - (coreGraphicsFrame.maxY - displayBounds.minY),
            width: coreGraphicsFrame.width,
            height: coreGraphicsFrame.height
        )
    }

    /// Updates the ``averageColorInfo`` property with the current average color
    /// of the menu bar.
    func updateAverageColorInfo() {
        guard
            let settingsWindow,
            settingsWindow.isVisible,
            let screen = settingsWindow.screen
        else {
            return
        }

        let windows = WindowInfo.createWindows(option: .onScreen)
        let displayID = screen.displayID

        guard
            let menuBarWindow = WindowInfo.menuBarWindow(from: windows, for: displayID),
            let wallpaperWindow = WindowInfo.wallpaperWindow(from: windows, for: displayID)
        else {
            return
        }

        guard
            let image = ScreenCapture.captureWindows(
                with: [menuBarWindow.windowID, wallpaperWindow.windowID],
                screenBounds: withMutableCopy(of: wallpaperWindow.bounds) { $0.size.height = 1 },
                option: .nominalResolution
            ),
            let color = image.averageColor(option: .ignoreAlpha)
        else {
            return
        }

        let info = MenuBarAverageColorInfo(color: color, source: .menuBarWindow)

        if averageColorInfo != info {
            averageColorInfo = info
        }
    }

    /// Returns a Boolean value that indicates whether the given display
    /// has a valid menu bar.
    func hasValidMenuBar(in windows: [WindowInfo], for display: CGDirectDisplayID) -> Bool {
        guard
            let window = WindowInfo.menuBarWindow(from: windows, for: display),
            let element = AXHelpers.element(at: window.bounds.origin)
        else {
            return false
        }
        return AXHelpers.role(for: element) == .menuBar
    }

    /// Shows the secondary context menu.
    func showSecondaryContextMenu(at point: CGPoint) {
        let menu = NSMenu(title: "Ice")

        let editAppearanceItem = NSMenuItem(
            title: "Edit Menu Bar Appearance…",
            action: #selector(showAppearanceEditorPanel),
            keyEquivalent: ""
        )
        editAppearanceItem.target = self
        menu.addItem(editAppearanceItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Ice Settings…",
            action: #selector(AppDelegate.openSettingsWindow),
            keyEquivalent: ","
        )
        menu.addItem(settingsItem)

        menu.popUp(positioning: nil, at: point, in: nil)
    }

    /// Hides the application menus.
    func hideApplicationMenus() {
        guard let appState else {
            logger.error("Error hiding application menus: Missing app state")
            return
        }
        logger.info("Hiding application menus")
        appState.activate(withPolicy: .regular)
        isHidingApplicationMenus = true
    }

    /// Shows the application menus.
    func showApplicationMenus() {
        guard let appState else {
            logger.error("Error showing application menus: Missing app state")
            return
        }
        logger.info("Showing application menus")
        appState.deactivate(withPolicy: .accessory)
        isHidingApplicationMenus = false
    }

    /// Toggles the visibility of the application menus.
    func toggleApplicationMenus() {
        if isHidingApplicationMenus {
            showApplicationMenus()
        } else {
            hideApplicationMenus()
        }
    }

    /// Shows the appearance editor panel.
    @objc private func showAppearanceEditorPanel() {
        guard let screen = MenuBarAppearanceEditorPanel.defaultScreen else {
            return
        }
        appearanceEditorPanel.show(on: screen)
    }

    /// Returns the menu bar section with the given name.
    func section(withName name: MenuBarSection.Name) -> MenuBarSection? {
        sections.first { $0.name == name }
    }

    /// Returns the control item for the menu bar section with the given name.
    func controlItem(withName name: MenuBarSection.Name) -> ControlItem? {
        section(withName: name)?.controlItem
    }
}

// MARK: - MenuBarAverageColorInfo

/// Information for the average color of the menu bar.
struct MenuBarAverageColorInfo: Hashable {
    /// Sources used to compute the average color of the menu bar.
    enum Source: Hashable {
        case menuBarWindow
        case desktopWallpaper
    }

    /// The average color of the menu bar
    var color: CGColor

    /// The source used to compute the color.
    var source: Source

    /// The brightness of the menu bar's color.
    var brightness: CGFloat { color.brightness ?? 0 }

    /// A Boolean value that indicates whether the menu bar has a
    /// bright color.
    ///
    /// This value is `true` if ``brightness`` is above `0.67`. At
    /// the time of writing, if this value is `true`, the menu bar
    /// draws its items with a darker appearance.
    var isBright: Bool { brightness > 0.67 }
}

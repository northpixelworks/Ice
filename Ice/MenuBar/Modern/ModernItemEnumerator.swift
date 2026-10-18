//
//  ModernItemEnumerator.swift
//  Ice
//

// Adapted from fif7y/Pelmet (GPL-3.0). See docs/MACOS_27.md.
// ModernItemEnumerator.swift
// AX snapshot of MenuBarAgent's item tree. Verified structure (M1 findings):
// AXApplication → AXWindow (one per display) → `?`-role groups, one per item.
// Third-party groups nest the owning app's AXApplication node; system items are
// AXMenuBarItem leaves with a com.apple.menuextra.* identifier.

import AppKit
import ApplicationServices
import Foundation

public struct ModernMenuBarItem: Identifiable, Equatable, Sendable {
    public let id: ModernItemID
    public let frame: CGRect
    public let appName: String?
    /// See `ObservedItem.hostIsBundleless`.
    public let hostIsBundleless: Bool
    /// See `ObservedItem.pid`.
    public let pid: pid_t
}

public struct ModernMenuBarSnapshot: Sendable {
    public let items: [ModernMenuBarItem]
    public let isReadable: Bool
    public var hasReadErrors = false
    /// False only when geometry positively establishes retraction. Unknown
    /// presentation keeps normal unreadable-snapshot retry handling active.
    public var isMenuBarPresented = true
    /// Raw observations from fully presented displays only. Cached off-screen
    /// groups still belong in the editor, but cannot verify live concealment.
    public var presentedItems: [ModernMenuBarItem]?

    var verificationItems: [ModernMenuBarItem] { presentedItems ?? items }

    var canVerifyVisibility: Bool {
        isReadable && isMenuBarPresented && !hasReadErrors && !items.isEmpty && hasVerificationAnchor
    }

    var hasVerificationAnchor: Bool {
        verificationItems.contains { item in
            item.id.bundleID == "com.apple.MenuBarAgent" && (
                item.id.systemItem != nil ||
                item.id.isUserSwitcher ||
                item.id.title == "com.apple.menuextra.controlcenter"
            )
        }
    }

    static let unreadable = Self(items: [], isReadable: false)
}

/// Bundle attribution of an item's owning process.
private struct HostBundle {
    let id: String
    /// The process itself has no LS bundle id; `id` came from walking the
    /// executable path up to the enclosing .app.
    let bundleless: Bool
}

/// Runs off the main actor: AX calls into busy apps can block, so snapshots are
/// taken on a background executor with short messaging timeouts.
public actor ModernItemEnumerator {
    public init() {}
    static let agentBundleID = "com.apple.MenuBarAgent"

    private var agentElement: AXUIElement?
    private var agentPID: pid_t = 0
    private var snapshotHadReadErrors = false
    private var snapshotDeadline: TimeInterval = .infinity
    private var snapshotReadCount = 0

    /// Correlates each observed item group to a stable agent tag. Tags come
    /// from the positions plist domain (`status:<bundle>::<title>`); we build
    /// the same shape from the AX tree so both sources agree.
    public func snapshotItems() -> [ModernMenuBarItem] {
        snapshot().items
    }

    public func snapshot() -> ModernMenuBarSnapshot {
        snapshotHadReadErrors = false
        let started = ProcessInfo.processInfo.systemUptime
        snapshotReadCount = 0
        snapshotDeadline = started + 1.5
        defer {
            NSLog("[Ice ModernAX] snapshot reads=%ld duration=%.3f incomplete=%d", snapshotReadCount, ProcessInfo.processInfo.systemUptime - started, snapshotHadReadErrors)
            snapshotDeadline = .infinity
        }
        guard let agent = resolveAgent() else { return .unreadable }
        guard let windows = copyAttribute(agent, kAXChildrenAttribute) as? [AXUIElement] else {
            return .unreadable
        }
        var byID: [ModernItemID: ModernMenuBarItem] = [:]
        var order: [ModernItemID] = []
        var readWindowChildren = false
        var hasPresentedMenuBar = false
        var presentationHadReadErrors = false
        var presentedItems: [ModernMenuBarItem] = []
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else { return .unreadable }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displays, &displayCount) == .success, displayCount > 0 else { return .unreadable }
        let displayBounds = displays.prefix(Int(displayCount)).map { CGDisplayBounds($0) }
        for window in windows {
            guard role(of: window) == "AXWindow" else { continue }
            let isPresented: Bool
            if let windowFrame = frame(of: window), ModernMenuBarOccupancy.isUsable(windowFrame) {
                isPresented = ModernMenuBarGeometry.isPresented(windowFrame, on: displayBounds)
            } else {
                isPresented = false
                presentationHadReadErrors = true
                snapshotHadReadErrors = true
            }
            hasPresentedMenuBar = hasPresentedMenuBar || isPresented
            guard let groups = copyAttribute(window, kAXChildrenAttribute) as? [AXUIElement] else {
                snapshotHadReadErrors = true
                continue
            }
            readWindowChildren = true
            for group in groups {
                guard let item = describeGroup(group) else { continue }
                if isPresented { presentedItems.append(item) }
                if let existing = byID[item.id] {
                    // The same item appears once per display. Prefer the
                    // main-display occurrence (y ≈ 0 in CG top-left coords) so
                    // every frame lives in one coordinate space — boundary
                    // comparisons break across mixed display spaces.
                    if !isMainDisplayFrame(existing.frame), isMainDisplayFrame(item.frame) {
                        byID[item.id] = item
                    }
                } else {
                    byID[item.id] = item
                    order.append(item.id)
                }
            }
        }
        guard readWindowChildren else { return .unreadable }
        return ModernMenuBarSnapshot(
            items: order.compactMap { byID[$0] },
            isReadable: true,
            hasReadErrors: snapshotHadReadErrors,
            isMenuBarPresented: hasPresentedMenuBar || presentationHadReadErrors,
            presentedItems: presentedItems
        )
    }

    /// Fresh, bounded occupancy for click/hover decisions. Do not resolve app
    /// identities or deduplicate: unknown items and every display still occupy
    /// space, including Ice's own icon and the system overflow control.
    func snapshotOccupancy(at point: CGPoint, deadline: TimeInterval) -> ModernMenuBarOccupancy {
        var snapshot = ModernMenuBarOccupancy()
        guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline,
              let agent = resolveAgent(),
              let windows = occupancyAttribute(agent, kAXChildrenAttribute, deadline: deadline) as? [AXUIElement],
              !windows.isEmpty else { return snapshot }

        for window in windows {
            guard let role = occupancyAttribute(window, kAXRoleAttribute, deadline: deadline) as? String else { return snapshot }
            guard role == "AXWindow" else { continue }
            guard let windowFrame = occupancyFrame(window, deadline: deadline),
                  ModernMenuBarOccupancy.isUsable(windowFrame) else { return snapshot }
            // A retracted or busy bar on another display must not prevent
            // interaction with the readable bar under the pointer.
            guard windowFrame.contains(point) else { continue }
            guard let groups = occupancyAttribute(window, kAXChildrenAttribute, deadline: deadline) as? [AXUIElement],
                  !groups.isEmpty else { return snapshot }
            snapshot.windowFrames.append(windowFrame)
            for group in groups {
                guard let frame = occupancyFrame(group, deadline: deadline),
                      ModernMenuBarOccupancy.isUsable(frame, allowZeroWidth: true) else { return snapshot }
                snapshot.itemFrames.append(frame)
            }
        }
        snapshot.isComplete = !snapshot.windowFrames.isEmpty && !Task.isCancelled && ProcessInfo.processInfo.systemUptime <= deadline
        return snapshot
    }

    private func occupancyAttribute(_ element: AXUIElement, _ name: String, deadline: TimeInterval) -> CFTypeRef? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard !Task.isCancelled, remaining > 0 else { return nil }
        // Bound each remote message as well as the entire traversal. This runs
        // on a separate actor from the editor's slower identity discovery.
        guard AXUIElementSetMessagingTimeout(element, Float(min(remaining, 0.05))) == .success else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              !Task.isCancelled, ProcessInfo.processInfo.systemUptime <= deadline else { return nil }
        return value
    }

    private func occupancyFrame(_ element: AXUIElement, deadline: TimeInterval) -> CGRect? {
        guard let value = occupancyAttribute(element, "AXFrame", deadline: deadline),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        // The Core Foundation type ID was checked above.
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private func isMainDisplayFrame(_ frame: CGRect) -> Bool {
        abs(frame.minY - CGDisplayBounds(CGMainDisplayID()).minY) <= 2
    }

    // MARK: - Internals

    private func resolveAgent() -> AXUIElement? {
        if let cached = agentElement,
           NSRunningApplication(processIdentifier: agentPID)?.bundleIdentifier == Self.agentBundleID {
            return cached
        }
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == Self.agentBundleID
        }) else { return nil }
        let element = AXUIElementCreateApplication(agent.processIdentifier)
        // A stuck app must never wedge a snapshot.
        AXUIElementSetMessagingTimeout(element, 0.2)
        agentElement = element
        agentPID = agent.processIdentifier
        return element
    }

    private func describeGroup(_ group: AXUIElement) -> ModernMenuBarItem? {
        guard let frame = frame(of: group) else {
            snapshotHadReadErrors = true
            logDrop("no AXFrame", pid: nil, role: role(of: group))
            return nil
        }
        let kids = children(of: group)
        for child in kids {
            switch role(of: child) {
            case "AXApplication":
                // Third-party item: owning app nested right in the tree.
                let appName = copyAttribute(child, kAXTitleAttribute) as? String
                var appPID: pid_t = 0
                guard AXUIElementGetPid(child, &appPID) == .success else {
                    snapshotHadReadErrors = true
                    continue
                }
                guard let host = hostBundle(ofPID: appPID) else {
                    logDrop("no bundle id for AXApplication", pid: appPID, role: "AXApplication")
                    return nil
                }
                let title = statusItemTitle(in: child) ?? "Item-0"
                return ModernMenuBarItem(
                    id: .status(bundle: host.id, title: title),
                    frame: frame,
                    appName: appName,
                    hostIsBundleless: host.bundleless,
                    pid: appPID
                )
            case "AXGroup":
                // System item: AXGroup wrapping an AXMenuBarItem.
                for leaf in children(of: child) where role(of: leaf) == "AXMenuBarItem" {
                    guard let identifier = copyAttribute(leaf, kAXIdentifierAttribute) as? String else {
                        continue
                    }
                    return ModernMenuBarItem(
                        id: .status(bundle: Self.agentBundleID, title: identifier),
                        frame: frame,
                        appName: nil,
                        hostIsBundleless: false,
                        pid: agentPID
                    )
                }
            case "AXButton":
                // Plain NSStatusItem buttons (Pelmet's own chevron/separators,
                // Thaw's dividers) sit in the tree as bare AXButtons — no
                // nested AXApplication. Attribute by the button's owning pid.
                if let item = describeLeaf(child, frame: frame) { return item }
            default:
                continue
            }
        }
        // Nothing matched the known shapes (a custom status view exposed as
        // AXStaticText/AXUnknown, issue #1: Little Snitch's two-line traffic
        // monitor). Any child with an owning pid outside the agent still
        // names its app; attribute by that rather than dropping the item.
        for child in kids {
            var pid: pid_t = 0
            AXUIElementGetPid(child, &pid)
            guard pid > 0, pid != agentPID else { continue }
            if let item = describeLeaf(child, frame: frame) {
                logOnce("enumerate: fallback — role=\(roleLabel(child)) → \(item.id.rawValue)", pid: pid)
                return item
            }
        }
        logDrop("unrecognized children \(kids.map { roleLabel($0) })", pid: nil, role: nil)
        return nil
    }

    /// Item attributed by a leaf element's owning pid, titled by whichever of
    /// title / identifier / description the element exposes.
    private func describeLeaf(_ element: AXUIElement, frame: CGRect) -> ModernMenuBarItem? {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard pid > 0, let host = hostBundle(ofPID: pid) else {
            logDrop("no bundle id for leaf", pid: pid, role: role(of: element))
            return nil
        }
        let candidates = [
            copyAttribute(element, kAXTitleAttribute) as? String,
            copyAttribute(element, kAXIdentifierAttribute) as? String,
            copyAttribute(element, kAXDescriptionAttribute) as? String,
        ]
        let title = candidates.compactMap { $0?.isEmpty == false ? $0 : nil }.first ?? "Item-0"
        return ModernMenuBarItem(
            id: .status(bundle: host.id, title: title),
            frame: frame,
            appName: NSRunningApplication(processIdentifier: pid)?.localizedName,
            hostIsBundleless: host.bundleless,
            pid: pid
        )
    }

    /// `NSRunningApplication.bundleIdentifier` first; when the process is not
    /// registered as an application (helper agents nested in another app's
    /// Components/ folder), read the Info.plist of the nearest enclosing .app
    /// on its executable path — and say so, because such an item is filed
    /// under a bundle the assertion can never hide.
    private func hostBundle(ofPID pid: pid_t) -> HostBundle? {
        guard pid > 0 else { return nil }
        let app = NSRunningApplication(processIdentifier: pid)
        if let id = app?.bundleIdentifier { return HostBundle(id: id, bundleless: false) }
        var url = app?.executableURL ?? executableURL(ofPID: pid)
        while let current = url, current.path != "/" {
            if current.pathExtension == "app", let id = Bundle(url: current)?.bundleIdentifier {
                logOnce("enumerate: bundle-less host → \(id) (\(app?.executableURL?.lastPathComponent ?? "?"))", pid: pid)
                return HostBundle(id: id, bundleless: true)
            }
            url = current.deletingLastPathComponent()
        }
        return nil
    }

    private func executableURL(ofPID pid: pid_t) -> URL? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        // proc_pidpath returns the byte count it wrote, excluding the
        // terminator — decode exactly that rather than the whole buffer.
        let written = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard written > 0 else { return nil }
        guard let path = String(bytes: buffer[..<Int(written)], encoding: .utf8) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Each distinct drop is logged once per process lifetime: the walk runs
    /// on every converge and the same unrecognized group would flood the log.
    private var loggedDrops: Set<String> = []

    private func logDrop(_ reason: String, pid: pid_t?, role: String?) {
        var line = "enumerate: skipped — \(reason)"
        if let role { line += " role=\(role)" }
        logOnce(line, pid: pid)
    }

    private func logOnce(_ message: String, pid: pid_t?) {
        var line = message
        if let pid, pid > 0 {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? executableURL(ofPID: pid)?.lastPathComponent ?? "?"
            line += " pid=\(pid) (\(name))"
        }
        guard loggedDrops.insert(line).inserted else { return }
        NSLog("[Ice ModernMenuBar] %@", line)
    }

    /// Best-effort title of the app's status item button (used in the agent
    /// tag). An app node exposes both its MAIN menu bar (Apple, File, Edit…)
    /// and its status-extras bar; the agent names the extras bar explicitly
    /// (`kAXExtrasMenuBarAttribute`, present on every hosted app probed on
    /// macOS 27). Without it, the narrower bar is the extras bar. No width
    /// cap: a text item can make the extras bar wider than a main menu (#17),
    /// and a dropped title collides every item of that app on "Item-0".
    /// The hosted items' frames sit in the app's own off-screen space, never
    /// the agent group's, so geometry cannot pick among several items.
    private func statusItemTitle(in appNode: AXUIElement) -> String? {
        let menuBars = children(of: appNode).filter { role(of: $0) == "AXMenuBar" }
        let explicit = copyAttribute(appNode, kAXExtrasMenuBarAttribute)
            .flatMap { value -> AXUIElement? in
                guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                // CF types require a forced bridge after checking the runtime type ID.
                // swiftlint:disable:next force_cast
                return (value as! AXUIElement)
            }
        let extrasBar = explicit ?? menuBars.min { lhs, rhs in
            (frame(of: lhs)?.width ?? .greatestFiniteMagnitude)
                < (frame(of: rhs)?.width ?? .greatestFiniteMagnitude)
        }
        guard let extrasBar else { return nil }
        let titles = children(of: extrasBar).compactMap { item -> String? in
            let title = copyAttribute(item, kAXTitleAttribute) as? String
            return title?.isEmpty == false ? title : nil
        }
        // SystemUIServer's extras (Siri, Time Machine) hide as one bundle and
        // every group of its carries the same extras bar: name the lot, so
        // the one editor tile can list them ("Siri, TimeMachine", #19).
        if pid(of: appNode).flatMap(hostBundle(ofPID:))?.id == "com.apple.systemuiserver" {
            return titles.isEmpty ? nil : titles.joined(separator: ", ")
        }
        return titles.first
    }

    private func pid(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else {
            snapshotHadReadErrors = true
            return nil
        }
        return pid > 0 ? pid : nil
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
            snapshotHadReadErrors = true
            return []
        }
        return children
    }

    private func role(of element: AXUIElement) -> String {
        guard let role = copyAttribute(element, kAXRoleAttribute) as? String else {
            snapshotHadReadErrors = true
            return ""
        }
        return role
    }

    /// `role(of:)` reports a missing role as "", so the `?? "?"` the log
    /// sites used was dead and they printed `role=` with nothing after it.
    private func roleLabel(_ element: AXUIElement) -> String {
        let role = role(of: element)
        return role.isEmpty ? "?" : role
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        guard let value = copyAttribute(element, "AXFrame"),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        // The runtime type ID is checked above before bridging this CF value.
        // swiftlint:disable:next force_cast
        let axValue = value as! AXValue
        guard AXValueGetValue(axValue, .cgRect, &rect) else { return nil }
        return rect
    }

    /// Optional attributes may be absent; transport failures make the snapshot
    /// incomplete, so a missing item cannot be mistaken for successful hiding.
    nonisolated static func isIncompleteRead(_ error: AXError) -> Bool {
        error != .success && error != .attributeUnsupported && error != .noValue
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        let remaining = snapshotDeadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0, !Task.isCancelled else {
            snapshotHadReadErrors = true
            return nil
        }
        snapshotReadCount += 1
        AXUIElementSetMessagingTimeout(element, Float(min(0.2, remaining)))
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if Self.isIncompleteRead(error) {
            snapshotHadReadErrors = true
        }
        return error == .success ? value : nil
    }
}

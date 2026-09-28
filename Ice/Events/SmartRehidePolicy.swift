//
//  SmartRehidePolicy.swift
//  Ice
//

import AppKit

/// Decides whether a click outside the menu bar rehides sections.
///
/// Window titles (`kCGWindowName`) require Screen Recording. Owner, layer,
/// and bounds do not, so limited mode identifies the clicked window from
/// those instead of never finding one.
enum SmartRehidePolicy {
    struct Window: Equatable {
        var ownerPID: pid_t
        var bounds: CGRect
        var layer: Int
        var title: String?
    }

    struct Owner: Equatable {
        var bundleIdentifier: String?
        var isActive: Bool
        var activationPolicy: NSApplication.ActivationPolicy
    }

    static let dockBundleIdentifier = "com.apple.dock"

    /// Titles are trusted only with Screen Recording and when another
    /// process's normal-level window actually reports one. Without them the
    /// title filter would reject every window.
    static func titlesAvailable(permissionGranted: Bool, windows: [Window], ownPID: pid_t) -> Bool {
        permissionGranted && windows.contains { window in
            window.layer == Int(CGWindowLevelForKey(.normalWindow)) &&
            window.ownerPID != ownPID &&
            window.title != nil
        }
    }

    /// Returns the window the user clicked into, searching front to back.
    ///
    /// With titles, untitled windows are skipped as overlays (the original
    /// behavior). Without titles, windows of accessory and background
    /// processes are skipped instead; those own nearly all overlays. The Dock
    /// stays eligible because clicking it should still rehide.
    static func clickedWindow(
        in windows: [Window],
        at point: CGPoint,
        titlesAvailable: Bool,
        maximumLayer: Int,
        owner: (pid_t) -> Owner?
    ) -> (window: Window, owner: Owner)? {
        for window in windows where window.layer < maximumLayer && window.bounds.contains(point) {
            if titlesAvailable {
                guard window.title?.isEmpty == false else { continue }
                guard let owner = owner(window.ownerPID) else { return nil }
                return (window, owner)
            }
            guard
                let owner = owner(window.ownerPID),
                owner.activationPolicy == .regular || owner.bundleIdentifier == dockBundleIdentifier
            else {
                continue
            }
            return (window, owner)
        }
        return nil
    }

    /// Clicking the Dock, or into an active regular app, rehides.
    static func shouldRehide(owner: Owner) -> Bool {
        owner.bundleIdentifier == dockBundleIdentifier ||
        (owner.isActive && owner.activationPolicy == .regular)
    }
}

extension SmartRehidePolicy.Window {
    init(_ info: WindowInfo) {
        self.init(ownerPID: info.ownerPID, bounds: info.bounds, layer: info.layer, title: info.title)
    }
}

extension SmartRehidePolicy.Owner {
    init?(pid: pid_t) {
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }
        self.init(
            bundleIdentifier: application.bundleIdentifier,
            isActive: application.isActive,
            activationPolicy: application.activationPolicy
        )
    }
}

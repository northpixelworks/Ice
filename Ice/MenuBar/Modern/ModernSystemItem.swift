//
//  ModernSystemItem.swift
//  Ice
//

import Foundation

// Raw identifiers and AX mappings adapted from fif7y/Pelmet's MenuBarPolicy
// (GPL-3.0), revision 76db5715991a82e4583f93c360fba9807750d040.
enum ModernSystemItem: Int, CaseIterable {
    case battery = 0, bluetooth, clock, displays, keyboard, volume, wifi, screenMirroring
    case controlCenter

    var assignmentKey: String { "system:\(rawValue)" }
}

extension ModernItemID {
    var systemItem: ModernSystemItem? {
        if bundleID == "com.apple.TextInputMenuAgent" { return .keyboard }
        guard bundleID == "com.apple.MenuBarAgent" else { return nil }
        switch title {
        case "com.apple.menuextra.battery": return .battery
        case "com.apple.menuextra.bluetooth": return .bluetooth
        case "com.apple.menuextra.clock": return .clock
        case "com.apple.menuextra.display", "com.apple.menuextra.displays": return .displays
        case "com.apple.menuextra.textinput", "com.apple.menuextra.keyboard": return .keyboard
        case "com.apple.menuextra.sound": return .volume
        case "com.apple.menuextra.wifi": return .wifi
        case "com.apple.menuextra.screen-mirroring": return .screenMirroring
        default: return nil // Control Center cannot be hidden by this API.
        }
    }

    var isUserSwitcher: Bool {
        bundleID == "com.apple.MenuBarAgent" && title == "com.apple.menuextra.user"
    }

    var assignmentKey: String {
        if let systemItem { return systemItem.assignmentKey }
        if isUserSwitcher { return ModernVisibilityPlan.otherSystemExtrasKey }
        return bundleID
    }

    var supportsHiding: Bool {
        systemItem != nil || isUserSwitcher || Self.supportsBundleHiding(bundleID)
    }

    static func supportsBundleHiding(_ bundle: String) -> Bool {
        // SystemUIServer's legacy extras (including Siri) hide together.
        bundle == "com.apple.systemuiserver" || !bundle.hasPrefix("com.apple.")
    }

    var displaySymbol: String? {
        if title == "Spotlight" { return "magnifyingglass" }
        if isUserSwitcher { return "person.crop.circle" }
        if title == "com.apple.menuextra.controlcenter" { return "switch.2" }
        if title == "com.apple.menuextra.focusmode" { return "moon.fill" }
        if title == "com.apple.menuextra.now-playing" { return "play.circle.fill" }
        switch systemItem {
        case .battery: return "battery.100percent"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .clock: return "clock.fill"
        case .displays: return "display"
        case .keyboard: return "keyboard"
        case .volume: return "speaker.wave.2.fill"
        case .wifi: return "wifi"
        case .screenMirroring: return "rectangle.on.rectangle"
        default: return nil
        }
    }

    var systemDisplayName: String? {
        if isUserSwitcher { return "User" }
        if title == "Spotlight" { return "Spotlight" }
        if title == "com.apple.menuextra.focusmode" { return "Focus" }
        if title == "com.apple.menuextra.now-playing" { return "Now Playing" }
        if title == "com.apple.menuextra.controlcenter" { return "Control Center" }
        switch systemItem {
        case .battery: return "Battery"
        case .bluetooth: return "Bluetooth"
        case .clock: return "Clock"
        case .displays: return "Display"
        case .keyboard: return "Input Menu"
        case .volume: return "Sound"
        case .wifi: return "Wi-Fi"
        case .screenMirroring: return "Screen Mirroring"
        default: return nil
        }
    }
}

/// The complete assertion state, including system-only hiding requests.
struct ModernVisibilityPlan: Equatable {
    static let otherSystemExtrasKey = "system:other-extras"
    var bundles: Set<String> = []
    var systemItems: Set<ModernSystemItem> = []
    var hideOtherSystemExtras = false

    var requiresAssertion: Bool {
        !bundles.isEmpty || !systemItems.isEmpty || hideOtherSystemExtras
    }

    var allowedSystemItems: [ModernSystemItem] {
        ModernSystemItem.allCases.filter { !systemItems.contains($0) }
    }

    func allowedBundles(runningBundles: Set<String>, ownBundle: String) -> Set<String> {
        var allowed = runningBundles.subtracting(bundles)
        // The input menu is hosted by a separate app. Allowing that host
        // overrides removing keyboard from the system-item allowlist on macOS 27.
        if systemItems.contains(.keyboard) {
            allowed.remove("com.apple.TextInputMenuAgent")
        }
        return allowed.union([ownBundle])
    }

    func conceals(_ id: ModernItemID) -> Bool {
        if let system = id.systemItem { return systemItems.contains(system) }
        // macOS removes the User menu and optional CC extras whenever ANY
        // assertion is active; it has no individual exemption for them.
        if id.isUserSwitcher { return requiresAssertion }
        return bundles.contains(id.bundleID)
    }
}

/// A running process as the assertion allowlist sees it.
struct ModernRunningApplication: Equatable {
    var bundleID: String
    /// Background-only (`.prohibited`) processes cannot show status items.
    var canOwnStatusItem: Bool
}

/// Decides when a newly running application requires a new assertion.
///
/// Bundles missing from the allowlist are hidden while an assertion is
/// active, and hidden items never reach MenuBarAgent's Accessibility tree.
/// Observed items therefore cannot drive this decision; the running set can.
enum ModernAllowlistReapply {
    /// Bundles that may own a status item, are allowed by the current plan,
    /// and are missing from the active assertion. Terminations and
    /// background-only helpers never require reapplying.
    static func missingBundles(
        allowed: Set<String>,
        applied: Set<String>,
        running: [ModernRunningApplication]
    ) -> Set<String> {
        Set(running.filter(\.canOwnStatusItem).map(\.bundleID))
            .intersection(allowed)
            .subtracting(applied)
    }

    /// Bundles allowed earlier stay allowed while their saved section is
    /// visible, so quitting and relaunching one needs no new assertion.
    static func candidateBundles(
        running: Set<String>,
        previouslyAllowed: Set<String>,
        concealedAssignments: Set<String>
    ) -> Set<String> {
        running.union(previouslyAllowed.subtracting(concealedAssignments))
    }
}

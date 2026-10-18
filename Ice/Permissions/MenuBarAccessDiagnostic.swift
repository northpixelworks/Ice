//
//  MenuBarAccessDiagnostic.swift
//  Ice
//

import Foundation

/// Keep denied process access distinct from an authorized but unreadable menu bar.
enum MenuBarAccessDiagnostic: Equatable {
    case accessibilityDenied
    case reading
    case noItems

    static func select(isTrusted: Bool, hasItems: Bool, isRefreshing: Bool) -> Self? {
        guard isTrusted else { return .accessibilityDenied }
        guard !hasItems else { return nil }
        return isRefreshing ? .reading : .noItems
    }

    static func repairGuidance(appPath: String) -> String {
        "macOS is not granting Accessibility access to this copy of Ice. If Ice is already enabled in System Settings, remove its Accessibility entry and add Ice again from \(appPath), then retry. Ice cannot tell whether access was never granted or an older app entry is being used."
    }
}

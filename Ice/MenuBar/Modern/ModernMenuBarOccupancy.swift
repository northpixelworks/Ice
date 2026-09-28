//
//  ModernMenuBarOccupancy.swift
//  Ice
//

import CoreGraphics
import Foundation

/// Pure geometry shared by pointer handling and visibility verification.
enum ModernMenuBarGeometry {
    static func isPresented(_ menuBar: CGRect, on displays: [CGRect]) -> Bool {
        guard ModernMenuBarOccupancy.isUsable(menuBar), menuBar.height > 1 else { return false }
        return displays.contains { display in
            display.contains(menuBar) && abs(menuBar.minY - display.minY) <= 1
        }
    }

    /// AppKit coordinates. A retracted bar owns only its reveal edge, not the
    /// title bar or toolbar of the application underneath it.
    static func interactionFrame(screen: CGRect, height: CGFloat, isRetracted: Bool) -> CGRect {
        let visibleHeight = isRetracted ? 1 : max(1, min(height, screen.height))
        return CGRect(x: screen.minX, y: screen.maxY - visibleHeight, width: screen.width, height: visibleHeight)
    }
}

/// Interaction geometry is deliberately independent of editor identities. One app
/// can own several status items, and each item can occur on several displays.
struct ModernMenuBarOccupancy: Sendable {
    static let maximumSnapshotDuration: TimeInterval = 0.4

    var windowFrames: [CGRect] = []
    var itemFrames: [CGRect] = []
    var isComplete = false

    static func isUsable(_ frame: CGRect, allowZeroWidth: Bool = false) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite &&
        frame.size.width.isFinite && frame.size.height.isFinite &&
        frame.maxX.isFinite && frame.maxY.isFinite &&
        (allowZeroWidth ? frame.size.width >= 0 : frame.size.width > 0) && frame.size.height > 0
    }

    func confirmsEmptySpace(at point: CGPoint, requestedAt: TimeInterval, now: TimeInterval) -> Bool {
        guard isComplete, point.x.isFinite, point.y.isFinite,
              now >= requestedAt, now - requestedAt <= Self.maximumSnapshotDuration,
              !windowFrames.isEmpty,
              windowFrames.allSatisfy({ Self.isUsable($0) }),
              itemFrames.allSatisfy({ Self.isUsable($0, allowZeroWidth: true) }),
              windowFrames.contains(where: { $0.contains(point) }) else { return false }
        return !itemFrames.contains(where: { $0.contains(point) })
    }
}

/// A delayed action belongs to the exact pointer position and input generation
/// that requested it. Moving away and back must not revive an earlier click.
struct ModernMenuBarInteractionIntent {
    static let jitterTolerance: CGFloat = 4

    let point: CGPoint
    let generation: UInt64

    func isCurrent(point: CGPoint?, generation: UInt64) -> Bool {
        guard self.generation == generation, let point else { return false }
        return hypot(self.point.x - point.x, self.point.y - point.y) <= Self.jitterTolerance
    }

    /// Whether a drag or scroll event leaves this intent pending. Any pointer
    /// event ends a hover intent. A click intent survives jitter: pressing a
    /// button can report a one- or two-point drag, and scrolling does not
    /// move the pointer.
    func survivesPointerEvent(at point: CGPoint?, generation: UInt64, isHover: Bool) -> Bool {
        !isHover && isCurrent(point: point, generation: generation)
    }
}

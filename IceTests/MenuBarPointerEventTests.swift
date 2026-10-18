import AppKit
import XCTest
@testable import Ice

/// Drives `EventManager` through the same methods its drag and scroll
/// monitors call, and `NSScreen` through the frame pointer handling reads.
final class MenuBarPointerEventTests: XCTestCase {
    private let point = CGPoint(x: 900, y: 12)

    /// Starts an intent whose action records whether it ran uncancelled.
    @MainActor
    private func startIntent(on events: EventManager, isHover: Bool, fired: @escaping @MainActor () -> Void) {
        events.startModernIntent(at: point, isHover: isHover) { _ in
            try? await Task.sleep(for: .milliseconds(100))
            if !Task.isCancelled { fired() }
        }
    }

    /// C5 regression: pressing a button can report a one- or two-point drag,
    /// and a scroll can arrive while a click waits. Neither may drop the click.
    @MainActor
    func testDragAndScrollJitterKeepPendingClick() async throws {
        let events = EventManager()
        var fired = false
        startIntent(on: events, isHover: false) { fired = true }

        events.modernPointerEventOccurred("drag", at: CGPoint(x: point.x + 2, y: point.y + 1))
        events.modernPointerEventOccurred("scroll", at: CGPoint(x: point.x + 2, y: point.y + 1))
        events.modernPointerEventOccurred("drag", at: CGPoint(x: point.x, y: point.y + 4))
        XCTAssertTrue(events.hasPendingModernIntent, "Jitter within four points must keep the click")

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(fired, "The click action must still run")
        XCTAssertFalse(events.hasPendingModernIntent)
    }

    @MainActor
    func testDragBeyondToleranceCancelsPendingClick() async throws {
        let events = EventManager()
        var fired = false
        startIntent(on: events, isHover: false) { fired = true }

        events.modernPointerEventOccurred("drag", at: CGPoint(x: point.x + 5, y: point.y))
        XCTAssertFalse(events.hasPendingModernIntent)
        // Moving back does not revive it.
        events.modernPointerEventOccurred("drag", at: point)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(fired)

        startIntent(on: events, isHover: false) { fired = true }
        events.modernPointerEventOccurred("scroll", at: nil)
        XCTAssertFalse(events.hasPendingModernIntent, "An unknown pointer location cannot keep a click")
    }

    @MainActor
    func testAnyDragOrScrollCancelsPendingHover() async throws {
        let events = EventManager()
        var fired = false
        startIntent(on: events, isHover: true) { fired = true }
        events.modernPointerEventOccurred("drag", at: point)
        XCTAssertFalse(events.hasPendingModernIntent)

        startIntent(on: events, isHover: true) { fired = true }
        events.modernPointerEventOccurred("scroll", at: point)
        XCTAssertFalse(events.hasPendingModernIntent)

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(fired)
    }

    /// C2 regression: the menu bar frame is read on every scroll event (and
    /// every mouse move with show-on-hover). Each read of the auto-hide
    /// preference used to copy the whole global defaults domain.
    @MainActor
    func testMenuBarFrameReusesOneAutoHidePreferenceRead() throws {
        let screen = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first)
        let original = Defaults.MenuBarAutoHide.read
        var reads = 0
        Defaults.MenuBarAutoHide.read = {
            reads += 1
            return false
        }
        Defaults.MenuBarAutoHide.invalidate()
        defer {
            Defaults.MenuBarAutoHide.read = original
            Defaults.MenuBarAutoHide.invalidate()
        }

        let top = CGPoint(x: screen.frame.midX, y: screen.frame.maxY - 1)
        for _ in 0..<100 {
            _ = screen.containsAppKitMenuBarPoint(top)
        }
        XCTAssertEqual(reads, 1, "A burst of pointer events must share one preference read")
    }

    @MainActor
    func testAutoHidePreferenceIsRereadAfterMaximumAge() {
        let original = Defaults.MenuBarAutoHide.read
        var stored = false
        var reads = 0
        Defaults.MenuBarAutoHide.read = {
            reads += 1
            return stored
        }
        Defaults.MenuBarAutoHide.invalidate()
        defer {
            Defaults.MenuBarAutoHide.read = original
            Defaults.MenuBarAutoHide.invalidate()
        }

        XCTAssertFalse(Defaults.MenuBarAutoHide.isEnabled(now: 100))
        stored = true
        XCTAssertFalse(Defaults.MenuBarAutoHide.isEnabled(now: 100.5), "Within a second the cached value is reused")
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(Defaults.MenuBarAutoHide.isEnabled(now: 100 + Defaults.MenuBarAutoHide.maximumAge))
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(Defaults.MenuBarAutoHide.isEnabled(now: 50), "A clock that moved backwards forces a read")
        XCTAssertEqual(reads, 3)
    }
}

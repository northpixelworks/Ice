import AppKit
import XCTest
@testable import Ice

/// Drives `NSScreen` through the menu bar frame that pointer handling reads.
final class MenuBarPointerEventTests: XCTestCase {
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

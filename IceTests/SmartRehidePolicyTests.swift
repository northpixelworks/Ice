import AppKit
import XCTest
@testable import Ice

final class SmartRehidePolicyTests: XCTestCase {
    private let ownPID: pid_t = 1
    private let dockPID: pid_t = 2
    private let finderPID: pid_t = 3
    private let overlayPID: pid_t = 4
    private let safariPID: pid_t = 5
    private let windowServerPID: pid_t = 6
    private let cursorLayer = Int(CGWindowLevelForKey(.cursorWindow))
    private let click = CGPoint(x: 400, y: 400)

    private func owners(active: pid_t) -> (pid_t) -> SmartRehidePolicy.Owner? {
        { pid in
            switch pid {
            case self.ownPID:
                return SmartRehidePolicy.Owner(bundleIdentifier: "ice", isActive: pid == active, activationPolicy: .accessory)
            case self.dockPID:
                return SmartRehidePolicy.Owner(bundleIdentifier: "com.apple.dock", isActive: pid == active, activationPolicy: .accessory)
            case self.finderPID:
                return SmartRehidePolicy.Owner(bundleIdentifier: "com.apple.finder", isActive: pid == active, activationPolicy: .regular)
            case self.overlayPID:
                return SmartRehidePolicy.Owner(bundleIdentifier: "example.overlay", isActive: pid == active, activationPolicy: .accessory)
            case self.safariPID:
                return SmartRehidePolicy.Owner(bundleIdentifier: "com.apple.Safari", isActive: pid == active, activationPolicy: .regular)
            default:
                return nil // Window Server has no running application.
            }
        }
    }

    /// Front to back: a transparent overlay, the clicked Safari window, the
    /// Finder desktop, and a Window Server backdrop.
    private func windows(titled: Bool) -> [SmartRehidePolicy.Window] {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        return [
            .init(ownerPID: overlayPID, bounds: screen, layer: 3, title: titled ? "" : nil),
            .init(ownerPID: safariPID, bounds: CGRect(x: 100, y: 100, width: 800, height: 600), layer: 0, title: titled ? "Start Page" : nil),
            .init(ownerPID: finderPID, bounds: screen, layer: -2_147_483_603, title: titled ? "" : nil),
            .init(ownerPID: windowServerPID, bounds: screen, layer: -2_147_483_626, title: nil),
        ]
    }

    private func decision(_ windows: [SmartRehidePolicy.Window], at point: CGPoint? = nil, titled: Bool, active: pid_t) -> Bool {
        guard let target = SmartRehidePolicy.clickedWindow(
            in: windows,
            at: point ?? click,
            titlesAvailable: titled,
            maximumLayer: cursorLayer,
            owner: owners(active: active)
        ) else {
            return false
        }
        return SmartRehidePolicy.shouldRehide(owner: target.owner)
    }

    // MARK: Titles available (Screen Recording)

    func testTitlesRequireScreenRecordingAndATitledNormalWindow() {
        XCTAssertTrue(SmartRehidePolicy.titlesAvailable(permissionGranted: true, windows: windows(titled: true), ownPID: ownPID))
        XCTAssertFalse(SmartRehidePolicy.titlesAvailable(permissionGranted: false, windows: windows(titled: true), ownPID: ownPID))
        // Limited mode: only Window Server and desktop-level system windows
        // (and Ice's own windows) still report names.
        let limited = windows(titled: false) + [
            .init(ownerPID: windowServerPID, bounds: CGRect(x: 0, y: 0, width: 1512, height: 33), layer: 24, title: "Menubar"),
            .init(ownerPID: 7, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), layer: -2_147_483_624, title: "Wallpaper"),
            .init(ownerPID: ownPID, bounds: CGRect(x: 600, y: 33, width: 800, height: 700), layer: 0, title: "Ice"),
        ]
        XCTAssertFalse(SmartRehidePolicy.titlesAvailable(permissionGranted: true, windows: limited, ownPID: ownPID))
    }

    func testWithTitlesUntitledOverlayIsSkippedAndActiveWindowRehides() {
        let target = SmartRehidePolicy.clickedWindow(
            in: windows(titled: true),
            at: click,
            titlesAvailable: true,
            maximumLayer: cursorLayer,
            owner: owners(active: safariPID)
        )
        XCTAssertEqual(target?.window.ownerPID, safariPID)
        XCTAssertTrue(decision(windows(titled: true), titled: true, active: safariPID))
    }

    func testWithTitlesInactiveClickedWindowDoesNotRehide() {
        XCTAssertFalse(decision(windows(titled: true), titled: true, active: finderPID))
    }

    func testWithTitlesMissingOwnerDoesNotFallThrough() {
        let windows = [
            SmartRehidePolicy.Window(ownerPID: windowServerPID, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), layer: 0, title: "Backdrop"),
        ] + windows(titled: true)
        XCTAssertFalse(decision(windows, titled: true, active: safariPID))
    }

    // MARK: No titles (limited mode)

    /// Regression: with every title nil, the title filter found no window,
    /// so smart rehide never fired without Screen Recording.
    func testWithoutTitlesClickIntoActiveAppRehides() {
        let target = SmartRehidePolicy.clickedWindow(
            in: windows(titled: false),
            at: click,
            titlesAvailable: false,
            maximumLayer: cursorLayer,
            owner: owners(active: safariPID)
        )
        XCTAssertEqual(target?.window.ownerPID, safariPID, "Accessory overlays are skipped")
        XCTAssertTrue(decision(windows(titled: false), titled: false, active: safariPID))
    }

    func testWithoutTitlesInactiveOrAccessoryTargetDoesNotRehide() {
        // The clicked window did not activate its app.
        XCTAssertFalse(decision(windows(titled: false), titled: false, active: finderPID))
        // An accessory panel took focus; the regular window below it is inactive.
        XCTAssertFalse(decision(windows(titled: false), titled: false, active: overlayPID))
    }

    func testWithoutTitlesDesktopClickRehidesThroughFinder() {
        XCTAssertTrue(decision(windows(titled: false), at: CGPoint(x: 1200, y: 800), titled: false, active: finderPID))
    }

    func testWithoutTitlesDockRemainsAnException() {
        let dock = SmartRehidePolicy.Window(
            ownerPID: dockPID,
            bounds: CGRect(x: 0, y: 900, width: 1512, height: 82),
            layer: Int(CGWindowLevelForKey(.dockWindow)),
            title: nil
        )
        XCTAssertTrue(decision([dock] + windows(titled: false), at: CGPoint(x: 700, y: 940), titled: false, active: safariPID))
    }

    func testWithoutTitlesWindowServerAndCursorLayersAreIgnored() {
        let cursor = SmartRehidePolicy.Window(ownerPID: safariPID, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982), layer: cursorLayer, title: nil)
        let windows = [cursor] + windows(titled: false).filter { $0.ownerPID == windowServerPID }
        XCTAssertNil(SmartRehidePolicy.clickedWindow(
            in: windows,
            at: click,
            titlesAvailable: false,
            maximumLayer: cursorLayer,
            owner: owners(active: safariPID)
        ))
    }
}

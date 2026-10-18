import XCTest
@testable import Ice

final class ModernMenuBarOccupancyTests: XCTestCase {
    private let bar = CGRect(x: 0, y: 0, width: 1440, height: 26)

    func testRetractedBarDoesNotOwnApplicationToolbar() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = ModernMenuBarGeometry.interactionFrame(screen: screen, height: 26, isRetracted: true)
        XCTAssertTrue(frame.contains(CGPoint(x: 700, y: 899.5)))
        XCTAssertFalse(frame.contains(CGPoint(x: 700, y: 885)))
        XCTAssertEqual(frame.height, 1)
    }

    func testPresentedBarAndNotchedDisplayUseTheirActualHeight() {
        let screen = CGRect(x: -1512, y: 200, width: 1512, height: 982)
        let frame = ModernMenuBarGeometry.interactionFrame(screen: screen, height: 38, isRetracted: false)
        XCTAssertEqual(frame, CGRect(x: -1512, y: 1144, width: 1512, height: 38))
        XCTAssertTrue(frame.contains(CGPoint(x: -800, y: 1150)))
        XCTAssertFalse(frame.contains(CGPoint(x: 800, y: 1150)))
    }

    func testRetractionAndPartialRevealAreNotVisibilityEvidence() {
        let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertTrue(ModernMenuBarGeometry.isPresented(bar, on: [display]))
        XCTAssertFalse(ModernMenuBarGeometry.isPresented(bar.offsetBy(dx: 0, dy: -26), on: [display]))
        XCTAssertFalse(ModernMenuBarGeometry.isPresented(bar.offsetBy(dx: 0, dy: -12), on: [display]))
        XCTAssertFalse(ModernMenuBarGeometry.isPresented(CGRect(x: 0, y: 0, width: 1440, height: 1), on: [display]))
        XCTAssertFalse(ModernMenuBarGeometry.isPresented(.null, on: [display]))
    }

    func testPresentedBarUsesDisplayOriginNotMainScreenOrigin() {
        let display = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let secondaryBar = CGRect(x: -1920, y: -200, width: 1920, height: 26)
        XCTAssertTrue(ModernMenuBarGeometry.isPresented(secondaryBar, on: [display]))
        XCTAssertFalse(ModernMenuBarGeometry.isPresented(secondaryBar.offsetBy(dx: 0, dy: -26), on: [display]))
    }

    private func approves(_ snapshot: ModernMenuBarOccupancy, _ point: CGPoint, elapsed: TimeInterval = 0.05) -> Bool {
        snapshot.confirmsEmptySpace(at: point, requestedAt: 10, now: 10 + elapsed)
    }

    func testEveryIconOfOneAppOccupiesSpaceWithoutAnEditorIdentity() {
        // All three tracker groups can share one editor ID/title. Interaction
        // geometry must preserve every frame, even if the editor shows one tile.
        let frames = [900, 940, 980].map { CGRect(x: $0, y: 0, width: 32, height: 26) }
        let snapshot = ModernMenuBarOccupancy(windowFrames: [bar], itemFrames: frames, isComplete: true)
        for frame in frames {
            XCTAssertFalse(approves(snapshot, CGPoint(x: frame.midX, y: frame.midY)))
        }
        XCTAssertTrue(approves(snapshot, CGPoint(x: 850, y: 13)))
    }

    func testUnknownAppIceAndOverflowGroupsStillBlockEmptySpaceActions() {
        // Occupancy has no bundle-name or known-role filter. Each raw group,
        // including Ice and macOS's overflow control, excludes its whole frame.
        let frames = [
            CGRect(x: 850, y: 0, width: 30, height: 26),
            CGRect(x: 890, y: 0, width: 25, height: 26),
            CGRect(x: 925, y: 0, width: 35, height: 26),
        ]
        let snapshot = ModernMenuBarOccupancy(windowFrames: [bar], itemFrames: frames, isComplete: true)
        XCTAssertFalse(approves(snapshot, CGPoint(x: 860, y: 13)))
        XCTAssertFalse(approves(snapshot, CGPoint(x: 900, y: 13)))
        XCTAssertFalse(approves(snapshot, CGPoint(x: 940, y: 13)))
    }

    func testSecondaryAndVerticallyOffsetDisplaysKeepTheirOwnOccupancy() {
        let secondBar = CGRect(x: -1920, y: -200, width: 1920, height: 26)
        let frames = [
            CGRect(x: 1000, y: 0, width: 50, height: 26),
            CGRect(x: -500, y: -200, width: 50, height: 26),
        ]
        let snapshot = ModernMenuBarOccupancy(windowFrames: [bar, secondBar], itemFrames: frames, isComplete: true)
        XCTAssertFalse(approves(snapshot, CGPoint(x: -475, y: -187)))
        XCTAssertTrue(approves(snapshot, CGPoint(x: -600, y: -187)))
        XCTAssertFalse(approves(snapshot, CGPoint(x: -600, y: 13)))
    }

    func testFreshReflowFramesOverrideAFormerlyEmptyPoint() {
        let point = CGPoint(x: 950, y: 13)
        let before = ModernMenuBarOccupancy(windowFrames: [bar], itemFrames: [CGRect(x: 1000, y: 0, width: 40, height: 26)], isComplete: true)
        let after = ModernMenuBarOccupancy(windowFrames: [bar], itemFrames: [CGRect(x: 930, y: 0, width: 80, height: 26)], isComplete: true)
        XCTAssertTrue(approves(before, point))
        XCTAssertFalse(approves(after, point))
    }

    func testIncompleteMissingOrInvalidGeometryCannotApproveEmptySpace() {
        let point = CGPoint(x: 900, y: 13)
        for snapshot in [
            ModernMenuBarOccupancy(),
            ModernMenuBarOccupancy(windowFrames: [bar], isComplete: false),
            ModernMenuBarOccupancy(isComplete: true),
            ModernMenuBarOccupancy(windowFrames: [.zero], isComplete: true),
            ModernMenuBarOccupancy(windowFrames: [bar], itemFrames: [.null], isComplete: true),
            ModernMenuBarOccupancy(windowFrames: [bar], itemFrames: [CGRect(x: 800, y: 0, width: -1, height: 26)], isComplete: true),
        ] {
            XCTAssertFalse(approves(snapshot, point))
        }
    }

    func testWindowCoverageIsRequiredEvenWithNoNearbyGroups() {
        let partialBar = CGRect(x: 1000, y: 0, width: 440, height: 26)
        let snapshot = ModernMenuBarOccupancy(windowFrames: [partialBar], itemFrames: [], isComplete: true)
        XCTAssertFalse(approves(snapshot, CGPoint(x: 900, y: 13)))
        XCTAssertFalse(approves(snapshot, CGPoint(x: 1100, y: 40)))
        XCTAssertTrue(approves(snapshot, CGPoint(x: 1100, y: 13)))
    }

    func testZeroWidthDividerDoesNotHideRealEmptySpace() {
        let snapshot = ModernMenuBarOccupancy(windowFrames: [bar], itemFrames: [CGRect(x: 900, y: 0, width: 0, height: 26)], isComplete: true)
        XCTAssertTrue(approves(snapshot, CGPoint(x: 910, y: 13)))
    }

    func testSlowOrQueuedAXReplyCannotApproveAnOldAction() {
        let snapshot = ModernMenuBarOccupancy(windowFrames: [bar], isComplete: true)
        let point = CGPoint(x: 900, y: 13)
        XCTAssertTrue(approves(snapshot, point))
        XCTAssertFalse(approves(snapshot, point, elapsed: 0.41))
        XCTAssertFalse(approves(snapshot, point, elapsed: 3))
        XCTAssertFalse(approves(snapshot, point, elapsed: -1))
    }

    func testMovedPointerOrNewClickInvalidatesPendingActionEvenAfterMovingBack() {
        let point = CGPoint(x: 900, y: 13)
        let intent = ModernMenuBarInteractionIntent(point: point, generation: 10)
        XCTAssertTrue(intent.isCurrent(point: point, generation: 10))
        XCTAssertTrue(intent.isCurrent(point: CGPoint(x: 901, y: 13), generation: 10))
        XCTAssertTrue(intent.isCurrent(point: CGPoint(x: 904, y: 13), generation: 10))
        XCTAssertFalse(intent.isCurrent(point: CGPoint(x: 905, y: 13), generation: 10))
        XCTAssertFalse(intent.isCurrent(point: point, generation: 11))
        XCTAssertFalse(intent.isCurrent(point: nil, generation: 10))
    }
}

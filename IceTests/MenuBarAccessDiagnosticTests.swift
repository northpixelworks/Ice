import XCTest
@testable import Ice

final class MenuBarAccessDiagnosticTests: XCTestCase {
    func testDeniedAccessTakesPriorityOverAnEmptySnapshot() {
        XCTAssertEqual(
            MenuBarAccessDiagnostic.select(isTrusted: false, hasItems: false, isRefreshing: false),
            .accessibilityDenied
        )
    }

    func testDeniedAccessIsNotHiddenByCachedItemsOrAnInFlightRefresh() {
        XCTAssertEqual(
            MenuBarAccessDiagnostic.select(isTrusted: false, hasItems: true, isRefreshing: true),
            .accessibilityDenied
        )
    }

    func testAuthorizedEmptySnapshotIsNotCalledAPermissionFailure() {
        XCTAssertEqual(
            MenuBarAccessDiagnostic.select(isTrusted: true, hasItems: false, isRefreshing: false),
            .noItems
        )
        XCTAssertEqual(
            MenuBarAccessDiagnostic.select(isTrusted: true, hasItems: false, isRefreshing: true),
            .reading
        )
    }

    func testAuthorizedItemsHaveNoDiagnostic() {
        XCTAssertNil(MenuBarAccessDiagnostic.select(isTrusted: true, hasItems: true, isRefreshing: false))
    }

    func testRepairGuidanceUsesTheRunningAppPathWithoutClaimingTheCause() {
        let message = MenuBarAccessDiagnostic.repairGuidance(appPath: "/Applications/Ice.app")
        XCTAssertTrue(message.contains("/Applications/Ice.app"))
        XCTAssertTrue(message.contains("If Ice is already enabled"))
        XCTAssertTrue(message.contains("cannot tell"))
    }

    @MainActor
    func testExplicitRetryRechecksAccessAfterPeriodicChecksStop() {
        var trusted = false
        let permission = Permission(
            title: "Test", details: [], isRequired: true, settingsURL: nil,
            check: { trusted }, request: {}
        )
        permission.stopCheck()
        XCTAssertFalse(permission.hasPermission)
        trusted = true
        XCTAssertTrue(permission.refresh())
        XCTAssertTrue(permission.hasPermission)
        trusted = false
        XCTAssertFalse(permission.refresh())
        XCTAssertFalse(permission.hasPermission)
    }
}

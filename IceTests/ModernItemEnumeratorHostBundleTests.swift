import XCTest
@testable import Ice

final class ModernItemEnumeratorHostBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HostBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Wine reports executables as ".../lib/wine/../../bin/wine". Walking that
    /// path up used to append "/.." forever (100% CPU, unbounded memory).
    func testWinePathWithDotDotTerminatesWithoutBundle() {
        let wine = root.appendingPathComponent("engine/lib/wine/../../bin/wine")
        XCTAssertNil(walkWithTimeout(wine))
    }

    func testDotDotPathStillFindsEnclosingApp() throws {
        let app = root.appendingPathComponent("Host.app", isDirectory: true)
        try makeAppBundle(at: app, id: "com.example.host")
        let helper = app.appendingPathComponent("Contents/lib/wine/../../MacOS/helper")
        XCTAssertEqual(walkWithTimeout(helper), "com.example.host")
    }

    func testRelativePathTerminatesWithoutBundle() {
        XCTAssertNil(walkWithTimeout(URL(fileURLWithPath: "../../bin/wine", relativeTo: nil)))
    }

    /// Runs the walk on a background thread so a regression fails the test
    /// instead of hanging the whole run.
    private func walkWithTimeout(_ url: URL, file: StaticString = #filePath, line: UInt = #line) -> String? {
        let done = XCTestExpectation(description: "walk finished")
        let result = Box()
        DispatchQueue.global().async {
            result.value = ModernItemEnumerator.enclosingAppBundleID(ofExecutable: url)
            done.fulfill()
        }
        let outcome = XCTWaiter().wait(for: [done], timeout: 2)
        XCTAssertEqual(outcome, .completed, "path walk did not terminate", file: file, line: line)
        return result.value
    }

    private func makeAppBundle(at app: URL, id: String) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contents.appendingPathComponent("MacOS", isDirectory: true),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}

private final class Box: @unchecked Sendable {
    var value: String?
}

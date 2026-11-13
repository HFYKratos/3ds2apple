import XCTest

@MainActor
final class PreviewSnapshotTests: XCTestCase {
    func testRenderShellScreens() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("3ds2apple-ui-shots")
        let written = SnapshotRenderer.renderAll(to: directory)
        XCTAssertFalse(written.isEmpty, "no screenshots were written")
    }
}
import XCTest
@testable import OpenUsage

@MainActor
final class ProviderMarksTests: XCTestCase {
    func testProviderVectorMarksLoadWithoutFallbacks() throws {
        for id in ["claude", "codex", "cursor", "devin", "grok", "muse"] {
            let mark = try XCTUnwrap(ProviderMarks.mark(for: id), "\(id) should load a vector mark")
            XCTAssertFalse(mark.path.isEmpty, "\(id) mark must carry SVG path data")
        }

        let muse = try XCTUnwrap(ProviderMarks.mark(for: "muse"))
        XCTAssertGreaterThan(muse.bounds.width, 20, "Muse mark must render the full Meta loop")
        XCTAssertGreaterThan(muse.bounds.height, 14, "Muse mark must render the full Meta loop")
    }

}

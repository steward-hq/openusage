import XCTest
import SwiftUI
@testable import OpenUsage

@MainActor
final class ProviderMarksTests: XCTestCase {
    func testProviderVectorMarksLoadWithoutFallbacks() throws {
        let activeProviders = [
            "claude", "codex", "grok", "antigravity",
            "muse", "ollama", "opencode", "synthetic"
        ]
        for id in activeProviders {
            let mark = try XCTUnwrap(ProviderMarks.mark(for: id), "\(id) should load a vector mark")
            XCTAssertFalse(mark.path.isEmpty, "\(id) mark must carry SVG path data")
            XCTAssertGreaterThan(mark.bounds.width, 0, "\(id) mark must have non-zero width")
            XCTAssertGreaterThan(mark.bounds.height, 0, "\(id) mark must have non-zero height")
        }

        let muse = try XCTUnwrap(ProviderMarks.mark(for: "muse"))
        XCTAssertGreaterThan(muse.bounds.width, 20, "Muse mark must render the full Meta loop")
        XCTAssertGreaterThan(muse.bounds.height, 14, "Muse mark must render the full Meta loop")

        let opencode = try XCTUnwrap(ProviderMarks.mark(for: "opencode"))
        XCTAssertEqual(opencode.bounds.width, 24, accuracy: 0.1)
        XCTAssertEqual(opencode.bounds.height, 30, accuracy: 0.1)

        let synthetic = try XCTUnwrap(ProviderMarks.mark(for: "synthetic"))
        XCTAssertGreaterThan(synthetic.bounds.width, 40)
        XCTAssertGreaterThan(synthetic.bounds.height, 40)
    }

    func testProviderIconOpticalDensity() throws {
        let activeProviders = [
            "claude", "codex", "grok", "antigravity",
            "muse", "ollama", "opencode", "synthetic"
        ]

        for id in activeProviders {
            let mark = try XCTUnwrap(ProviderMarks.mark(for: id))
            // Render at 16x16 pt, scale 2 (32x32 px) with inset 0.14 and inset 0.04
            for inset in [0.14, 0.04] {
                let view = ProviderIconShape(mark: mark, inset: inset)
                    .fill(Color.black)
                    .frame(width: 16, height: 16)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.nsImage, "\(id) should render to NSImage")
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    XCTFail("\(id) failed to obtain CGImage")
                    continue
                }
                XCTAssertEqual(cgImage.width, 32)
                XCTAssertEqual(cgImage.height, 32)

                // Count non-zero alpha pixels
                guard let dataProvider = cgImage.dataProvider,
                      let pixelData = dataProvider.data,
                      let ptr = CFDataGetBytePtr(pixelData) else {
                    XCTFail("\(id) cannot read pixel data")
                    continue
                }
                let bytesPerRow = cgImage.bytesPerRow
                let bytesPerPixel = cgImage.bitsPerPixel / 8
                var filledCount = 0
                for y in 0..<cgImage.height {
                    for x in 0..<cgImage.width {
                        let offset = y * bytesPerRow + x * bytesPerPixel
                        let alpha = ptr[offset + 3]
                        if alpha > 20 {
                            filledCount += 1
                        }
                    }
                }
                // Verify the mark rendered cleanly without completely filling or leaving empty
                XCTAssertGreaterThan(filledCount, 150, "\(id) inset \(inset) rendered too faint")
                XCTAssertLessThan(filledCount, 850, "\(id) inset \(inset) rendered solid/clipped")
            }
        }
    }

}

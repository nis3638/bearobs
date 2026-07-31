import Foundation
import XCTest

@testable import MarkdownSpike

final class MarkdownPerformanceTests: XCTestCase {
    func testLargeAndManyFileBaseline() throws {
        let clock = ContinuousClock()

        let largeStart = clock.now
        let largeResult = try MarkdownSpike.analyze(
            GoldenVault.data("Performance/large-note.md")
        )
        let largeDuration = largeStart.duration(to: clock.now)

        let smallURLs = try GoldenVault.smallNoteURLs()
        let smallStart = clock.now
        for url in smallURLs {
            _ = try MarkdownSpike.analyze(Data(contentsOf: url))
        }
        let smallDuration = smallStart.duration(to: clock.now)

        XCTAssertEqual(largeResult.originalData.count, 1_048_576)
        XCTAssertEqual(smallURLs.count, 256)
        print(
            "M0-08 macOS baseline: 1MiB=\(largeDuration), "
                + "256-small=\(smallDuration)"
        )
    }
}

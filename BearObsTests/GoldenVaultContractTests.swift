import Foundation
import XCTest

final class GoldenVaultContractTests: XCTestCase {
    func testContractDeclaresSyntheticM005Coverage() throws {
        let contract = try loadContract()

        XCTAssertEqual(contract.schemaVersion, 1)
        XCTAssertEqual(contract.fixture.id, "bearobs-golden-vault")
        XCTAssertEqual(contract.fixture.milestone, "M0-05")
        XCTAssertTrue(contract.fixture.synthetic)
        XCTAssertFalse(contract.fixture.containsRealUserContent)
        XCTAssertEqual(contract.fixture.vaultRoot, "vault")
        XCTAssertEqual(
            Set(contract.parserCases.flatMap(\.features)),
            Set([
                "attachments",
                "byte-encoding",
                "code-exclusions",
                "inline-tags",
                "invalid-frontmatter",
                "path-encoding",
                "unsupported-syntax",
                "wiki-links",
                "yaml-frontmatter",
            ])
        )
    }

    func testParserCasesHaveUniqueStableIdentifiers() throws {
        let parserCases = try loadContract().parserCases
        let identifiers = parserCases.map(\.id)

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertTrue(
            identifiers.allSatisfy {
                $0.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil
            })
    }

    func testEveryContractPathIsRelativeAndMaterialized() throws {
        let contract = try loadContract()
        let vault = try vaultURL(contract: contract)
        let casePaths = contract.parserCases.map(\.path)
        let resolvedLinkPaths = contract.parserCases.flatMap {
            $0.expected.links?.compactMap(\.resolvedPath) ?? []
        }
        let candidateLinkPaths = contract.parserCases.flatMap {
            $0.expected.links?.flatMap(\.candidates) ?? []
        }
        let resolvedAttachmentPaths = contract.parserCases.flatMap {
            $0.expected.attachments?.compactMap(\.resolvedPath) ?? []
        }
        let performancePaths = [
            contract.performance.largeNote.path,
            contract.performance.smallNotes.directory,
        ]
        let paths =
            casePaths + resolvedLinkPaths + candidateLinkPaths + resolvedAttachmentPaths
            + performancePaths

        for path in Set(paths) {
            try assertMaterializedRelativePath(path, below: vault)
        }
    }

    func testEncodingCasesPreserveExactByteProfiles() throws {
        let contract = try loadContract()
        let vault = try vaultURL(contract: contract)
        let encodingCases = contract.parserCases.filter { $0.expected.encoding != nil }

        XCTAssertEqual(
            Set(encodingCases.map(\.expected.encoding?.lineEnding)), Set(["lf", "crlf"]))
        XCTAssertEqual(Set(encodingCases.map(\.expected.encoding?.utf8BOM)), Set([true, false]))

        for parserCase in encodingCases {
            let expectation = try XCTUnwrap(parserCase.expected.encoding)
            let data = try Data(contentsOf: vault.appendingPathComponent(parserCase.path))
            assert(data: data, matches: expectation, file: parserCase.path)
        }
    }

    func testLinkAndAttachmentContractCoversAllResolutionStates() throws {
        let parserCases = try loadContract().parserCases
        let links = parserCases.flatMap { $0.expected.links ?? [] }
        let attachments = parserCases.flatMap { $0.expected.attachments ?? [] }

        XCTAssertEqual(Set(links.map(\.state)), Set(["ambiguous", "resolved"]))
        XCTAssertTrue(links.contains { $0.alias != nil })
        XCTAssertTrue(links.contains { $0.target.contains("%") && $0.target.contains("空 格") })
        XCTAssertEqual(Set(attachments.map(\.syntax)), Set(["markdown-image", "obsidian-embed"]))
        XCTAssertEqual(Set(attachments.map(\.state)), Set(["missing", "resolved"]))
    }

    func testExpectedLexemesExistAndMissingAttachmentsStayMissing() throws {
        let contract = try loadContract()
        let vault = try vaultURL(contract: contract)

        for parserCase in contract.parserCases {
            let note = vault.appendingPathComponent(parserCase.path)
            let source = String(decoding: try Data(contentsOf: note), as: UTF8.self)
            let expected = parserCase.expected
            let lexemes =
                (expected.frontmatter?.tags ?? [])
                + (expected.inlineTags?.map { "#\($0)" } ?? [])
                + (expected.excludedSourceTokens ?? [])
                + (expected.links?.map(\.source) ?? [])
                + (expected.attachments?.map(\.source) ?? [])
                + (expected.fallback?.preservedSource ?? [])

            for lexeme in lexemes {
                XCTAssertTrue(source.contains(lexeme), "\(parserCase.path): \(lexeme)")
            }

            for attachment in expected.attachments ?? [] where attachment.state == "missing" {
                assertMissing(attachment.target, from: note, vault: vault)
            }
        }
    }

    func testPerformanceCorpusIsMaterialized() throws {
        let contract = try loadContract()
        let vault = try vaultURL(contract: contract)
        let largeNote = vault.appendingPathComponent(contract.performance.largeNote.path)
        let smallNotes = vault.appendingPathComponent(contract.performance.smallNotes.directory)
        let fileManager = FileManager.default

        XCTAssertEqual(
            try Data(contentsOf: largeNote).count, contract.performance.largeNote.byteCount)

        let markdownFiles = try fileManager.contentsOfDirectory(
            at: smallNotes,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" }
        XCTAssertEqual(markdownFiles.count, contract.performance.smallNotes.count)
        XCTAssertTrue(markdownFiles.allSatisfy { fileManager.fileExists(atPath: $0.path) })
    }
}

extension GoldenVaultContractTests {
    fileprivate func loadContract() throws -> GoldenVaultContract {
        let root = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "GoldenVault", withExtension: nil)
        )
        let data = try Data(contentsOf: root.appendingPathComponent("contract.json"))
        return try JSONDecoder().decode(GoldenVaultContract.self, from: data)
    }

    fileprivate func vaultURL(contract: GoldenVaultContract) throws -> URL {
        let root = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "GoldenVault", withExtension: nil)
        )
        return root.appendingPathComponent(contract.fixture.vaultRoot, isDirectory: true)
    }

    fileprivate func assertMaterializedRelativePath(_ path: String, below root: URL) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        XCTAssertFalse(path.hasPrefix("/"), path)
        XCTAssertFalse(components.contains(""), path)
        XCTAssertFalse(components.contains("."), path)
        XCTAssertFalse(components.contains(".."), path)

        let resolved = root.appendingPathComponent(path).standardizedFileURL
        XCTAssertTrue(resolved.path.hasPrefix(root.standardizedFileURL.path + "/"), path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path), path)
    }

    fileprivate func assert(
        data: Data,
        matches expectation: GoldenVaultContract.EncodingExpectation,
        file: String
    ) {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let hasBOM = data.starts(with: bom)
        let content = hasBOM ? data.dropFirst(bom.count) : data[...]

        XCTAssertEqual(hasBOM, expectation.utf8BOM, file)
        switch expectation.lineEnding {
        case "lf":
            XCTAssertTrue(content.contains(0x0A), file)
            XCTAssertFalse(content.contains(0x0D), file)
        case "crlf":
            assertOnlyCRLF(in: content, file: file)
        default:
            XCTFail("Unsupported line-ending contract: \(expectation.lineEnding)")
        }
    }

    fileprivate func assertOnlyCRLF(in data: Data.SubSequence, file: String) {
        let bytes = Array(data)
        XCTAssertTrue(bytes.contains(0x0A), file)
        for index in bytes.indices where bytes[index] == 0x0A {
            XCTAssertGreaterThan(index, bytes.startIndex, file)
            XCTAssertEqual(bytes[index - 1], 0x0D, file)
        }
        for index in bytes.indices where bytes[index] == 0x0D {
            XCTAssertLessThan(index + 1, bytes.endIndex, file)
            XCTAssertEqual(bytes[index + 1], 0x0A, file)
        }
    }

    fileprivate func assertMissing(_ target: String, from note: URL, vault: URL) {
        let fileManager = FileManager.default
        let relativeTarget = note.deletingLastPathComponent().appendingPathComponent(target)
        let rootTarget = vault.appendingPathComponent(target)

        XCTAssertFalse(fileManager.fileExists(atPath: relativeTarget.path), target)
        XCTAssertFalse(fileManager.fileExists(atPath: rootTarget.path), target)
    }
}

struct GoldenVaultContract: Decodable {
    let schemaVersion: Int
    let fixture: Fixture
    let parserCases: [ParserCase]
    let performance: Performance

    struct Fixture: Decodable {
        let id: String
        let milestone: String
        let synthetic: Bool
        let containsRealUserContent: Bool
        let vaultRoot: String
    }

    struct ParserCase: Decodable {
        let id: String
        let features: [String]
        let path: String
        let expected: Expectation
    }

    struct Expectation: Decodable {
        let frontmatter: FrontmatterExpectation?
        let inlineTags: [String]?
        let excludedSourceTokens: [String]?
        let links: [LinkExpectation]?
        let attachments: [AttachmentExpectation]?
        let encoding: EncodingExpectation?
        let fallback: FallbackExpectation?
    }

    struct FrontmatterExpectation: Decodable {
        let state: String
        let tags: [String]?
        let diagnostic: String?
    }

    struct LinkExpectation: Decodable {
        let source: String
        let target: String
        let alias: String?
        let state: String
        let resolvedPath: String?
        let candidates: [String]
    }

    struct AttachmentExpectation: Decodable {
        let syntax: String
        let source: String
        let target: String
        let state: String
        let resolvedPath: String?
    }

    struct EncodingExpectation: Decodable, Hashable {
        let utf8BOM: Bool
        let lineEnding: String
    }

    struct FallbackExpectation: Decodable {
        let preservedSource: [String]
        let diagnostics: [String]
    }

    struct Performance: Decodable {
        let largeNote: LargeNote
        let smallNotes: SmallNotes

        struct LargeNote: Decodable {
            let path: String
            let byteCount: Int
        }

        struct SmallNotes: Decodable {
            let directory: String
            let count: Int
        }
    }
}

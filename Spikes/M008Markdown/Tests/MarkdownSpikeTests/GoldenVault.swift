import Foundation

enum GoldenVault {
    struct Contract: Decodable {
        let schemaVersion: Int
        let parserCases: [ParserCase]
    }

    struct ParserCase: Decodable {
        let id: String
        let features: [String]
        let path: String
        let expected: Expected
    }

    struct Expected: Decodable {
        let frontmatter: Frontmatter?
        let inlineTags: [String]?
        let excludedSourceTokens: [String]?
        let links: [Link]?
        let attachments: [Attachment]?
        let encoding: Encoding?
        let fallback: Fallback?
    }

    struct Frontmatter: Decodable {
        let state: String
        let tags: [String]?
        let diagnostic: String?
    }

    struct Link: Decodable {
        let source: String
        let target: String
        let alias: String?
    }

    struct Attachment: Decodable {
        let syntax: String
        let source: String
        let target: String
    }

    struct Encoding: Decodable {
        let utf8BOM: Bool
        let lineEnding: String
    }

    struct Fallback: Decodable {
        let preservedSource: [String]
        let diagnostics: [String]
    }

    enum Error: Swift.Error {
        case missingParserCase(String)
    }

    static let repositoryURL: URL = {
        var repositoryURL = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            repositoryURL.deleteLastPathComponent()
        }
        return repositoryURL
    }()

    static let fixtureURL = repositoryURL.appendingPathComponent(
        "BearObsTests/Fixtures/GoldenVault"
    )
    static let vaultURL = fixtureURL.appendingPathComponent("vault")

    static func contract() throws -> Contract {
        let data = try Data(
            contentsOf: fixtureURL.appendingPathComponent("contract.json")
        )
        return try JSONDecoder().decode(Contract.self, from: data)
    }

    static func parserCase(id: String) throws -> ParserCase {
        guard let parserCase = try contract().parserCases.first(where: { $0.id == id })
        else {
            throw Error.missingParserCase(id)
        }
        return parserCase
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: vaultURL.appendingPathComponent(relativePath))
    }

    static func data(caseID: String) throws -> Data {
        try data(parserCase(id: caseID).path)
    }

    static func smallNoteURLs() throws -> [URL] {
        let directoryURL = vaultURL.appendingPathComponent("Performance/Small")
        return try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

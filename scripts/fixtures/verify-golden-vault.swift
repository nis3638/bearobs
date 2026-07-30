import Foundation

private struct Contract: Decodable {
    let schemaVersion: Int
    let fixture: Fixture
    let parserCases: [ParserCase]
    let performance: Performance

    struct Fixture: Decodable {
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
        let frontmatter: Frontmatter?
        let inlineTags: [String]?
        let excludedSourceTokens: [String]?
        let links: [Link]?
        let attachments: [Attachment]?
        let encoding: Encoding?
        let fallback: Fallback?
    }

    struct Frontmatter: Decodable {
        let tags: [String]?
    }

    struct Link: Decodable {
        let source: String
        let resolvedPath: String?
        let candidates: [String]
    }

    struct Attachment: Decodable {
        let syntax: String
        let source: String
        let target: String
        let state: String
        let resolvedPath: String?
    }

    struct Encoding: Decodable {
        let utf8BOM: Bool
        let lineEnding: String
    }

    struct Fallback: Decodable {
        let preservedSource: [String]
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

private enum VerificationError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            message
        }
    }
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw VerificationError.failed(message)
    }
}

private func assertRelativeFile(_ path: String, below root: URL) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    try require(!path.hasPrefix("/"), "Absolute contract path: \(path)")
    try require(!components.contains(""), "Empty contract path component: \(path)")
    try require(!components.contains("."), "Dot contract path component: \(path)")
    try require(!components.contains(".."), "Traversal contract path: \(path)")

    let resolved = root.appendingPathComponent(path).standardizedFileURL
    try require(
        resolved.path.hasPrefix(root.standardizedFileURL.path + "/"),
        "Contract path escapes vault: \(path)"
    )
    try require(FileManager.default.fileExists(atPath: resolved.path), "Missing fixture: \(path)")
}

private func assertEncoding(_ encoding: Contract.Encoding, data: Data, path: String) throws {
    let bom = Data([0xEF, 0xBB, 0xBF])
    let hasBOM = data.starts(with: bom)
    let bytes = Array(hasBOM ? data.dropFirst(bom.count) : data[...])
    try require(hasBOM == encoding.utf8BOM, "Wrong BOM profile: \(path)")

    switch encoding.lineEnding {
    case "lf":
        try require(bytes.contains(0x0A), "LF fixture has no newline: \(path)")
        try require(!bytes.contains(0x0D), "LF fixture contains CR: \(path)")
    case "crlf":
        try require(bytes.contains(0x0A), "CRLF fixture has no newline: \(path)")
        for index in bytes.indices where bytes[index] == 0x0A {
            try require(index > bytes.startIndex, "Bare LF at start: \(path)")
            try require(bytes[index - 1] == 0x0D, "Bare LF: \(path)")
        }
        for index in bytes.indices where bytes[index] == 0x0D {
            try require(index + 1 < bytes.endIndex, "Trailing CR: \(path)")
            try require(bytes[index + 1] == 0x0A, "Bare CR: \(path)")
        }
    default:
        throw VerificationError.failed("Unknown line ending: \(encoding.lineEnding)")
    }
}

private let script = URL(fileURLWithPath: #filePath)
private let repository = script.deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let fixtureRoot =
    repository
    .appendingPathComponent("BearObsTests/Fixtures/GoldenVault", isDirectory: true)
private let contractData = try Data(contentsOf: fixtureRoot.appendingPathComponent("contract.json"))
private let contract = try JSONDecoder().decode(Contract.self, from: contractData)
private let vault = fixtureRoot.appendingPathComponent(
    contract.fixture.vaultRoot, isDirectory: true)
private let requiredFeatures = Set([
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
private let caseIDs = contract.parserCases.map(\.id)

try require(contract.schemaVersion == 1, "Unsupported Golden Vault contract schema")
try require(contract.fixture.milestone == "M0-05", "Golden Vault is not assigned to M0-05")
try require(contract.fixture.synthetic, "Golden Vault must be synthetic")
try require(!contract.fixture.containsRealUserContent, "Golden Vault declares real user content")
try require(contract.fixture.vaultRoot == "vault", "Golden Vault root must remain 'vault'")
try require(Set(caseIDs).count == caseIDs.count, "Duplicate parser case identifier")
try require(
    Set(contract.parserCases.flatMap(\.features)) == requiredFeatures,
    "Golden Vault feature coverage drifted"
)

for parserCase in contract.parserCases {
    try assertRelativeFile(parserCase.path, below: vault)
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
        try require(
            source.contains(lexeme),
            "Missing expected lexeme in \(parserCase.path): \(lexeme)"
        )
    }
    for path in parserCase.expected.links?.compactMap(\.resolvedPath) ?? [] {
        try assertRelativeFile(path, below: vault)
    }
    for path in parserCase.expected.links?.flatMap(\.candidates) ?? [] {
        try assertRelativeFile(path, below: vault)
    }
    for path in parserCase.expected.attachments?.compactMap(\.resolvedPath) ?? [] {
        try assertRelativeFile(path, below: vault)
    }
    for attachment in parserCase.expected.attachments ?? [] where attachment.state == "missing" {
        let relativeTarget = note.deletingLastPathComponent()
            .appendingPathComponent(attachment.target)
        let rootTarget = vault.appendingPathComponent(attachment.target)
        try require(
            !FileManager.default.fileExists(atPath: relativeTarget.path),
            "Missing attachment exists relative to note: \(attachment.target)"
        )
        try require(
            !FileManager.default.fileExists(atPath: rootTarget.path),
            "Missing attachment exists at Vault root: \(attachment.target)"
        )
    }
    if let encoding = parserCase.expected.encoding {
        let data = try Data(contentsOf: vault.appendingPathComponent(parserCase.path))
        try assertEncoding(encoding, data: data, path: parserCase.path)
    }
}

private let largeNote = vault.appendingPathComponent(contract.performance.largeNote.path)
try assertRelativeFile(contract.performance.largeNote.path, below: vault)
try assertRelativeFile(contract.performance.smallNotes.directory, below: vault)
private let largeNoteByteCount = try Data(contentsOf: largeNote).count
try require(
    largeNoteByteCount == contract.performance.largeNote.byteCount,
    "Large-note byte count drifted"
)

private let smallNotes = vault.appendingPathComponent(contract.performance.smallNotes.directory)
private let smallNoteCount = try FileManager.default.contentsOfDirectory(
    at: smallNotes,
    includingPropertiesForKeys: nil
).filter { $0.pathExtension == "md" }.count
try require(
    smallNoteCount == contract.performance.smallNotes.count,
    "Small-note corpus count drifted"
)

print(
    "Verified Golden Vault contract v\(contract.schemaVersion): "
        + "\(contract.parserCases.count) parser cases, "
        + "\(contract.performance.smallNotes.count) small notes."
)

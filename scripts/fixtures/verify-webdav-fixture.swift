import Foundation

private struct Contract: Decodable {
    let schemaVersion: Int
    let fixture: Fixture
    let propfind: Propfind
    let resources: [Resource]
    let requiredScenarios: [String]

    struct Fixture: Decodable {
        let id: String
        let milestone: String
        let synthetic: Bool
        let containsRealUserContent: Bool
    }

    struct Propfind: Decodable {
        let percentEncodedPath: String
        let depth: String
        let body: String
    }

    struct Resource: Decodable {
        let id: String
        let percentEncodedPath: String
        let kind: String
        let body: String?
        let etag: String?
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

private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw VerificationError.failed(message)
    }
    return value
}

private func requireRelativeFile(_ path: String, below root: URL) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    try require(!path.hasPrefix("/"), "Absolute fixture file path: \(path)")
    try require(!components.contains(""), "Empty fixture file path component: \(path)")
    try require(!components.contains("."), "Dot fixture file path component: \(path)")
    try require(!components.contains(".."), "Traversal fixture file path: \(path)")

    let root = root.resolvingSymlinksInPath().standardizedFileURL
    let resolved = root.appendingPathComponent(path)
        .resolvingSymlinksInPath()
        .standardizedFileURL
    try require(
        resolved.path.hasPrefix(root.standardizedFileURL.path + "/"),
        "Fixture file escapes root: \(path)"
    )
    try require(
        FileManager.default.fileExists(atPath: resolved.path), "Missing fixture file: \(path)")
}

private let script = URL(fileURLWithPath: #filePath)
private let repository = script.deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let root = repository.appendingPathComponent(
    "BearObsTests/Fixtures/WebDAV",
    isDirectory: true
)
private let data = try Data(contentsOf: root.appendingPathComponent("contract.json"))
private let contract = try JSONDecoder().decode(Contract.self, from: data)
private let expectedScenarios = Set([
    "conditional-put",
    "get",
    "http-401",
    "http-503",
    "interrupted-download",
    "percent-encoded-path",
    "precondition-failed",
    "propfind-depth-1",
    "timeout",
])
private let resourceIDs = contract.resources.map(\.id)
private let resourcePaths = contract.resources.map(\.percentEncodedPath)

try require(contract.schemaVersion == 1, "Unsupported WebDAV contract schema")
try require(contract.fixture.id == "bearobs-controlled-webdav", "Unexpected fixture identifier")
try require(contract.fixture.milestone == "M0-06", "Fixture is not assigned to M0-06")
try require(contract.fixture.synthetic, "WebDAV fixture must be synthetic")
try require(!contract.fixture.containsRealUserContent, "Fixture declares real user content")
try require(contract.propfind.percentEncodedPath == "/vault/", "Unexpected PROPFIND root")
try require(contract.propfind.depth == "1", "PROPFIND depth must remain 1")
try require(
    Set(contract.requiredScenarios) == expectedScenarios, "Required scenario coverage drifted")
try require(Set(resourceIDs).count == resourceIDs.count, "Duplicate resource identifier")
try require(Set(resourcePaths).count == resourcePaths.count, "Duplicate resource path")

try requireRelativeFile(contract.propfind.body, below: root)
for body in contract.resources.compactMap(\.body) {
    try requireRelativeFile(body, below: root)
}

for resource in contract.resources {
    try require(resource.percentEncodedPath.hasPrefix("/vault/"), "Resource outside Vault root")
    try require(
        resource.kind == "collection" || resource.kind == "file",
        "Unsupported resource kind: \(resource.kind)"
    )
    if resource.kind == "collection" {
        try require(resource.body == nil, "Collection must not declare a body")
    } else {
        try require(resource.body != nil, "File must declare a body")
    }
}

let xml = String(
    decoding: try Data(contentsOf: root.appendingPathComponent(contract.propfind.body)),
    as: UTF8.self
)
private let note = try unwrap(
    contract.resources.first { $0.id == "note" },
    "Missing canonical note resource"
)
private let noteBody = try unwrap(note.body, "Canonical note has no body")
private let noteData = try Data(contentsOf: root.appendingPathComponent(noteBody))
try require(xml.contains("<d:multistatus"), "Golden response is not a DAV multistatus")
try require(xml.contains("HTTP/1.1 404 Not Found"), "Golden response lacks mixed propstat")
try require(xml.contains("W/\"weak-etag-v1\""), "Golden response lacks weak ETag")
try require(
    xml.contains("<d:getcontentlength>\(noteData.count)</d:getcontentlength>"),
    "Golden response content length drifted"
)
try require(!xml.contains("%E7%A9%BA%20%E6%A0%BC%25.md"), "Depth:1 response leaked a grandchild")

print(
    "Verified WebDAV contract v1: \(contract.resources.count) resources, "
        + "\(contract.requiredScenarios.count) scenarios."
)

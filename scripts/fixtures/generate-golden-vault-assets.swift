import Foundation

private let script = URL(fileURLWithPath: #filePath)
private let repository = script.deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
private let vault = repository.appendingPathComponent(
    "BearObsTests/Fixtures/GoldenVault/vault",
    isDirectory: true
)
private let fileManager = FileManager.default

private func write(_ data: Data, to relativePath: String) throws {
    let destination = vault.appendingPathComponent(relativePath)
    try fileManager.createDirectory(
        at: destination.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try data.write(to: destination, options: .atomic)
}

private func utf8(_ string: String) -> Data {
    Data(string.utf8)
}

private func makeLargeNote(byteCount: Int) -> Data {
    var result = utf8(
        """
        # Synthetic 1 MiB note

        This file is generated and contains no user content.

        """
    )
    let line = utf8("Synthetic performance line for deterministic parser measurement.\n")
    while result.count + line.count <= byteCount {
        result.append(line)
    }

    let remainder = byteCount - result.count
    if remainder == 1 {
        result.append(0x0A)
    } else if remainder > 1 {
        result.append(Data(repeating: 0x20, count: remainder - 1))
        result.append(0x0A)
    }
    return result
}

private let bomNote = """
    # UTF-8 BOM fixture

    This synthetic note starts with exactly one UTF-8 BOM and uses LF.
    """
private let crlfNote = [
    "# CRLF fixture",
    "",
    "Every newline in this synthetic note is CRLF.",
    "",
].joined(separator: "\r\n")

try write(Data([0xEF, 0xBB, 0xBF]) + utf8(bomNote), to: "Encoding/utf8-bom.md")
try write(utf8(crlfNote), to: "Encoding/crlf.md")
try write(makeLargeNote(byteCount: 1_048_576), to: "Performance/large-note.md")

for index in 1...256 {
    let identifier = String(format: "%04d", index)
    let note = """
        ---
        title: Synthetic Small Note \(identifier)
        tags: fixture/performance
        fixture: true
        ---

        # Synthetic small note \(identifier)

        Deterministic generated content \(identifier).
        """
    try write(utf8(note), to: "Performance/Small/note-\(identifier).md")
}

print("Generated Golden Vault byte and performance assets.")

import AtomicWriteSpike
import Darwin
import Foundation

private enum ProbeFailure: Error, CustomStringConvertible {
    case invalidArguments
    case childDidNotDie(AtomicWriteStage, Process.TerminationReason, Int32)
    case wrongDestination(AtomicWriteStage)
    case wrongStagingCount(AtomicWriteStage, Int)

    var description: String {
        switch self {
        case .invalidArguments:
            "invalid crash probe arguments"
        case .childDidNotDie(let stage, let reason, let status):
            "child did not die at \(stage.rawValue): \(reason) \(status)"
        case .wrongDestination(let stage):
            "destination violated atomicity at \(stage.rawValue)"
        case .wrongStagingCount(let stage, let count):
            "unexpected staging count \(count) at \(stage.rawValue)"
        }
    }
}

private let stagingPrefix = ".bearobs-staging-"

private func runChild(arguments: [String]) throws -> Never {
    guard arguments.count == 5,
        let stage = AtomicWriteStage(rawValue: arguments[2]),
        let bytes = Data(base64Encoded: arguments[4])
    else {
        throw ProbeFailure.invalidArguments
    }
    let destination = URL(fileURLWithPath: arguments[3])
    let writer = AtomicFileWriter { currentStage in
        if currentStage == stage {
            _ = kill(getpid(), SIGKILL)
            _exit(128 + SIGKILL)
        }
    }
    _ = try writer.replaceExistingFile(at: destination, with: bytes)
    _exit(65)
}

private func stagingFiles(in directory: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    ).filter { $0.lastPathComponent.hasPrefix(stagingPrefix) }
}

private func runParent() throws {
    let old = Data("old-complete-version\n".utf8)
    let new = Data(repeating: 0x4E, count: 64 * 1_024)
    let executable = URL(fileURLWithPath: CommandLine.arguments[0])
    let prePublish: Set<AtomicWriteStage> = [
        .stagingCreated,
        .partialDataWritten,
        .dataWritten,
        .fileSynchronized,
        .stagingClosed,
    ]

    for stage in AtomicWriteStage.allCases {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bearobs-m009-crash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("note.md")
        try old.write(to: destination)

        let child = Process()
        child.executableURL = executable
        child.arguments = [
            "--child",
            stage.rawValue,
            destination.path,
            new.base64EncodedString(),
        ]
        try child.run()
        child.waitUntilExit()

        guard child.terminationReason == .uncaughtSignal,
            child.terminationStatus == SIGKILL
        else {
            throw ProbeFailure.childDidNotDie(
                stage,
                child.terminationReason,
                child.terminationStatus
            )
        }
        let expected = prePublish.contains(stage) ? old : new
        guard try Data(contentsOf: destination) == expected else {
            throw ProbeFailure.wrongDestination(stage)
        }
        let count = try stagingFiles(in: directory).count
        let expectedCount = prePublish.contains(stage) ? 1 : 0
        guard count == expectedCount else {
            throw ProbeFailure.wrongStagingCount(stage, count)
        }
    }
    print(
        "Verified SIGKILL boundaries: \(AtomicWriteStage.allCases.count) stages, "
            + "destination always old or complete new."
    )
}

do {
    if CommandLine.arguments.dropFirst().first == "--child" {
        try runChild(arguments: CommandLine.arguments)
    } else {
        try runParent()
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

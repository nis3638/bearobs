import Foundation
import XCTest

@testable import JianguoyunWebDAVVerifierCore

@MainActor
final class ManualVerifierApplicationTests: XCTestCase {
    func testInvalidArgumentsPrintUsageWithoutTouchingOperationalDependencies() async {
        let invalidArguments = [
            [],
            ["unknown-command"],
            ["store-credentials", "leaked-user", "leaked-password"],
        ]

        for arguments in invalidArguments {
            let terminal = FakeTerminal()
            let store = FakeCredentialStore()
            let verifier = VerificationSpy()
            let output = OutputSpy()
            let application = makeApplication(
                terminal: terminal,
                store: store,
                verifier: verifier,
                output: output
            )

            let exitCode = await application.run(arguments: arguments)

            XCTAssertEqual(exitCode, ManualVerifierExitCode.usage)
            XCTAssertEqual(output.values, [ManualVerifierApplication.usage])
            XCTAssertTrue(terminal.linePrompts.isEmpty)
            XCTAssertTrue(terminal.secretPrompts.isEmpty)
            XCTAssertTrue(store.saveCalls.isEmpty)
            XCTAssertEqual(store.loadCallCount, 0)
            XCTAssertEqual(store.deleteCallCount, 0)
            XCTAssertTrue(verifier.calls.isEmpty)
            assertRedacted(output.values)
        }
    }

    func testStoreCredentialsReadsUsernameAndPasswordOnlyFromTerminal() async {
        let credentials = Credentials(
            username: "terminal-user",
            applicationPassword: "terminal-password"
        )
        let terminal = FakeTerminal(
            lineResults: [.success(credentials.username)],
            secretResults: [.success(credentials.applicationPassword)]
        )
        let store = FakeCredentialStore()
        let output = OutputSpy()
        let application = makeApplication(terminal: terminal, store: store, output: output)

        let exitCode = await application.run(arguments: ["store-credentials"])

        XCTAssertEqual(exitCode, ManualVerifierExitCode.success)
        XCTAssertEqual(
            store.saveCalls,
            [SaveCall(credentials: credentials, overwrite: false)]
        )
        XCTAssertEqual(terminal.linePrompts.count, 1)
        XCTAssertEqual(terminal.secretPrompts.count, 1)
        XCTAssertEqual(output.values, ["Credentials stored."])
        assertRedacted(output.values)
    }

    func testExistingCredentialsAreNotOverwrittenWithoutExactConfirmation() async {
        for confirmation in ["overwrite", " OVERWRITE", "OVERWRITE ", "NO"] {
            let credentials = Credentials(
                username: "terminal-user",
                applicationPassword: "terminal-password"
            )
            let terminal = FakeTerminal(
                lineResults: [.success(credentials.username), .success(confirmation)],
                secretResults: [.success(credentials.applicationPassword)]
            )
            let store = FakeCredentialStore(
                saveResults: [.failure(KeychainCredentialStoreError.itemAlreadyExists)]
            )
            let output = OutputSpy()
            let application = makeApplication(terminal: terminal, store: store, output: output)

            let exitCode = await application.run(arguments: ["store-credentials"])

            XCTAssertEqual(exitCode, ManualVerifierExitCode.failure)
            XCTAssertEqual(
                store.saveCalls,
                [SaveCall(credentials: credentials, overwrite: false)]
            )
            XCTAssertEqual(output.values, ["Credentials were not changed."])
            assertRedacted(output.values)
        }
    }

    func testExistingCredentialsAreOverwrittenAfterExactConfirmation() async {
        let credentials = Credentials(
            username: "terminal-user",
            applicationPassword: "terminal-password"
        )
        let terminal = FakeTerminal(
            lineResults: [.success(credentials.username), .success("OVERWRITE")],
            secretResults: [.success(credentials.applicationPassword)]
        )
        let store = FakeCredentialStore(
            saveResults: [
                .failure(KeychainCredentialStoreError.itemAlreadyExists),
                .success(()),
            ]
        )
        let output = OutputSpy()
        let application = makeApplication(terminal: terminal, store: store, output: output)

        let exitCode = await application.run(arguments: ["store-credentials"])

        XCTAssertEqual(exitCode, ManualVerifierExitCode.success)
        XCTAssertEqual(
            store.saveCalls,
            [
                SaveCall(credentials: credentials, overwrite: false),
                SaveCall(credentials: credentials, overwrite: true),
            ]
        )
        XCTAssertEqual(output.values, ["Credentials stored."])
        assertRedacted(output.values)
    }

    func testDeleteRequiresExactTerminalConfirmation() async {
        for confirmation in ["delete", " DELETE", "DELETE ", "NO"] {
            let terminal = FakeTerminal(lineResults: [.success(confirmation)])
            let store = FakeCredentialStore()
            let output = OutputSpy()
            let application = makeApplication(terminal: terminal, store: store, output: output)

            let exitCode = await application.run(arguments: ["delete-credentials"])

            XCTAssertEqual(exitCode, ManualVerifierExitCode.failure)
            XCTAssertEqual(store.deleteCallCount, 0)
            XCTAssertEqual(output.values, ["Credentials were not deleted."])
            assertRedacted(output.values)
        }

        let terminal = FakeTerminal(lineResults: [.success("DELETE")])
        let store = FakeCredentialStore()
        let output = OutputSpy()
        let application = makeApplication(terminal: terminal, store: store, output: output)

        let exitCode = await application.run(arguments: ["delete-credentials"])

        XCTAssertEqual(exitCode, ManualVerifierExitCode.success)
        XCTAssertEqual(store.deleteCallCount, 1)
        XCTAssertEqual(output.values, ["Credentials deleted."])
        assertRedacted(output.values)
    }

    func testVerifyDoesNotRunWithoutStoredCredentials() async {
        let terminal = FakeTerminal()
        let store = FakeCredentialStore(loadResult: .success(nil))
        let verifier = VerificationSpy()
        let output = OutputSpy()
        let application = makeApplication(
            terminal: terminal,
            store: store,
            verifier: verifier,
            output: output
        )

        let exitCode = await application.run(arguments: ["verify"])

        XCTAssertEqual(exitCode, ManualVerifierExitCode.failure)
        XCTAssertEqual(store.loadCallCount, 1)
        XCTAssertTrue(terminal.linePrompts.isEmpty)
        XCTAssertTrue(verifier.calls.isEmpty)
        XCTAssertEqual(output.values, ["Verification failed: credentials unavailable."])
        assertRedacted(output.values)
    }

    func testVerifyRejectsInvalidTerminalPathBeforeRunningVerifier() async {
        let credentials = Credentials(
            username: "stored-user",
            applicationPassword: "stored-password"
        )
        let terminal = FakeTerminal(lineResults: [.success("../private-directory")])
        let store = FakeCredentialStore(loadResult: .success(credentials))
        let verifier = VerificationSpy()
        let output = OutputSpy()
        let application = makeApplication(
            terminal: terminal,
            store: store,
            verifier: verifier,
            output: output
        )

        let exitCode = await application.run(arguments: ["verify"])

        XCTAssertEqual(exitCode, ManualVerifierExitCode.failure)
        XCTAssertTrue(verifier.calls.isEmpty)
        XCTAssertEqual(output.values, ["Verification failed: invalid dedicated directory."])
        assertRedacted(output.values)
    }

    func testVerifyUsesInjectedCredentialsAndTerminalPathAndRendersOnlySanitizedReport() async {
        let credentials = Credentials(
            username: "stored-user",
            applicationPassword: "stored-password"
        )
        let terminalPath = "manual-verifier-only"
        let report = makeReport()
        let terminal = FakeTerminal(lineResults: [.success(terminalPath)])
        let store = FakeCredentialStore(loadResult: .success(credentials))
        let verifier = VerificationSpy(result: .success(report))
        let output = OutputSpy()
        let application = makeApplication(
            terminal: terminal,
            store: store,
            verifier: verifier,
            output: output
        )

        let exitCode = await application.run(arguments: ["verify"])

        XCTAssertEqual(exitCode, ManualVerifierExitCode.success)
        XCTAssertEqual(store.loadCallCount, 1)
        XCTAssertEqual(verifier.calls.count, 1)
        XCTAssertEqual(verifier.calls.first?.credentials, credentials)
        XCTAssertEqual(verifier.calls.first?.path.description, terminalPath)
        XCTAssertEqual(output.values, [SanitizedReportRenderer().render(report)])
        assertRedacted(output.values)
    }

    func testDependencyFailuresProduceOnlyFixedRedactedOutput() async {
        let sensitiveError = SensitiveFailure(
            description: "stored-user stored-password https://dav.jianguoyun.com/dav secret/root"
        )

        let storeTerminal = FakeTerminal(
            lineResults: [.success("stored-user")],
            secretResults: [.success("stored-password")]
        )
        let failingStore = FakeCredentialStore(saveResults: [.failure(sensitiveError)])
        let storeOutput = OutputSpy()
        let storeApplication = makeApplication(
            terminal: storeTerminal,
            store: failingStore,
            output: storeOutput
        )
        let storeExitCode = await storeApplication.run(arguments: ["store-credentials"])
        XCTAssertEqual(storeExitCode, ManualVerifierExitCode.failure)
        XCTAssertEqual(storeOutput.values, ["Credential storage failed."])

        let loadOutput = OutputSpy()
        let loadApplication = makeApplication(
            terminal: FakeTerminal(),
            store: FakeCredentialStore(loadResult: .failure(sensitiveError)),
            output: loadOutput
        )
        let loadExitCode = await loadApplication.run(arguments: ["verify"])
        XCTAssertEqual(loadExitCode, ManualVerifierExitCode.failure)
        XCTAssertEqual(loadOutput.values, ["Verification failed."])

        let verifyOutput = OutputSpy()
        let verifyApplication = makeApplication(
            terminal: FakeTerminal(lineResults: [.success("secret/root")]),
            store: FakeCredentialStore(
                loadResult: .success(
                    Credentials(username: "stored-user", applicationPassword: "stored-password")
                )
            ),
            verifier: VerificationSpy(result: .failure(sensitiveError)),
            output: verifyOutput
        )
        let verifyExitCode = await verifyApplication.run(arguments: ["verify"])
        XCTAssertEqual(verifyExitCode, ManualVerifierExitCode.failure)
        XCTAssertEqual(verifyOutput.values, ["Verification failed."])

        let deleteOutput = OutputSpy()
        let deleteApplication = makeApplication(
            terminal: FakeTerminal(lineResults: [.success("DELETE")]),
            store: FakeCredentialStore(deleteResult: .failure(sensitiveError)),
            output: deleteOutput
        )
        let deleteExitCode = await deleteApplication.run(arguments: ["delete-credentials"])
        XCTAssertEqual(deleteExitCode, ManualVerifierExitCode.failure)
        XCTAssertEqual(deleteOutput.values, ["Credential deletion failed."])

        assertRedacted(
            storeOutput.values + loadOutput.values + verifyOutput.values + deleteOutput.values
        )
    }

    func testStoreCredentialsRendersOnlyKeychainStatusForKeychainStatusFailure() async {
        let terminal = FakeTerminal(
            lineResults: [.success("terminal-user")],
            secretResults: [.success("terminal-password")]
        )
        let store = FakeCredentialStore(
            saveResults: [
                .failure(GenericPasswordKeychainClientError.unexpectedStatus(-50))
            ]
        )
        let output = OutputSpy()
        let application = makeApplication(terminal: terminal, store: store, output: output)

        let exitCode = await application.run(arguments: ["store-credentials"])

        XCTAssertEqual(exitCode, ManualVerifierExitCode.failure)
        XCTAssertEqual(
            output.values,
            ["Credential storage failed: macOS Keychain status -50."]
        )
        assertRedacted(output.values)
    }

    func testStoreCredentialsIdentifiesSafeTerminalInputFailureWithoutLeakingCredentials() async {
        let terminal = FakeTerminal(
            lineResults: [.success("terminal-user")],
            secretResults: [.failure(TerminalInputError.readFailed)]
        )
        let store = FakeCredentialStore()
        let output = OutputSpy()
        let application = makeApplication(terminal: terminal, store: store, output: output)

        let exitCode = await application.run(arguments: ["store-credentials"])

        XCTAssertEqual(exitCode, ManualVerifierExitCode.failure)
        XCTAssertEqual(
            output.values,
            ["Credential storage failed: terminal input unavailable."]
        )
        XCTAssertTrue(store.saveCalls.isEmpty)
        assertRedacted(output.values)
    }

    func testStoreCredentialsRendersOnlyTerminalSystemErrorForSignalMonitoringFailure() async {
        let terminal = FakeTerminal(
            lineResults: [.success("terminal-user")],
            secretResults: [.failure(TerminalInputError.signalMonitoringUnavailable(22))]
        )
        let store = FakeCredentialStore()
        let output = OutputSpy()
        let application = makeApplication(terminal: terminal, store: store, output: output)

        let exitCode = await application.run(arguments: ["store-credentials"])

        XCTAssertEqual(exitCode, ManualVerifierExitCode.failure)
        XCTAssertEqual(
            output.values,
            ["Credential storage failed: terminal signal monitoring error 22."]
        )
        XCTAssertTrue(store.saveCalls.isEmpty)
        assertRedacted(output.values)
    }

    func testStoreCredentialsIdentifiesEmptyTerminalInputWithoutLeakingCredentials() async {
        let terminal = FakeTerminal(
            lineResults: [.success("terminal-user")],
            secretResults: [.failure(TerminalInputError.emptyInput)]
        )
        let store = FakeCredentialStore()
        let output = OutputSpy()
        let application = makeApplication(terminal: terminal, store: store, output: output)

        let exitCode = await application.run(arguments: ["store-credentials"])

        XCTAssertEqual(exitCode, ManualVerifierExitCode.failure)
        XCTAssertEqual(
            output.values,
            ["Credential storage failed: username and application password must not be empty."]
        )
        XCTAssertTrue(store.saveCalls.isEmpty)
        assertRedacted(output.values)
    }

    func testCleanupFailuresProduceFixedActionableRedactedOutput() async {
        let cases: [(VerifierFailure, String)] = [
            (
                .manualReviewRequired,
                "Verification stopped: manual review required; automatic cleanup is disabled."
            ),
            (
                .cleanupFailed,
                "Verification failed: cleanup incomplete; retry with the same account and directory."
            ),
            (
                .runAlreadyInProgress,
                "Verification failed: another verifier run is active."
            ),
        ]

        for (failure, expectedOutput) in cases {
            let output = OutputSpy()
            let application = makeApplication(
                terminal: FakeTerminal(lineResults: [.success("secret/root")]),
                store: FakeCredentialStore(
                    loadResult: .success(
                        Credentials(
                            username: "stored-user",
                            applicationPassword: "stored-password"
                        )
                    )
                ),
                verifier: VerificationSpy(result: .failure(failure)),
                output: output
            )

            let exitCode = await application.run(arguments: ["verify"])
            XCTAssertEqual(exitCode, ManualVerifierExitCode.failure)
            XCTAssertEqual(output.values, [expectedOutput])
            assertRedacted(output.values)
        }
    }

    func testVerifierFailuresProduceOnlyFixedRedactedReasonCodes() async {
        let cases: [(VerifierFailure, String)] = [
            (.authenticationProbeFailed, "authentication-probe-failed"),
            (.authenticationChallengeRejected, "authentication-challenge-rejected"),
            (.authenticationCredentialsRejected, "authentication-credentials-rejected"),
            (.dedicatedDirectoryUnavailable, "dedicated-directory-unavailable"),
            (
                .dedicatedDirectoryHTTPStatus(depth: 0, status: 401),
                "dedicated-directory-depth-0-http-401"
            ),
            (.dedicatedDirectoryNotEmpty, "dedicated-directory-not-empty"),
            (.invalidHTTPStatus, "invalid-http-status"),
            (.missingStrongETag, "missing-strong-etag"),
            (.responseBodyMismatch, "response-body-mismatch"),
            (.staleWriteWasAccepted, "stale-write-was-accepted"),
            (.staleWriteChangedBody, "stale-write-changed-body"),
            (.staleDeleteWasAccepted, "stale-delete-was-accepted"),
            (.staleDeleteChangedResource, "stale-delete-changed-resource"),
            (.remoteOperationFailed, "remote-operation-failed"),
        ]

        for (failure, reasonCode) in cases {
            let output = OutputSpy()
            let application = makeApplication(
                terminal: FakeTerminal(lineResults: [.success("secret/root")]),
                store: FakeCredentialStore(
                    loadResult: .success(
                        Credentials(
                            username: "stored-user",
                            applicationPassword: "stored-password"
                        )
                    )
                ),
                verifier: VerificationSpy(result: .failure(failure)),
                output: output
            )

            let exitCode = await application.run(arguments: ["verify"])

            XCTAssertEqual(exitCode, ManualVerifierExitCode.failure)
            XCTAssertEqual(output.values, ["Verification failed: reason=\(reasonCode)."])
            assertRedacted(output.values)
        }
    }

    private func makeApplication(
        terminal: FakeTerminal,
        store: FakeCredentialStore,
        verifier: VerificationSpy = VerificationSpy(),
        output: OutputSpy
    ) -> ManualVerifierApplication {
        ManualVerifierApplication(
            terminal: terminal,
            credentialStore: store,
            verify: verifier.verify(credentials:dedicatedRoot:),
            output: output.write(_:)
        )
    }

    private func makeReport() -> VerificationReport {
        VerificationReport(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            toolVersion: .v1,
            results: [
                CapabilityResult(
                    capability: .staleETagPrecondition,
                    status: .pass,
                    httpStatus: 412,
                    reason: nil,
                    evidence: [.bodyUnchanged]
                )
            ]
        )
    }

    private func assertRedacted(
        _ output: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rendered = output.joined(separator: "\n")
        for secret in [
            "leaked-user",
            "leaked-password",
            "stored-user",
            "stored-password",
            "terminal-user",
            "terminal-password",
            "https://dav.jianguoyun.com/dav",
            "secret/root",
            "manual-verifier-only",
            "../private-directory",
        ] {
            XCTAssertFalse(
                rendered.contains(secret), "output leaked \(secret)", file: file, line: line)
        }
    }
}

@MainActor
private final class FakeTerminal: ManualVerifierTerminal {
    private var lineResults: [Result<String, any Error>]
    private var secretResults: [Result<String, any Error>]

    private(set) var linePrompts: [String] = []
    private(set) var secretPrompts: [String] = []

    init(
        lineResults: [Result<String, any Error>] = [],
        secretResults: [Result<String, any Error>] = []
    ) {
        self.lineResults = lineResults
        self.secretResults = secretResults
    }

    func readLine(prompt: String) throws -> String {
        linePrompts.append(prompt)
        guard !lineResults.isEmpty else { throw FakeFailure.unexpectedCall }
        return try lineResults.removeFirst().get()
    }

    func readSecret(prompt: String) throws -> String {
        secretPrompts.append(prompt)
        guard !secretResults.isEmpty else { throw FakeFailure.unexpectedCall }
        return try secretResults.removeFirst().get()
    }
}

private struct SaveCall: Equatable {
    let credentials: Credentials
    let overwrite: Bool
}

@MainActor
private final class FakeCredentialStore: ManualVerifierCredentialStore {
    private var saveResults: [Result<Void, any Error>]
    private let loadResult: Result<Credentials?, any Error>
    private let deleteResult: Result<Void, any Error>

    private(set) var saveCalls: [SaveCall] = []
    private(set) var loadCallCount = 0
    private(set) var deleteCallCount = 0

    init(
        saveResults: [Result<Void, any Error>] = [],
        loadResult: Result<Credentials?, any Error> = .success(nil),
        deleteResult: Result<Void, any Error> = .success(())
    ) {
        self.saveResults = saveResults
        self.loadResult = loadResult
        self.deleteResult = deleteResult
    }

    func save(_ credentials: Credentials, overwrite: Bool) throws {
        saveCalls.append(SaveCall(credentials: credentials, overwrite: overwrite))
        guard !saveResults.isEmpty else { return }
        try saveResults.removeFirst().get()
    }

    func load() throws -> Credentials? {
        loadCallCount += 1
        return try loadResult.get()
    }

    func delete() throws {
        deleteCallCount += 1
        try deleteResult.get()
    }
}

private struct VerificationCall: Equatable {
    let credentials: Credentials
    let path: VerifierPath
}

@MainActor
private final class VerificationSpy {
    private let result: Result<VerificationReport, any Error>
    private(set) var calls: [VerificationCall] = []

    init(
        result: Result<VerificationReport, any Error> =
            .success(VerificationSpy.defaultReport)
    ) {
        self.result = result
    }

    func verify(
        credentials: Credentials,
        dedicatedRoot: VerifierPath
    ) async throws -> VerificationReport {
        calls.append(VerificationCall(credentials: credentials, path: dedicatedRoot))
        return try result.get()
    }

    private static let defaultReport = VerificationReport(
        generatedAt: Date(timeIntervalSince1970: 0),
        toolVersion: .v1,
        results: []
    )
}

@MainActor
private final class OutputSpy {
    private(set) var values: [String] = []

    func write(_ value: String) {
        values.append(value)
    }
}

private enum FakeFailure: Error {
    case unexpectedCall
}

private struct SensitiveFailure: Error {
    let description: String
}

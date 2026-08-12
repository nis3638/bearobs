@MainActor
public protocol ManualVerifierTerminal {
    func readLine(prompt: String) throws -> String
    func readSecret(prompt: String) throws -> String
}

@MainActor
public protocol ManualVerifierCredentialStore {
    func save(_ credentials: Credentials, overwrite: Bool) throws
    func load() throws -> Credentials?
    func delete() throws
}

public enum ManualVerifierExitCode: Int32, Equatable, Sendable {
    case success = 0
    case failure = 1
    case usage = 64
}

@MainActor
public struct ManualVerifierApplication {
    public static let usage =
        "Usage: JianguoyunWebDAVVerifier <store-credentials|verify|delete-credentials>"

    private let terminal: any ManualVerifierTerminal
    private let credentialStore: any ManualVerifierCredentialStore
    private let verify: @MainActor (Credentials, VerifierPath) async throws -> VerificationReport
    private let output: @MainActor (String) -> Void

    public init(
        terminal: any ManualVerifierTerminal,
        credentialStore: any ManualVerifierCredentialStore,
        verify:
            @escaping @MainActor (
                Credentials,
                VerifierPath
            ) async throws -> VerificationReport,
        output: @escaping @MainActor (String) -> Void
    ) {
        self.terminal = terminal
        self.credentialStore = credentialStore
        self.verify = verify
        self.output = output
    }

    public func run(arguments: [String]) async -> ManualVerifierExitCode {
        let command: ManualVerifierCommand
        do {
            command = try ManualVerifierCommand.parse(arguments: arguments)
        } catch {
            output(Self.usage)
            return .usage
        }

        switch command.action {
        case .storeCredentials:
            return storeCredentials()
        case .verify:
            return await verifyCredentials()
        case .deleteCredentials:
            return deleteCredentials()
        }
    }

    private func storeCredentials() -> ManualVerifierExitCode {
        do {
            let credentials = Credentials(
                username: try terminal.readLine(prompt: "Username: "),
                applicationPassword: try terminal.readSecret(prompt: "Application password: ")
            )

            do {
                try credentialStore.save(credentials, overwrite: false)
            } catch KeychainCredentialStoreError.itemAlreadyExists {
                let confirmation = try terminal.readLine(
                    prompt: "Type OVERWRITE to replace stored credentials: "
                )
                guard ConfirmationPolicy.overwriteCredentials.accepts(confirmation) else {
                    output("Credentials were not changed.")
                    return .failure
                }
                try credentialStore.save(credentials, overwrite: true)
            }

            output("Credentials stored.")
            return .success
        } catch TerminalInputError.emptyInput {
            output(
                "Credential storage failed: username and application password must not be empty."
            )
            return .failure
        } catch TerminalInputError.openFailed, TerminalInputError.notControllingTerminal {
            output("Credential storage failed: an interactive terminal is required.")
            return .failure
        } catch TerminalInputError.modeReadFailed {
            output("Credential storage failed: terminal mode is unavailable.")
            return .failure
        } catch TerminalInputError.signalMonitoringUnavailable(let code) {
            output("Credential storage failed: terminal signal monitoring error \(code).")
            return .failure
        } catch is TerminalInputError {
            output("Credential storage failed: terminal input unavailable.")
            return .failure
        } catch GenericPasswordKeychainClientError.unexpectedStatus(let status) {
            output("Credential storage failed: macOS Keychain status \(status).")
            return .failure
        } catch {
            output("Credential storage failed.")
            return .failure
        }
    }

    private func verifyCredentials() async -> ManualVerifierExitCode {
        do {
            guard let credentials = try credentialStore.load() else {
                output("Verification failed: credentials unavailable.")
                return .failure
            }

            let pathInput = try terminal.readLine(prompt: "Dedicated directory: ")
            let dedicatedRoot: VerifierPath
            do {
                dedicatedRoot = try VerifierPath(decodedRelativePath: pathInput)
            } catch {
                output("Verification failed: invalid dedicated directory.")
                return .failure
            }

            let report = try await verify(credentials, dedicatedRoot)
            output(SanitizedReportRenderer().render(report))
            return .success
        } catch VerifierFailure.manualReviewRequired {
            output("Verification stopped: manual review required; automatic cleanup is disabled.")
            return .failure
        } catch VerifierFailure.cleanupFailed {
            output(
                "Verification failed: cleanup incomplete; retry with the same account and directory."
            )
            return .failure
        } catch VerifierFailure.runAlreadyInProgress {
            output("Verification failed: another verifier run is active.")
            return .failure
        } catch let failure as VerifierFailure {
            output("Verification failed: reason=\(failure.safeReasonCode).")
            return .failure
        } catch {
            output("Verification failed.")
            return .failure
        }
    }

    private func deleteCredentials() -> ManualVerifierExitCode {
        do {
            let confirmation = try terminal.readLine(
                prompt: "Type DELETE to delete stored credentials: "
            )
            guard ConfirmationPolicy.deleteCredentials.accepts(confirmation) else {
                output("Credentials were not deleted.")
                return .failure
            }

            try credentialStore.delete()
            output("Credentials deleted.")
            return .success
        } catch {
            output("Credential deletion failed.")
            return .failure
        }
    }
}

extension ControllingTerminal: ManualVerifierTerminal {}
extension KeychainCredentialStore: ManualVerifierCredentialStore {}

extension VerifierFailure {
    fileprivate var safeReasonCode: String {
        switch self {
        case .authenticationProbeFailed:
            "authentication-probe-failed"
        case .authenticationChallengeRejected:
            "authentication-challenge-rejected"
        case .authenticationCredentialsRejected:
            "authentication-credentials-rejected"
        case .dedicatedDirectoryUnavailable:
            "dedicated-directory-unavailable"
        case .dedicatedDirectoryHTTPStatus(let depth, let status):
            "dedicated-directory-depth-\(depth)-http-\(status)"
        case .dedicatedDirectoryNotEmpty:
            "dedicated-directory-not-empty"
        case .invalidHTTPStatus:
            "invalid-http-status"
        case .missingStrongETag:
            "missing-strong-etag"
        case .responseBodyMismatch:
            "response-body-mismatch"
        case .staleWriteWasAccepted:
            "stale-write-was-accepted"
        case .staleWriteChangedBody:
            "stale-write-changed-body"
        case .staleDeleteWasAccepted:
            "stale-delete-was-accepted"
        case .staleDeleteChangedResource:
            "stale-delete-changed-resource"
        case .cleanupFailed:
            "cleanup-failed"
        case .manualReviewRequired:
            "manual-review-required"
        case .runAlreadyInProgress:
            "run-already-in-progress"
        case .remoteOperationFailed:
            "remote-operation-failed"
        }
    }
}

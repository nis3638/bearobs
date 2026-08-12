import Darwin
import Foundation
import JianguoyunWebDAVVerifierCore

@main
enum Main {
    @MainActor
    static func main() async {
        do {
            let terminal = try ControllingTerminal()
            let credentialStore = KeychainCredentialStore()
            let journal = RecoveryJournal(fileURL: recoveryJournalURL)

            let application = ManualVerifierApplication(
                terminal: terminal,
                credentialStore: credentialStore,
                verify: { credentials, dedicatedRoot in
                    let scope = RemoteScope(dedicatedRoot: dedicatedRoot)
                    let remote = URLSessionWebDAVTransport(
                        dedicatedRoot: scope.dedicatedRoot,
                        credentials: credentials
                    )
                    let verifier = JianguoyunVerifier(
                        remote: remote,
                        journal: journal,
                        runComponent: "bearobs-m0-11-run-\(UUID().uuidString.lowercased())",
                        scopeIdentifier: [
                            JianguoyunEndpoint.baseURL.absoluteString,
                            dedicatedRoot.percentEncodedRelativePath,
                            credentials.username,
                        ].joined(separator: "|")
                    )
                    return try await verifier.verify()
                },
                output: { print($0) }
            )

            let exitCode = await application.run(
                arguments: Array(CommandLine.arguments.dropFirst())
            )
            Darwin.exit(exitCode.rawValue)
        } catch {
            print("Initialization failed.")
            Darwin.exit(ManualVerifierExitCode.failure.rawValue)
        }
    }

    private static var recoveryJournalURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(
                "com.bearobs.m0-11.jianguoyun",
                isDirectory: true
            )
            .appendingPathComponent("recovery-v1.json", isDirectory: false)
    }
}

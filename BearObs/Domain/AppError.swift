import Foundation

enum AppErrorCategory: String, CaseIterable, Codable, Hashable, Sendable {
    case configuration
    case authentication
    case tls
    case remoteUnavailable
    case incompatibleServer
    case pathRejected
    case localStorage
    case parsing
    case database
    case conflict
    case cancelled
}

enum RecoveryAction: String, Codable, Hashable, Sendable {
    case editConfiguration
    case reauthenticate
    case fixServerCertificate
    case retryLater
    case viewCompatibility
    case skipAndReport
    case freeStorageAndRetry
    case readOriginal
    case rebuildIndex
    case resolveConflict
    case preserveCommittedProgress
}

enum DiagnosticOperation: String, Codable, Hashable, Sendable {
    case configuration
    case authentication
    case remoteList
    case remoteRead
    case remoteWrite
    case localRead
    case localWrite
    case parse
    case database
    case syncPlan
}

enum DiagnosticSubsystem: String, Codable, Hashable, Sendable {
    case domain
    case http
    case urlSession
    case posix
    case sqlite
    case markdown
}

struct ErrorDiagnostic: Codable, Hashable, Sendable {
    let operation: DiagnosticOperation
    let subsystem: DiagnosticSubsystem
    let code: Int
    let correlationID: UUID?
}

struct AppError: Error, Codable, Hashable, Sendable {
    let category: AppErrorCategory
    let diagnostic: ErrorDiagnostic?

    init(
        category: AppErrorCategory,
        diagnostic: ErrorDiagnostic? = nil
    ) {
        self.category = category
        self.diagnostic = diagnostic
    }

    var recoveryAction: RecoveryAction {
        switch category {
        case .configuration: .editConfiguration
        case .authentication: .reauthenticate
        case .tls: .fixServerCertificate
        case .remoteUnavailable: .retryLater
        case .incompatibleServer: .viewCompatibility
        case .pathRejected: .skipAndReport
        case .localStorage: .freeStorageAndRetry
        case .parsing: .readOriginal
        case .database: .rebuildIndex
        case .conflict: .resolveConflict
        case .cancelled: .preserveCommittedProgress
        }
    }

    var userMessageKey: String {
        "error.\(category.rawValue)"
    }

    var isRetryable: Bool {
        category == .remoteUnavailable
    }
}

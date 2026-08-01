import Foundation
import XCTest

#if SWIFT_PACKAGE
    @testable import BearObsDomain
#else
    @testable import BearObs
#endif

final class AppErrorTests: XCTestCase {
    func testEveryCategoryHasOneDerivedRecoveryAction() {
        let expected: [AppErrorCategory: RecoveryAction] = [
            .configuration: .editConfiguration,
            .authentication: .reauthenticate,
            .tls: .fixServerCertificate,
            .remoteUnavailable: .retryLater,
            .incompatibleServer: .viewCompatibility,
            .pathRejected: .skipAndReport,
            .localStorage: .freeStorageAndRetry,
            .parsing: .readOriginal,
            .database: .rebuildIndex,
            .conflict: .resolveConflict,
            .cancelled: .preserveCommittedProgress,
        ]

        XCTAssertEqual(expected.count, AppErrorCategory.allCases.count)
        for category in AppErrorCategory.allCases {
            XCTAssertEqual(
                AppError(category: category).recoveryAction,
                expected[category]
            )
        }
    }

    func testEveryCategoryRoundTripsThroughCodable() throws {
        for category in AppErrorCategory.allCases {
            let error = AppError(
                category: category,
                diagnostic: ErrorDiagnostic(
                    operation: .syncPlan,
                    subsystem: .domain,
                    code: 42,
                    correlationID: UUID(
                        uuidString: "00000000-0000-0000-0000-000000000010"
                    )
                )
            )
            let data = try JSONEncoder().encode(error)

            XCTAssertEqual(
                try JSONDecoder().decode(AppError.self, from: data),
                error
            )
        }
    }

    func testUserPresentationIsDerivedWithoutDiagnosticDetails() {
        let diagnostic = ErrorDiagnostic(
            operation: .remoteRead,
            subsystem: .http,
            code: 401,
            correlationID: nil
        )
        let error = AppError(
            category: .authentication,
            diagnostic: diagnostic
        )

        XCTAssertEqual(error.userMessageKey, "error.authentication")
        XCTAssertFalse(error.userMessageKey.contains("401"))
        XCTAssertFalse(error.isRetryable)
    }

    func testDiagnosticSchemaContainsNoArbitraryTextFields() throws {
        let diagnostic = ErrorDiagnostic(
            operation: .remoteWrite,
            subsystem: .http,
            code: 412,
            correlationID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000010"
            )
        )
        let object =
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(diagnostic)
            ) as? [String: Any]

        XCTAssertEqual(
            Set(object?.keys.map { $0 } ?? []),
            Set(["operation", "subsystem", "code", "correlationID"])
        )
    }

    func testCancellationPreservesProgressAndIsNotRetryable() {
        let error = AppError(category: .cancelled)

        XCTAssertEqual(
            error.recoveryAction,
            .preserveCommittedProgress
        )
        XCTAssertFalse(error.isRetryable)
    }
}

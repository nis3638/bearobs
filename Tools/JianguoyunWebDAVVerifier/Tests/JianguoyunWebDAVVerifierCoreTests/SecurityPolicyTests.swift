import Foundation
import XCTest

@testable import JianguoyunWebDAVVerifierCore

final class SecurityPolicyTests: XCTestCase {
    func testScopeUsesFixedHTTPSOriginAndDedicatedRoot() throws {
        let scope = RemoteScope(
            dedicatedRoot: try VerifierPath(decodedRelativePath: "BearObs 验证%")
        )

        XCTAssertEqual(JianguoyunEndpoint.baseURL.absoluteString, "https://dav.jianguoyun.com/dav/")
        XCTAssertEqual(
            scope.rootURL.absoluteString,
            "https://dav.jianguoyun.com/dav/BearObs%20%E9%AA%8C%E8%AF%81%25/"
        )
        XCTAssertEqual(
            try scope.resourceURL(
                for: VerifierPath(decodedRelativePath: "子 dir/literal%.md")
            ).absoluteString,
            "https://dav.jianguoyun.com/dav/BearObs%20%E9%AA%8C%E8%AF%81%25/"
                + "%E5%AD%90%20dir/literal%25.md"
        )
    }

    func testFinalResponseAndHrefMustRemainInsideScope() throws {
        let scope = RemoteScope(
            dedicatedRoot: try VerifierPath(decodedRelativePath: "private-root"))
        let accepted = [
            "https://dav.jianguoyun.com/dav/private-root/",
            "https://dav.jianguoyun.com/dav/private-root/a%20b.md",
            "/dav/private-root/unicode-%E9%AA%8C%E8%AF%81.md",
        ]
        for value in accepted {
            XCTAssertNoThrow(try scope.relativePath(forHref: value), value)
        }

        let rejected = [
            "http://dav.jianguoyun.com/dav/private-root/a.md",
            "https://evil.example/dav/private-root/a.md",
            "https://user@dav.jianguoyun.com/dav/private-root/a.md",
            "https://dav.jianguoyun.com/dav/private-root/a.md?secret=1",
            "https://dav.jianguoyun.com/dav/other/a.md",
            "https://dav.jianguoyun.com/private-root/a.md",
            "/dav/private-root/%2E%2E/other.md",
        ]
        for value in rejected {
            XCTAssertThrowsError(try scope.relativePath(forHref: value), value)
        }
    }

    func testChallengePolicyAllowsOnlyFirstTargetBasicOrDigestChallenge() {
        let policy = ChallengePolicy()
        let target = [AuthenticationMethod.basic, .digest]
        for method in target {
            XCTAssertEqual(
                policy.disposition(
                    for: ChallengeContext(
                        method: method,
                        host: "dav.jianguoyun.com",
                        protocolName: "https",
                        port: 443,
                        previousFailureCount: 0
                    ),
                    credentialsAvailable: true
                ),
                .useCredential
            )
        }

        let rejected = [
            ChallengeContext(
                method: .basic,
                host: "evil.example",
                protocolName: "https",
                port: 443,
                previousFailureCount: 0
            ),
            ChallengeContext(
                method: .digest,
                host: "dav.jianguoyun.com",
                protocolName: "http",
                port: 80,
                previousFailureCount: 0
            ),
            ChallengeContext(
                method: .basic,
                host: "dav.jianguoyun.com",
                protocolName: "https",
                port: 443,
                previousFailureCount: 1
            ),
            ChallengeContext(
                method: .other,
                host: "dav.jianguoyun.com",
                protocolName: "https",
                port: 443,
                previousFailureCount: 0
            ),
        ]
        for context in rejected {
            XCTAssertEqual(
                policy.disposition(for: context, credentialsAvailable: true),
                .reject
            )
        }
    }

    func testServerTrustUsesSystemDefaultAndRedirectsAreAlwaysRejected() throws {
        let disposition = ChallengePolicy().disposition(
            for: ChallengeContext(
                method: .serverTrust,
                host: "dav.jianguoyun.com",
                protocolName: "https",
                port: 443,
                previousFailureCount: 0
            ),
            credentialsAvailable: false
        )
        XCTAssertEqual(disposition, .performDefaultHandling)

        let policy = RedirectPolicy()
        let original = URL(string: "https://dav.jianguoyun.com/dav/private-root/a")!
        for target in [
            URL(string: "https://dav.jianguoyun.com/dav/private-root/b")!,
            URL(string: "https://evil.example/dav/private-root/b")!,
            URL(string: "http://dav.jianguoyun.com/dav/private-root/b")!,
            URL(string: "https://dav.jianguoyun.com/dav/other/b")!,
        ] {
            XCTAssertFalse(policy.shouldFollow(from: original, to: target))
        }
    }
}

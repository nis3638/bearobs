import Foundation

/// Version of the verifier that produced a sanitized capability report.
public enum ToolVersion: String, Codable, Equatable, Sendable {
    case v1
}

/// Capabilities whose results may appear in the public verifier report.
///
/// This is deliberately a closed set. Adding a capability requires an explicit
/// renderer mapping so arbitrary or sensitive text can never become report data.
public enum Capability: String, Codable, Equatable, Sendable {
    case staleETagPrecondition
    case staleWritePreservesBody
    case staleDeletePrecondition
    case paginationBeyond750
}

/// Sanitized outcome of a capability check.
public enum CapabilityStatus: String, Codable, Equatable, Sendable {
    case pass
    case fail
    case blocked
    case unavailable
}

/// Fixed reason codes permitted in a sanitized report.
public enum ReportReason: String, Codable, Equatable, Sendable {
    case vendorPaginationProtocolUndocumented
}

/// Fixed evidence codes permitted in a sanitized report.
public enum ReportEvidence: String, Codable, Equatable, Sendable {
    case bodyUnchanged
}

/// One result in the closed, sanitized capability matrix.
public struct CapabilityResult: Codable, Equatable, Sendable {
    public let capability: Capability
    public let status: CapabilityStatus
    public let httpStatus: Int?
    public let reason: ReportReason?
    public let evidence: [ReportEvidence]

    public init(
        capability: Capability,
        status: CapabilityStatus,
        httpStatus: Int?,
        reason: ReportReason?,
        evidence: [ReportEvidence]
    ) {
        self.capability = capability
        self.status = status
        self.httpStatus = httpStatus.flatMap(Self.sanitizedHTTPStatus(_:))
        self.reason = reason
        self.evidence = evidence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let capability = try container.decode(Capability.self, forKey: .capability)
        let status = try container.decode(CapabilityStatus.self, forKey: .status)
        let decodedHTTPStatus = try container.decodeIfPresent(Int.self, forKey: .httpStatus)
        let reason = try container.decodeIfPresent(ReportReason.self, forKey: .reason)
        let evidence = try container.decode([ReportEvidence].self, forKey: .evidence)

        guard decodedHTTPStatus.map(Self.isPermittedHTTPStatus(_:)) ?? true else {
            throw DecodingError.dataCorruptedError(
                forKey: .httpStatus,
                in: container,
                debugDescription: "HTTP status is outside the permitted range"
            )
        }

        self.init(
            capability: capability,
            status: status,
            httpStatus: decodedHTTPStatus,
            reason: reason,
            evidence: evidence
        )
    }

    private static func sanitizedHTTPStatus(_ status: Int) -> Int? {
        (100...599).contains(status) ? status : nil
    }

    private static func isPermittedHTTPStatus(_ status: Int) -> Bool {
        (100...599).contains(status)
    }
}

/// A verifier report whose schema has no free-text or sensitive-value fields.
public struct VerificationReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let toolVersion: ToolVersion
    public let results: [CapabilityResult]

    public init(
        generatedAt: Date,
        toolVersion: ToolVersion,
        results: [CapabilityResult]
    ) {
        self.generatedAt = generatedAt
        self.toolVersion = toolVersion
        self.results = results
    }
}

/// Renders only fixed labels and validated numeric/time values.
///
/// URLs, paths, credentials, headers, bodies, and raw entity-tags cannot be
/// supplied to this renderer because the report model has no such fields.
public struct SanitizedReportRenderer: Sendable {
    public init() {}

    public func render(_ report: VerificationReport) -> String {
        let header = [
            "jianguoyun-webdav-verifier",
            "tool=\(render(report.toolVersion))",
            "generated-at-unix=\(render(report.generatedAt))",
        ].joined(separator: " ")
        let resultLines = report.results.map(render(_:))
        return ([header] + resultLines).joined(separator: "\n")
    }

    private func render(_ result: CapabilityResult) -> String {
        var fields = [render(result.capability), render(result.status)]
        if let httpStatus = result.httpStatus {
            fields.append("http=\(httpStatus)")
        }
        if let reason = result.reason {
            fields.append(render(reason))
        }
        fields.append(contentsOf: result.evidence.map(render(_:)))
        return fields.joined(separator: " ")
    }

    private func render(_ version: ToolVersion) -> String {
        switch version {
        case .v1:
            "v1"
        }
    }

    private func render(_ capability: Capability) -> String {
        switch capability {
        case .staleETagPrecondition:
            "stale-etag-precondition"
        case .staleWritePreservesBody:
            "stale-write-preserves-body"
        case .staleDeletePrecondition:
            "stale-delete-precondition"
        case .paginationBeyond750:
            "pagination-beyond-750"
        }
    }

    private func render(_ status: CapabilityStatus) -> String {
        switch status {
        case .pass:
            "PASS"
        case .fail:
            "FAIL"
        case .blocked:
            "BLOCKED"
        case .unavailable:
            "UNAVAILABLE"
        }
    }

    private func render(_ reason: ReportReason) -> String {
        switch reason {
        case .vendorPaginationProtocolUndocumented:
            "vendor-pagination-protocol-undocumented"
        }
    }

    private func render(_ evidence: ReportEvidence) -> String {
        switch evidence {
        case .bodyUnchanged:
            "body-unchanged"
        }
    }

    private func render(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        guard seconds.isFinite,
            seconds >= TimeInterval(Int64.min),
            seconds <= TimeInterval(Int64.max)
        else {
            return "unavailable"
        }
        return String(Int64(seconds.rounded(.towardZero)))
    }
}

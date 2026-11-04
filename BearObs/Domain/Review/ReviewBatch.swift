import Foundation

/// 当日批次实体（REQ-005 §9.3）：按 Vault 一份，身份是 `vaultID + day`。
public struct ReviewBatch: Hashable, Codable, Sendable {
    public let vaultID: UUID
    /// 本地日历日，只保留年、月、日（REQ-005 §3 共享约定）。
    public let day: DateComponents
    public let rule: ReviewRule
    public let orderedPaths: [String]

    public init(
        vaultID: UUID,
        day: DateComponents,
        rule: ReviewRule,
        orderedPaths: [String]
    ) {
        self.vaultID = vaultID
        self.day = Self.normalizedDay(day)
        self.rule = rule
        self.orderedPaths = orderedPaths
    }

    /// 从日期取本地日历日（用户当前日历，不使用 UTC 日），只保留年月日。
    public static func localDay(from date: Date, calendar: Calendar) -> DateComponents {
        var day = calendar.dateComponents([.year, .month, .day], from: date)
        day.calendar = nil
        day.timeZone = nil
        return day
    }

    private static func normalizedDay(_ day: DateComponents) -> DateComponents {
        var normalized = DateComponents()
        normalized.year = day.year
        normalized.month = day.month
        normalized.day = day.day
        return normalized
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            vaultID: container.decode(UUID.self, forKey: .vaultID),
            day: container.decode(DateComponents.self, forKey: .day),
            rule: container.decode(ReviewRule.self, forKey: .rule),
            orderedPaths: container.decode([String].self, forKey: .orderedPaths)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case vaultID
        case day
        case rule
        case orderedPaths
    }
}

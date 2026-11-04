import Foundation

/// 每日回顾规则（REQ-005 §9.2）。
///
/// 值对象：内容范围 + 时间范围 + 每日数量，按 Vault 存在沙箱。
public struct ReviewRule: Hashable, Codable, Sendable {
    public enum ContentScope: Hashable, Codable, Sendable {
        case all
        case includingTag(String)
        case excludingTag(String)
        case untagged
    }

    public enum TimeScope: Hashable, Codable, Sendable {
        case all
        case pastYear
        case pastSixMonths
        case pastThreeMonths
        case pastMonth

        /// 时间范围对应的修改时间下限；`all` 没有下限。
        public func cutoff(from now: Date, calendar: Calendar) -> Date? {
            switch self {
            case .all:
                return nil
            case .pastYear:
                return calendar.date(byAdding: .year, value: -1, to: now)
            case .pastSixMonths:
                return calendar.date(byAdding: .month, value: -6, to: now)
            case .pastThreeMonths:
                return calendar.date(byAdding: .month, value: -3, to: now)
            case .pastMonth:
                return calendar.date(byAdding: .month, value: -1, to: now)
            }
        }
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidDailyCount(Int)
    }

    public static let allowedDailyCounts: Set<Int> = [4, 8, 12, 16, 20, 24]
    public static let defaultDailyCount = 8

    public let contentScope: ContentScope
    public let timeScope: TimeScope
    public let dailyCount: Int

    /// `dailyCount` 仅允许 4 的倍数且在 4...24 内（REQ-005 §9.2）。
    public init(
        contentScope: ContentScope = .all,
        timeScope: TimeScope = .all,
        dailyCount: Int = ReviewRule.defaultDailyCount
    ) throws {
        guard Self.allowedDailyCounts.contains(dailyCount) else {
            throw ValidationError.invalidDailyCount(dailyCount)
        }
        self.contentScope = contentScope
        self.timeScope = timeScope
        self.dailyCount = dailyCount
    }

    /// 含标签 / 排除标签的标签为空字符串时，规则不可提交（REQ-005 §9.2）。
    public var isSubmittable: Bool {
        switch contentScope {
        case .all, .untagged:
            return true
        case .includingTag(let tag), .excludingTag(let tag):
            return !tag.isEmpty
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            contentScope: container.decode(
                ContentScope.self,
                forKey: .contentScope
            ),
            timeScope: container.decode(TimeScope.self, forKey: .timeScope),
            dailyCount: container.decode(Int.self, forKey: .dailyCount)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case contentScope
        case timeScope
        case dailyCount
    }
}

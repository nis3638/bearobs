import Foundation

/// 回顾抽取的候选（REQ-005 §9.4 第 3 步的输入投影）。
public struct ReviewCandidate: Hashable, Sendable {
    public let path: String
    public let modifiedAt: Date
    /// 完整标签身份（如 `project`、`project/mobile`），用于精确匹配。
    public let tags: Set<String>
    public let isReadable: Bool

    public init(path: String, modifiedAt: Date, tags: Set<String>, isReadable: Bool) {
        self.path = path
        self.modifiedAt = modifiedAt
        self.tags = tags
        self.isReadable = isReadable
    }
}

/// 每日回顾抽取（REQ-005 §9.4）：纯逻辑，不依赖索引、SwiftUI 或持久化。
public enum ReviewDrawing {
    /// 先按规则过滤，再稳定洗牌，取前 `dailyCount` 条路径。
    ///
    /// 过滤顺序固定：排除不可读，再按时间下限，再按内容范围；内容范围使用
    /// 完整标签身份的精确匹配（`project` 不包含仅标记 `project/mobile` 的笔记）。
    /// 稳定洗牌：同一种子与同一输入得到同一顺序，随机源由种子决定。
    ///
    /// - Parameters:
    ///   - now: 时间下限的基准时刻；生产调用方使用默认当前时刻。
    ///   - calendar: 计算时间下限使用的日历，应为用户当前日历。
    public static func draw(
        candidates: [ReviewCandidate],
        rule: ReviewRule,
        seed: UInt64,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String] {
        let filtered = candidates.filter { candidate in
            passesRule(candidate, rule: rule, now: now, calendar: calendar)
        }
        var shuffled = filtered
        var generator = SplitMix64(seed: seed)
        if shuffled.count > 1 {
            for index in stride(from: shuffled.count - 1, to: 0, by: -1) {
                let swapIndex = Int(generator.next(upperBound: UInt64(index + 1)))
                shuffled.swapAt(index, swapIndex)
            }
        }
        return shuffled.prefix(rule.dailyCount).map(\.path)
    }

    private static func passesRule(
        _ candidate: ReviewCandidate,
        rule: ReviewRule,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard candidate.isReadable else { return false }
        if let cutoff = rule.timeScope.cutoff(from: now, calendar: calendar),
            candidate.modifiedAt < cutoff
        {
            return false
        }
        return passesContentScope(candidate.tags, rule.contentScope)
    }

    private static func passesContentScope(
        _ tags: Set<String>,
        _ scope: ReviewRule.ContentScope
    ) -> Bool {
        switch scope {
        case .all:
            return true
        case .includingTag(let tag):
            return tags.contains(tag)
        case .excludingTag(let tag):
            return !tags.contains(tag)
        case .untagged:
            return tags.isEmpty
        }
    }
}

/// 稳定洗牌的随机源：SplitMix64，输出序列完全由种子决定，
/// 不使用 `SystemRandomNumberGenerator`（REQ-005 T1 实现要点）。
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

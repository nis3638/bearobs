import Foundation
import Observation

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsUserState
#endif

/// 每日回顾会话（REQ-005 §9.4、FR-002）：持有规则、当日批次与「未能保存」
/// 标记，把 `ReviewDrawing` 的抽取经 `ReviewStateStore` 落盘。
/// 纯逻辑类型：只依赖 Foundation、Observation 与回顾上下文，不依赖 SwiftUI。
@MainActor
@Observable
public final class ReviewSessionModel {
    public private(set) var rule: ReviewRule?
    public private(set) var batch: ReviewBatch?
    /// FR-002.7：本次批次未能写入沙箱时为 true，当次抽取结果仍然可用。
    public private(set) var persistenceFailed = false

    private let store: ReviewStateStore
    private let vaultID: UUID
    private let calendar: Calendar

    public init(store: ReviewStateStore, vaultID: UUID, calendar: Calendar = .current) {
        self.store = store
        self.vaultID = vaultID
        self.calendar = calendar
    }

    /// 打开回顾（REQ-005 §9.4）：批次为今天且规则未变则复用，否则按规则
    /// 抽取并落盘。读取状态失败时按空状态处理（状态可删除重建），并退回
    /// 内存中的规则继续；未设置规则时不抽卡（FR-002.1 进入规则设置）。
    public func open(today: Date, candidates: [ReviewCandidate]) async {
        let state: ReviewState
        do {
            state = try await store.load(vaultID: vaultID)
        } catch {
            // 损坏的状态文件在进入时删除重建（FR-005.2），内存中的规则立即
            // 写回，让本次会话就能恢复持久化；其余失败按空状态处理。
            if await discardUnreadableState(error), let currentRule = rule {
                _ = try? await store.save(vaultID: vaultID, rule: currentRule)
            }
            state = ReviewState(rule: rule, batch: nil)
        }
        guard let currentRule = state.rule else {
            self.rule = nil
            self.batch = nil
            return
        }
        self.rule = currentRule
        let day = ReviewBatch.localDay(from: today, calendar: calendar)
        if let storedBatch = state.batch,
            storedBatch.day == day,
            storedBatch.rule == currentRule
        {
            self.batch = storedBatch
            persistenceFailed = false
            return
        }
        let saved = await drawAndStore(
            currentRule,
            day: day,
            today: today,
            candidates: candidates
        )
        persistenceFailed = !saved
    }

    /// 确认新规则（FR-002.6）：当日批次作废，按新规则重抽并落盘。
    /// 规则或批次任一落盘失败都置 `persistenceFailed`，结果仍保留在内存。
    public func updateRule(
        _ newRule: ReviewRule,
        today: Date,
        candidates: [ReviewCandidate]
    ) async {
        var ruleSaved = true
        do {
            _ = try await store.save(vaultID: vaultID, rule: newRule)
        } catch {
            // 重新设置规则必须能恢复持久化（FR-005.2）：状态文件内容损坏时
            // 删除重建再写一次；其余失败保持 `ReviewStateStore` 的 fail-closed。
            if await discardUnreadableState(error) {
                do {
                    _ = try await store.save(vaultID: vaultID, rule: newRule)
                } catch {
                    ruleSaved = false
                }
            } else {
                ruleSaved = false
            }
        }
        rule = newRule
        let day = ReviewBatch.localDay(from: today, calendar: calendar)
        let batchSaved = await drawAndStore(
            newRule,
            day: day,
            today: today,
            candidates: candidates
        )
        persistenceFailed = !(ruleSaved && batchSaved)
    }

    /// FR-005.2：状态「可随时删除重建」。状态文件内容损坏（解码失败或超出
    /// 大小限制）时删除旧文件并返回 true，让下一次读写从空状态开始；符号
    /// 链接与目录级故障不自动删除，保持 store 的 fail-closed，返回 false。
    @discardableResult
    private func discardUnreadableState(_ error: Error) async -> Bool {
        switch error as? ReviewStateStoreError {
        case .invalidState, .stateFileTooLarge:
            do {
                try await store.delete(vaultID: vaultID)
                return true
            } catch {
                return false
            }
        default:
            return false
        }
    }

    /// 抽取、落盘并更新内存批次；返回批次是否成功保存。
    /// 落盘失败时批次仍保留（FR-002.7：当日仍展示抽到的结果）。
    @discardableResult
    private func drawAndStore(
        _ currentRule: ReviewRule,
        day: DateComponents,
        today: Date,
        candidates: [ReviewCandidate]
    ) async -> Bool {
        let paths = ReviewDrawing.draw(
            candidates: candidates,
            rule: currentRule,
            seed: Self.seed(vaultID: vaultID, day: day, rule: currentRule),
            now: today,
            calendar: calendar
        )
        let newBatch = ReviewBatch(
            vaultID: vaultID,
            day: day,
            rule: currentRule,
            orderedPaths: paths
        )
        var saved = true
        do {
            _ = try await store.save(vaultID: vaultID, batch: newBatch)
        } catch {
            saved = false
        }
        batch = newBatch
        return saved
    }

    /// 固定种子（REQ-005 §9.4 第 4 步）：`hash(vaultID, day, rule)`。
    /// 同一 Vault、同一本地日历日、同一规则得到同一种子，因此抽取可复现
    /// （AC-REQ-005-03）；不使用任何随机源。FNV-1a 64 位。
    private static func seed(
        vaultID: UUID,
        day: DateComponents,
        rule: ReviewRule
    ) -> UInt64 {
        let content: String
        switch rule.contentScope {
        case .all: content = "all"
        case .includingTag(let tag): content = "including:\(tag)"
        case .excludingTag(let tag): content = "excluding:\(tag)"
        case .untagged: content = "untagged"
        }
        let time: String
        switch rule.timeScope {
        case .all: time = "all"
        case .pastYear: time = "pastYear"
        case .pastSixMonths: time = "pastSixMonths"
        case .pastThreeMonths: time = "pastThreeMonths"
        case .pastMonth: time = "pastMonth"
        }
        let dayKey = "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
        let canonical = "\(vaultID.uuidString)|\(dayKey)|\(content)|\(time)|\(rule.dailyCount)"
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in canonical.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

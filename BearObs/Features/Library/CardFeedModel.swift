import Foundation

#if SWIFT_PACKAGE
    import BearObsDomain
    import BearObsIndex
#endif

/// 卡片投影使用的固定文案（REQ-005 §3 共享约定：文案集中在枚举里，测试比对枚举）。
public enum CardFeedCopy {
    /// FR-001.5：解析失败的笔记在摘要处显示的固定文案。
    public static let unreadableExcerpt = "这条笔记暂时无法读取"
}

/// 卡片的可读性，由 `IndexedNoteParseStatus` 推导（REQ-005 §9.1）。
public enum CardReadability: Equatable, Sendable {
    case readable
    case unreadable
}

/// 一张卡片等于一篇笔记的展示投影（REQ-005 §9.1）。
/// 值对象，不落库；只承载展示所需的字段，数据库读取留在调用方。
public struct Card: Equatable, Identifiable, Sendable {
    public var id: VaultPath { path }

    public let path: VaultPath
    public let title: String
    public let excerpt: String
    /// 完整标签身份，按输入顺序最多保留 3 个。
    public let visibleTags: [String]
    /// 未展示的剩余标签数量，折叠为「+N」由视图负责。
    public let extraTagCount: Int
    public let modifiedAt: Date
    public let readability: CardReadability

    public init(
        path: VaultPath,
        title: String,
        excerpt: String,
        visibleTags: [String],
        extraTagCount: Int,
        modifiedAt: Date,
        readability: CardReadability
    ) {
        self.path = path
        self.title = title
        self.excerpt = excerpt
        self.visibleTags = visibleTags
        self.extraTagCount = extraTagCount
        self.modifiedAt = modifiedAt
        self.readability = readability
    }
}

/// 把索引结果投影成卡片流模型的纯函数集合。
/// 所有函数只消费传入的值，不做任何 I/O；索引与标签查询由调用方完成。
public enum CardFeedModel {
    /// 摘要最大长度，按扩展字形簇计数（REQ-005 §3 共享约定）。
    public static let maximumExcerptClusterCount = 140
    /// 卡片最多展示的标签数量（REQ-005 §3 共享约定）。
    public static let maximumVisibleTagCount = 3

    /// 把一篇索引摘要与该路径的标签列表投影成卡片。
    /// - Parameters:
    ///   - summary: 索引返回的笔记摘要，顺序由调用方保证（卡片流按修改时间倒序）。
    ///   - tags: 该路径的完整标签身份，按展示顺序传入；输入顺序即展示顺序。
    public static func card(
        from summary: IndexedNoteSummary,
        tags: [String]
    ) -> Card {
        let readability: CardReadability =
            summary.parseStatus == .failed ? .unreadable : .readable
        let visibleTags = tags.prefix(maximumVisibleTagCount)
        return Card(
            path: summary.path,
            title: title(of: summary),
            excerpt: excerpt(of: summary, readability: readability),
            visibleTags: Array(visibleTags),
            extraTagCount: tags.count - visibleTags.count,
            modifiedAt: summary.modifiedAt,
            readability: readability
        )
    }

    /// 标签过滤的纯函数版本：完整标签身份精确匹配（REQ-005 FR-003.2），
    /// `project` 不包含仅标记 `project/mobile` 的笔记。
    /// 使用调用方提供的完整标签身份表匹配，因此第 4 个及之后的标签（不在
    /// `visibleTags` 里）同样参与匹配；路径不在表中时退回卡片自带的可见标签。
    public static func filtering(
        _ cards: [Card],
        byTag tag: String,
        tagsByPath: [VaultPath: [String]]
    ) -> [Card] {
        cards.filter { card in
            (tagsByPath[card.path] ?? card.visibleTags).contains(tag)
        }
    }

    /// 搜索过滤的纯函数版本：搜索本身由调用方执行（复用现有离线全文搜索），
    /// 这里只按调用方传入的匹配路径集合筛选卡片，保持原有顺序。
    public static func filtering(
        _ cards: [Card],
        bySearch matchingPaths: Set<VaultPath>
    ) -> [Card] {
        cards.filter { matchingPaths.contains($0.path) }
    }

    /// 标题为空时用路径的文件名（去掉扩展名）。
    private static func title(of summary: IndexedNoteSummary) -> String {
        summary.title.isEmpty ? summary.path.fileNameWithoutExtension : summary.title
    }

    /// 摘要按 140 个扩展字形簇截断，超出加省略号；解析失败的笔记替换为固定文案。
    private static func excerpt(
        of summary: IndexedNoteSummary,
        readability: CardReadability
    ) -> String {
        guard readability == .readable else {
            return CardFeedCopy.unreadableExcerpt
        }
        let preview = summary.preview
        guard preview.count > maximumExcerptClusterCount else { return preview }
        // String 的 count 与 prefix 都按扩展字形簇计数，多码点字符不会被从中间截断。
        return preview.prefix(maximumExcerptClusterCount) + "…"
    }
}

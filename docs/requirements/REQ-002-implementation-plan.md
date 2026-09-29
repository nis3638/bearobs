---
title: REQ-002 Bear 式笔记原位编辑实现计划
date: 2026-09-07
status: planned
requirement_id: REQ-002
tags:
  - implementation-plan
  - macos
  - editor
  - markdown
---

# REQ-002 Bear 式笔记原位编辑实现计划

## 1. 核心判断

值得做，但不能继续在现有整篇 `TextEditor` 上堆条件判断。当前实现已经完成本地原始 Markdown
编辑、脏状态、expected-hash CAS、原子替换、保存竞态保护和单笔记索引刷新；剩余问题集中在
编辑表面、源码坐标映射、阅读/编辑位置连续性和真实 macOS UI 验收。

本计划采用一个简单的不变量：

> [!important] 单一文本事实源
> 编辑控件始终直接持有当前 Markdown 草稿；标题样式、列表样式、任务状态、未知语法样式和
> 可访问性信息都只是从草稿派生的投影。投影可以丢弃和重建，不能成为第二份可保存文档。

具体方案是在当前详情栏内使用一个 AppKit `NSTextView` 文本系统承载全文编辑，通过临时属性和
布局绘制形成接近阅读态的视觉效果。不要把每个 Markdown 块拆成独立 `TextEditor`：那会人为制造
跨块输入、选择、撤销、输入法、焦点和滚动同步等特殊情况。

## 2. 当前基线

### 2.1 已完成并必须复用

- `ReaderView` 已在同一详情栏切换阅读态和编辑态，没有 `sheet` 或第二窗口；
- `EditorFeatureModel` 已具备加载、草稿、脏状态、保存中输入保护和固定错误语义；
- `LocalEditorLoader` 已具备 expected-hash 校验、macOS 文件协调、原子替换和保存后索引刷新；
- `MarkdownSourceMapParser` 已产生基于原始 UTF-8 字节的半开区间；
- `MarkdownSourcePatchBuilder` 和 `MarkdownSourcePatchApplier` 已验证最小补丁、重叠区间和 UTF-8
  边界；
- 现有测试已覆盖无修改保存、普通段落最小改写、任务标记最小改写、BOM、CRLF、保存失败和
  保存期间继续输入。

### 2.2 当前缺口

- 编辑态仍显示整篇原始 Markdown `TextEditor`，没有按阅读结构排版；
- `MarkdownEditNodeKind` 只有 heading、paragraph、taskItem 和 opaque，普通列表、引用、代码块等
  还不能提供稳定的编辑投影；
- AppKit 使用 UTF-16 `NSRange`，现有写路径使用 UTF-8 字节区间，两套坐标还没有经过统一映射；
- 阅读态没有暴露稳定的源码锚点，进入编辑态无法恢复可见位置；
- 编辑态重新解析时没有选择、插入点和可见区域恢复契约；
- 未知语法虽能保留字节，但 UI 还没有明确表示它是局部源码区域；
- 当前两条启动 UI 测试依赖用户持久化状态，完整 `make test` 不是稳定绿线；
- ADR-005 仍写着“不做 Live Preview”，与 REQ-002/REQ-003 的新决策存在冲突。

## 3. 本轮范围

### 3.1 REQ-002 必须交付

1. 阅读态和编辑态继续使用同一详情栏、同一笔记身份和同一保存状态机；
2. 用一个无边框的原位编辑表面替换当前整篇原始 Markdown `TextEditor`；
3. 标题、普通段落、无序列表、有序列表、任务项、引用和代码块按接近阅读态的层级直接编辑；
4. 未知或不能证明安全的语法显示为同一文档内的局部源码区域；
5. 阅读转编辑时保持当前可见块附近，并把插入点放在该可见区域内的首个安全位置；
6. 保存、失败、并发输入、切换笔记和离开保护继续复用现有语义；
7. 键盘、VoiceOver、浅色和深色模式通过自动化或明确的人工验收。

### 3.2 本轮不冒充完成 REQ-003

以下内容不阻塞 REQ-002 收口，但仍属于 REQ-003：

- 所有内联 Markdown 标记的完整隐藏和按焦点无缝显隐；
- Wiki Link、Embed、Callout、数学公式、脚注和插件语法的专用可视编辑器；
- 任意复杂嵌套结构的结构化编辑；
- Bear 的动画、品牌、私有排版或像素级复制。

REQ-002 首版允许安全语法标记在当前块获得焦点时显示，并允许未知语法保持可读原文。不得为了
视觉统一而删除、转换或重新序列化原文。

## 4. 目标数据结构

### 4.1 数据所有权

```text
LocalVaultStore 原始字节
        ↓ load + expected hash
MarkdownSourceSnapshot（基线字节、hash、sourceInfo、sourceMap）
        ↓ 解码，不改写
EditorDraftSnapshot（当前 String、revision、selection、viewport）
        ↓ 后台解析，可丢弃
MarkdownEditorProjection（节点、样式、可访问性、坐标映射）
        ↓ 临时属性和布局绘制
NSTextView
        ↓ 用户输入
新的 EditorDraftSnapshot
        ↓ 现有 EditorDataSource.save
最小补丁 → expected-hash CAS → 原子替换 → 索引刷新
```

只有 `EditorDraftSnapshot.text` 可以代表待保存内容。`MarkdownEditorProjection` 不能提供保存接口。

### 4.2 新增值类型

建议放在 `BearObs/Markdown/Editor/`：

```swift
public struct MarkdownEditorProjection: Equatable, Sendable {
    public let revision: UInt64
    public let nodes: [MarkdownEditorNode]
    public let coordinateMap: MarkdownTextCoordinateMap
}

public struct MarkdownEditorNode: Equatable, Sendable, Identifiable {
    public let id: MarkdownEditorNodeID
    public let kind: MarkdownEditorNodeKind
    public let sourceRange: Range<Int>       // UTF-8，相对于当前投影文本
    public let editableRanges: [Range<Int>]  // UTF-8
}

public struct MarkdownEditorNodeID: Hashable, Sendable {
    public let lowerBound: Int
    public let upperBound: Int
    public let kind: MarkdownEditorNodeKind
}

public enum MarkdownEditorNodeKind: Hashable, Sendable {
    case heading(level: Int)
    case paragraph
    case unorderedListItem
    case orderedListItem(ordinal: Int)
    case taskItem(isChecked: Bool)
    case blockQuote
    case codeBlock(language: String?)
    case opaque
}

public struct MarkdownTextCoordinateMap: Equatable, Sendable {
    public func utf16Range(forUTF8 range: Range<Int>) -> Range<Int>?
    public func utf8Offset(forUTF16 location: Int) -> Int?
}
```

约束：

- `MarkdownEditorNodeID` 只在当前 revision 内稳定；保存或重新解析后不得拿旧 ID 写新文档；
- 所有写入边界继续使用 UTF-8；`NSRange` 只能停留在 AppKit 适配层；
- 坐标映射一次线性扫描构建，禁止对每个节点从字符串头部重复扫描；
- 任何越界、重叠、非 UTF-8 标量边界或无法核对原文的节点都降级为 `.opaque`；
- 投影构建失败时保留草稿并进入整篇安全源码兜底，不能清空编辑器或覆盖文件。

### 4.3 编辑会话快照

建议放在 `BearObs/Features/Library/EditorFeatureModel.swift`：

```swift
struct EditorDraftSnapshot: Equatable, Sendable {
    let text: String
    let revision: UInt64
    let selection: EditorSelection
    let viewport: EditorViewport
}

struct EditorSelection: Equatable, Sendable {
    let anchorUTF8: Int
    let headUTF8: Int
}

struct EditorViewport: Equatable, Sendable {
    let utf8Anchor: Int
    let verticalOffset: Double
}
```

模型内部可以改变当前快照引用，但每次修改必须创建新值，不能让后台解析任务持有可变集合。
`NSRange` 只存在于 AppKit adapter；进入模型前必须转换为 UTF-8 selection。

## 5. 编辑表面方案

### 5.1 为什么选择单一 `NSTextView`

- 原生支持跨块选择、撤销栈、拼写检查、输入法组合文本和键盘导航；
- 选择和可见字符范围都来自同一个文本系统，不需要同步多个编辑器；
- 文本存储可以始终保留原始 Markdown，样式使用临时属性，不污染待保存字符串；
- 可以精确控制字符范围、滚动位置、辅助功能和任务标记点击行为；
- macOS 15 已是项目最低版本，没有兼容旧系统的必要分支。

### 5.2 组件边界

新增以下文件，避免继续膨胀 `ReaderView.swift`：

```text
BearObs/Features/Library/EditorFeatureModel.swift
BearObs/Features/Library/InlineMarkdownEditorView.swift
BearObs/Features/Library/SourcePreservingTextView.swift
BearObs/Features/Library/ReaderViewportTracker.swift
BearObs/Markdown/Editor/MarkdownEditorProjection.swift
BearObs/Markdown/Editor/MarkdownEditorProjectionBuilder.swift
BearObs/Markdown/Editor/MarkdownTextCoordinateMap.swift
```

`SourcePreservingTextView` 是 `NSViewRepresentable`，内部 coordinator 负责：

- 将模型的新 revision 发布到 `NSTextStorage`；
- 把用户输入、选择和可见范围回传给模型；
- 对投影范围应用字体、段落、颜色、链接和代码样式；
- 防止 SwiftUI 更新回写时重置 selection 或 undo stack；
- 处理 Command-S、Escape 和任务标记点击；
- 暴露固定 accessibility identifier。

对应测试文件按职责拆分：

```text
BearObsTests/Markdown/Editor/MarkdownTextCoordinateMapTests.swift
BearObsTests/Markdown/Editor/MarkdownEditorProjectionBuilderTests.swift
BearObsTests/Features/Library/EditorFeatureModelTests.swift
BearObsTests/Features/Library/SourcePreservingTextViewTests.swift
BearObsUITests/REQ002InlineEditingUITests.swift
```

禁止在 `updateNSView` 中无条件执行 `textView.string = model.draft`。只有外部 revision 确实变化且
不是当前 coordinator 刚发出的编辑时才同步文本；同步前后必须保存并恢复选择和可见区域。

### 5.3 首版视觉规则

| 节点 | 首版表现 | 写入规则 |
|---|---|---|
| Heading | H1-H6 对应阅读态字号和字重；焦点块显示 `#` | 只修改当前文本；源码标记不自动规范化 |
| Paragraph | 正文字体、行距和段间距与 Reader 共用 token | 保存当前原始文本 |
| List item | 保留缩进，marker 降低干扰；正文按列表度量排版 | marker 和正文均保持原写法 |
| Task item | marker 绘制为可点击 checkbox，并提供切换 accessibility action | 点击只替换 `[ ]`/`[x]` 三字节范围 |
| Block quote | 使用段落缩进和左侧视觉引导 | `>` 仍在文本存储中 |
| Code block | 等宽字体和弱背景 | fence、语言和正文均保持原样 |
| Opaque | 等宽字体、轻量背景，并标注“局部源码区域” | 仅用户直接输入的该范围可变化 |

颜色不是唯一状态信号。焦点块还要有插入光标或形状/字重变化；错误状态同时显示图标、标题和文案。

### 5.4 样式与内容必须分离

- 使用 `NSTextStorage` 临时 attributes 或 TextKit 布局属性；
- 任务 checkbox 可通过自定义 layout fragment / drawing overlay 绘制，不能把 marker 替换成附件后再从
  富文本反向生成 Markdown；
- 链接预览只能使用既有白名单结果，不能因为编辑器样式产生新的系统动作；
- 首版不需要真正删除隐藏标记的 glyph；不能稳定处理光标和 VoiceOver 时，宁可降低颜色和字号，也
  不允许 `fontSize = 0`、透明字符或不可访问的附件技巧。

## 6. 阅读态与编辑态连续性

### 6.1 阅读侧源码锚点

给 `MarkdownRenderDocument` 增加顶层块描述：

```swift
public struct MarkdownRenderBlockEntry: Equatable, Sendable, Identifiable {
    public let id: Int                  // 当前文档内 sourceRange.lowerBound
    public let sourceRange: Range<Int>  // 原始 UTF-8 字节区间
    public let block: MarkdownRenderBlock
}
```

Reader 使用 entry 而不是数组下标作为滚动锚点。渲染器必须从 swift-markdown `SourceRange` 映射到
原始字节；映射失败的块使用最近安全父块区间，不能猜一个写入范围。

`ReaderViewportTracker` 通过命名坐标空间和 preference 收集可见顶层块，持续记录：

- 最靠近详情栏顶部的块源码起点；
- 该块相对可见区域顶部的垂直偏移；
- 当前笔记路径。

### 6.2 进入编辑态

1. 点击“编辑”时先冻结 `ReaderViewportSnapshot`；
2. 创建绑定当前 `VaultPath` 的 editor session；
3. 原文加载并构建 projection；
4. 在 `NSTextView` 中找到等于或紧邻 reader source anchor 的字符范围；
5. 恢复可见位置，并把插入点放到当前可见区域内第一个 editable range；
6. 如果没有安全 editable range，聚焦 opaque 局部源码区域；全文不得跳到开头。

阅读态目前不能可靠提供文本选择，因此首版不伪造“精确选择恢复”。REQ-002 允许在无法可靠映射时
聚焦当前可见区域。后续若 Reader 暴露真实 selection，再扩展 snapshot，不能预先猜测。

### 6.3 编辑期间重新解析

- 每次输入立即更新草稿和 revision；
- projection 构建在非主线程执行，使用 120～200 ms debounce；
- 结果携带 `path + revision`，只发布仍匹配当前会话的结果；
- 应用新样式前保存 UTF-16 selection 和 visible range；应用后恢复并裁剪到合法边界；
- 输入法存在 marked text 时不触发会改变文本存储的同步；
- 解析失败只撤掉结构化样式并显示源码兜底，不改变草稿。

### 6.4 保存和切换

- Command-S 继续调用现有 `EditorFeatureModel.save()`；
- 保存快照只包含触发保存时的 text；保存期间的新输入产生更高 revision；
- 较早保存完成后只更新 baseline，不覆盖更高 revision 的草稿、selection 和 viewport；
- 保存返回的新 `sourceSnapshot` 必须触发新 projection；旧 projection 结果按 revision 丢弃；
- 切换笔记、关闭窗口和 Escape 继续经过统一 dirty guard；确认放弃后销毁整个 session；
- 所有异步回调必须同时验证 session ID 和 `VaultPath`，不能只比较布尔状态。

## 7. 分阶段实施计划

每个阶段遵守 RED → GREEN → REFACTOR。一个阶段未达到退出条件，不进入下一阶段。

### P0：建立可信基线和决策边界

改动：

1. 新增 `ADR-009-source-preserving-live-preview.md`，替代 ADR-005 中“不做 Live Preview”这一条；
   保留“原始 Markdown 是事实源”和“禁止 AST 全文回写”；
2. 让 UI 测试使用临时 Vault/临时用户状态或明确 reset launch argument，不读取开发者机器上一次
   选择的 Vault；
3. 记录当前 `make check`、`make test`、Debug/Release build 和 coverage 基线。

退出条件：

- 干净环境连续两次 `make test` 全绿；
- 新 ADR 与 REQ-002、REQ-003、ADR-005 的关系无冲突；
- 不通过删除或跳过现有测试制造绿线。

#### P0 执行记录（2026-09-28）

1. `ADR-009-source-preserving-live-preview.md` 已建立；ADR-005 的“不做 Live Preview”条款已标注由
   ADR-009 替代，原始 Markdown 事实源与禁止 AST 全文回写两条不变量保留；`docs/adr/README.md`
   索引和 `03-development-design.md` 排除清单已同步，无残留冲突。
2. UI 测试状态隔离：`AppDirectories.makeLive` 支持 `BEAROBS_APP_SUPPORT_ROOT` 环境变量；
   每条 UI 测试创建独立临时根目录并在结束时删除，不读取也不写入开发者机器上一次选择的
   Vault。配套新增 `AppDirectoriesTests` 覆盖 override 和空值回退。
3. 启动 UI 测试此前失败的两个真实原因已修复：从 GUI 应用派生的 shell 会继承
   `__CFBundleIdentifier`，导致 xcodebuild 链路启动的 App 不创建任何窗口（`scripts/ci/common.sh`
   的 `xcodebuild_base` 现在显式清除该变量）；`VaultSelectionPrompt` 的 `open-vault-empty-state`
   AX identifier 被 `ContentUnavailableView` 外层标识覆盖（已移到外层）。未删除或跳过任何测试。
4. 基线（本机，2026-09-28）：`make check` 通过（swift-format lint --strict、Golden Vault 13 例、
   WebDAV 契约 9 场景）；`make test` 连续 4 次全绿（290 单元测试 + 2 条启动 UI 测试，
   0 失败）；`make build` Debug/Release 通过；`make coverage` 通过，BearObs.app 行覆盖
   83.53%（8803/10539）。

### P1：完成纯数据投影和坐标映射

先写测试：

- UTF-8 ↔ UTF-16 往返覆盖中文、emoji、组合字符、BOM、LF、CRLF；
- heading、paragraph、普通列表、任务列表、引用、代码块产生完整且不重叠的节点；
- Wiki Link、Embed、Callout、HTML、数学和未知插件块安全降级为 opaque；
- 每个 published range 都能逐字节核对当前输入；
- 1 MiB 文档构建时间和内存有上限，不出现按节点重复全量扫描。

然后实现：

- `MarkdownTextCoordinateMap`；
- `MarkdownEditorProjectionBuilder`；
- 扩充节点 kind，但继续让无法证明边界的结构降级；
- 将 Reader 和 Editor 共用的字体、间距抽成只含值的 presentation token。

退出条件：

- 投影模块不依赖 SwiftUI/AppKit；
- 对任意有效 UTF-8 输入，成功返回安全投影或显式失败，不崩溃；
- 投影没有保存接口，也不修改输入 Data。

#### P1 执行记录（2026-09-29）

1. 投影模块：新增 `BearObs/Markdown/Source/MarkdownEditorProjectionBuilder.swift`，仅依赖
   Foundation。`MarkdownEditorStyleToken`（heading(level:)、listItem、quote、codeBlock、
   opaque、taskMarker）与 `MarkdownEditorStyleRun`/`MarkdownEditorProjection` 只承载值；
   字体、颜色、段落样式留在 `SourcePreservingTextView` 的 AppKit 侧映射。快照未编辑时复用
   快照 range 并平移 BOM，编辑开始后重解析草稿一次；解析失败显式返回 nil，不崩溃；投影
   没有保存接口，也不修改输入 Data。
2. 节点 kind 扩充：`MarkdownEditNodeKind` 新增 `listItem`、`quote`、`codeBlock`，
   `heading` 携带 level（1…6）。parser 仅在边界可证时发射新 kind：marker 后内容必须是
   安全纯文本、不得自身为嵌套列表/主题分隔线、下一行不得是 Setext 下划线；空内容（`>`
   、`- `）产生无可编辑 span 的节点；裸围栏（无 info string）→ `codeBlock`，带 info
   string 的围栏（Dataview 等插件块）继续降级 opaque。Task marker 仍只发布 3 字节
   marker span。
3. `SourcePreservingTextView` 删除内嵌的 NSString 行扫描与重复的 overlay 推导，改为消费
   投影 run，全部 range 经 `MarkdownTextCoordinateMap` 做 UTF-8→UTF-16 映射；
   `MarkdownDraftSyntaxResolver` 改为投影 builder 的薄封装，公共 API 与测试语义保持。
4. 性能：`isSafePlainText` 的 22 个 Unicode 子串扫描改为等价的字节级扫描（全部
   forbidden token 均为 ASCII），`contains(_:ascii:)` 去掉逐位置 ArraySlice。1 MiB 文档
   投影构建 p95 ≈ 342 ms（Debug，本机），预算上限 1 s，无按节点重复全量扫描。
5. 测试：新增 `MarkdownEditorProjectionBuilderTests` 8 例（全部结构化 kind 的 token 序列、
   逐字节核对 run range、run 不劈裂 UTF-8/UTF-16 标量、BOM 快照路径与草稿路径投影相等、
   编辑后重解析、快照不被修改、1 MiB 预算）；坐标映射补 UTF-8↔UTF-16 全标量边界往返
   （BOM/中文/emoji/组合字符/LF/CRLF）；parser 新增 list/quote/codeBlock/heading level
   及降级用例；resolver 用例随“裸围栏→codeBlock”语义更新，围栏与 opaque 区域内的
   task marker 仍不上报。
6. 门禁：SwiftPM 全量 276 测试通过；xcodebuild 测试计划 308 测试（含 2 条 UI 冒烟）通过；
   `make build` Debug/Release 通过；`swift-format lint --strict` 通过。presentation
   token（Reader 与 Editor 共用字体/间距）尚未抽取，随 P3 界面统一时处理。

### P2：拆分并强化编辑状态机

先把 `EditorFeatureModel` 从 `ReaderFeatureModel.swift` 移到独立文件，再增加：

- draft revision；
- projection loading/ready/fallback 状态；
- session ID；
- selection/viewport 快照；
- debounce parse task 和 stale-result guard。

先写测试覆盖：

- 旧 projection 不能覆盖新输入；
- 旧笔记 projection/save 不能污染新笔记；
- 保存期间新输入仍为 dirty；
- 保存失败保留 draft、selection、viewport；
- 重新解析失败进入 fallback，草稿不变；
- marked text 期间模型不会强制回写旧字符串。

退出条件：现有 `EditorFeatureModelTests` 全部不降级，新状态测试全绿，保存 API 和错误文案保持兼容。

#### P2 执行记录（2026-09-29）

1. 会话身份：`EditorFeatureModel` 新增只读 `sessionID`（UUID，init 创建）。App 侧每次进入
   编辑态新建模型实例、切换/放弃时销毁，模型实例即会话，会话生而绑定 `path`、不重绑
   （对应 6.2/6.4）。`EditorProjectionEngine.scheduleParse` 改为携带 session，发布前同时
   校验 session 与 revision；会话切换取消未决解析、清空旧投影并重置 revision 空间——旧
   会话的解析结果无法发布进新会话，旧投影不会残留在新笔记下。
2. 快照值类型：按 4.3 新增 `EditorSelection`（anchor/head，UTF-8）、`EditorViewport`
   （utf8Anchor + verticalOffset）、`EditorDraftSnapshot`（text/revision/selection/
   viewport）。模型分别存储 `selection`/`viewport`，`draftSnapshot` 每次读取现组新值，
   任何修改都产生新值，后台任务不持有可变集合；`NSRange`→UTF-8 转换仍留在 AppKit 适配层
   （P3），模型只做字节范围钳制。与计划的差异：revision 用 `Int` 与现有 `draftRevision`
   对齐，未改用 `UInt64`。
3. 视图状态语义：`updateSelection`/`updateViewport` 更新视图快照；`publish`（载入）重置
   selection/viewport；`adoptSavedDocument`（保存完成）不触碰 selection/viewport。
4. 保存完成语义（6.4）：只更新 baseline；仅当草稿字节仍等于保存前文本时才采纳归一化的
   `document.text`（并加等值检查避免空写），保存期间新输入产生的高 revision 草稿、
   selection、viewport 不被覆盖；保存返回的新 `sourceSnapshot` 触发以当前草稿为准的重投影
   （revision +1），旧快照上的未决解析被取代。保存失败路径不改 draft 与快照。
5. marked text 守卫（6.3）：新增 `isMarkedTextActive` 与 `setMarkedTextActive(_:)`；激活
   期间保存完成不回写 draft（含等值写），组合输入期间模型绝不把旧字符串推回视图。
6. 测试：`EditorFeatureModelTests` 6 → 12。新增：保存期间新输入保持 dirty 且完成后不被
   覆盖；保存失败保留 draft/selection/viewport（快照级断言）；marked text 期间经
   `withObservationTracking` 证明 draft 无写入事件；保存完成采纳规范化文本且 selection/
   viewport 保留、新快照触发重投影（记录器断言解析文本与快照）；引擎会话切换丢弃旧会话
   结果并清空旧投影；共享数据源上两个会话互不污染（覆盖"旧笔记 projection/save 不能污染
   新笔记"）。`makeModel` 支持注入 save 闭包；另清理 `ParseGate` 同步访问处残留的无效
   `await`（在 xcodebuild 编译设置下按错误处理）。
7. 门禁：SwiftPM 全量 288 测试通过；xcodebuild 测试计划 320 测试（含 2 条 UI 冒烟）通过；
   `make build` Debug/Release 通过；`make check`（swift-format lint --strict、Golden/
   WebDAV 固定装置、密钥扫描）通过。`EditorDataSource` load/save 语义与错误分类未变，
   保存 API 和错误文案保持兼容。

### P3：接入单一 AppKit 编辑表面

实现 `SourcePreservingTextView` 和 coordinator，先只完成：

- 原始草稿编辑；
- selection、visible range 和 undo 保持；
- heading、paragraph、list、quote、code、opaque 样式；
- Command-S、Escape；
- 不带边框和独立卡片的详情栏布局。

把当前 `InlineMarkdownEditor` 中的 SwiftUI `TextEditor` 替换掉，但保留加载、错误、保存状态 UI。

退出条件：

- 中文输入法组合文本不丢字、不重复；
- 全文跨块选择、复制、粘贴、撤销和重做正常；
- SwiftUI state 更新不会重置光标到开头；
- 不产生第二个保存路径。

### P4：任务项和局部源码交互

实现：

- task marker 的自定义绘制、鼠标命中和 accessibility action；
- 点击只对当前 `[ ]`/`[x]` range 产生替换；
- opaque 节点获得焦点时明确进入“局部源码区域”，离开后恢复弱化样式；
- opaque 节点之外的输入不能意外覆盖其字节。

退出条件：

- 任务切换的 before/after 字节 diff 只有三个 marker 字节；
- 未触碰 opaque 节点时，其完整 bytes 保持一致；
- VoiceOver 能读出“未完成任务/已完成任务”和“局部源码区域”。

### P5：阅读/编辑位置连续性

实现 Reader block source entry、`ReaderViewportTracker` 和 editor restore：

- 长文中部进入编辑不回顶部；
- 编辑保存后仍在同一内容附近；
- 无可靠精确选择时聚焦当前可见区域；
- 切换笔记时清除旧 session 的位置状态。

退出条件：对至少 200 屏高度的 fixture，在上部、中部、尾部三处切换，目标块仍可见且插入点在
可见区域；不得使用固定像素或延时 sleep 猜测位置。

### P6：键盘、VoiceOver 和失败路径

实现并验证：

- 编辑按钮有键盘入口；Command-S 保存；Escape 经过 dirty guard；
- VoiceOver 读出编辑态、节点类型、任务状态、源码区域、保存中和失败状态；
- 保存失败后焦点仍在编辑器，重试不丢草稿；
- 浅色/深色、最大辅助字号下可操作，焦点和错误不只依赖颜色。

退出条件：AC-REQ-002-04 和 AC-REQ-002-06 对应自动化测试全绿，人工 VoiceOver checklist 留有
日期、系统版本和结果。

### P7：收口与文档同步

1. 运行 `make check`、`make test`、`make coverage`、Debug/Release build；
2. 做一次针对输入、链接协议、HTML/插件内容和文件写入的安全审查；
3. 更新 `03-development-design.md` 和 `04-development-plan.md`；
4. 将 REQ-002 的五项收口待办逐项链接到测试或验收证据后再勾选；
5. 只有 AC-REQ-002-01 至 06 全部有证据，才把 REQ-002 状态改成 `completed`。

## 8. 测试与验收矩阵

| 验收项 | 自动化证据 | 人工证据 |
|---|---|---|
| AC-REQ-002-01 原详情栏编辑 | XCUITest 验证窗口数、sheet 数、selection path 和 editor identifier | 观察无模态、无第二编辑区 |
| AC-REQ-002-02 位置连续性 | 长文 fixture 在三个 source anchor 切换并断言目标可见、插入点可见 | 检查无明显跳动和闪烁 |
| AC-REQ-002-03 编辑与保存 | heading/paragraph/list/task 端到端保存并重新打开 | 检查排版与 Reader 接近 |
| AC-REQ-002-04 失败与并发 | controlled save、external edit、stale parse、switch note 测试 | 检查错误可理解且可重试 |
| AC-REQ-002-05 Markdown 保真 | BOM/CRLF/frontmatter/opaque golden byte diff | 用 Obsidian 重新打开抽样文件 |
| AC-REQ-002-06 键盘与可访问性 | shortcut、focus、dark mode、最大字号 XCUITest | VoiceOver 完整走查 |

新增 UI fixture 必须由测试创建临时目录，不能依赖开发者本机 Vault。测试结束删除自己的临时数据，
不得删除或修改用户 Vault。

## 9. 性能和安全门禁

### 9.1 性能预算

- 1 MiB 上限文档首次投影：Release P95 小于 150 ms；
- 普通单次输入到样式稳定：P95 小于 250 ms；
- 滚动期间不得同步执行全文解析；
- projection task 同一会话最多一个在运行、一个待 debounce，取消旧任务；
- 不为了方便缓存第二份持久化富文本或 HTML。

性能数字是初始工程预算；若本机基线证明不合理，必须记录测量后调整，不能直接删除门禁。

### 9.2 安全边界

- HTML、脚本、插件代码和自定义 URI 只作为文本或安全预览，不执行；
- 编辑器新链接行为继续复用 Reader 的协议白名单和内部路由校验；
- 粘贴内容只进入当前草稿，不能解释成命令或自动访问网络；
- 外部修改继续由 expected content hash 拒绝覆盖；
- 错误 UI 不显示绝对 Vault 路径、底层异常文本或文件内容；
- 所有测试只写临时 Vault。

## 10. 兼容性与禁止事项

### 10.1 必须保持

- `VaultPath`、索引身份、同步基线和 WebDAV 冲突模型不变；
- `EditorDataSource` 的 load/save 语义和现有错误分类兼容；
- Reader 的链接白名单、Wiki Link 路由和未知语法安全显示不退化；
- 原始 Markdown 编辑模式保留为投影失败时的安全兜底；
- 未编辑字节、BOM、换行和未知语法保真。

### 10.2 禁止实现

- 禁止每个 Markdown 块一个独立 `TextEditor`；
- 禁止保存 `NSAttributedString`、HTML 或 AST 序列化结果；
- 禁止用全文格式化器生成保存内容；
- 禁止用透明字符、零字号或不可访问附件假装隐藏语法；
- 禁止在 `updateNSView` 无条件覆盖文本和 selection；
- 禁止用 sleep 修复焦点或滚动竞态；
- 禁止因为 unknown syntax 解析失败而阻止整篇编辑；
- 禁止顺手实现远端上传、自动保存、新建、删除或重命名。

## 11. Terra 执行顺序

建议严格按以下提交粒度执行，便于审查和回退：

1. `docs: reconcile source-preserving live preview decision`
2. `test: isolate macOS UI test state`
3. `feat: add markdown editor projection and coordinate map`
4. `refactor: isolate editor feature model`
5. `feat: add source-preserving AppKit editor surface`
6. `feat: add task and opaque-node interactions`
7. `feat: preserve reader editor viewport and focus`
8. `test: cover REQ-002 macOS acceptance paths`
9. `docs: close REQ-002 implementation evidence`

每个提交都必须：

- 先增加失败测试，再做最小实现；
- 运行相关测试和 `make check`；
- 审查 `git diff`，不混入无关格式化；
- 不修改或丢弃工作区中不属于本阶段的现有改动；
- 发现数据模型无法保持不变量时停下来修正模型，不用 UI 条件分支掩盖。

## 12. 完成定义

REQ-002 只有同时满足以下条件才算完成：

- [ ] 单一详情栏内完成结构化原位编辑，没有 sheet、弹窗或第二编辑器；
- [ ] heading、paragraph、list、task、quote、code 和 opaque 节点有明确表现；
- [ ] UTF-8 与 UTF-16 坐标映射测试覆盖 Unicode、BOM 和换行；
- [ ] 阅读/编辑切换保持当前可见内容和可见插入点；
- [ ] 保存失败、外部修改、保存期间输入和切换笔记不丢草稿；
- [ ] 未编辑 Frontmatter、未知语法、空白和换行保持字节一致；
- [ ] Command-S、Escape、键盘进入编辑和 VoiceOver 验收通过；
- [ ] 浅色、深色和最大辅助字号验收通过；
- [ ] `make check`、`make test`、`make coverage`、Debug/Release build 全绿；
- [ ] REQ-002 每条 AC 都链接到测试或人工验收记录；
- [ ] 设计文档、开发计划和需求状态已同步。

## 13. 追踪关系

- 需求：[REQ-002 Bear 式笔记原位编辑](REQ-002-bear-style-inline-note-editing.md)
- 源码保真：[REQ-003 Bear 式所见即所得与 Obsidian 无损编辑](REQ-003-source-preserving-bear-style-editing.md)
- 原文写入决策：[ADR-005 Markdown 原文编辑而非 AST 全文回写](../adr/ADR-005-markdown-source-editing.md)
- 开发设计：[03-development-design.md](../03-development-design.md)
- 开发计划：[04-development-plan.md](../04-development-plan.md)

---
title: REQ-002 Bear 式笔记原位编辑实现计划
date: 2026-09-07
status: completed
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

#### P3 执行记录（2026-09-30）

1. 视图契约重构：`SourcePreservingTextView` 从 `Binding<String>` 改为单向回调
   （onDraftChange / onSelectionChange / onViewportChange / onMarkedTextChange / onSave /
   onEscape）；`InlineMarkdownEditor` 把模型方法直接接到回调上，Command-S 与 Escape 路由回
   ReaderView 的统一 `saveEditing()` / `finishEditing()`（脏草稿经既有放弃确认），没有
   第二个保存路径。AppKit 侧 `NSRange`→UTF-8 转换全部收敛在 coordinator（4.3）。
2. revision 门控同步（5.2）：`updateNSView` 不再按字符串比较回写；仅当模型 revision 变化
   且显示文本确有差异时同步，并通过 `shouldChangeText` + `textStorage.replaceCharacters` +
   `didChangeText` 完成——外部改写（保存归一化、重载）注册为可撤销编辑，不摧毁用户 undo
   历史；同步前后保存并恢复 UTF-8 选择与首个可见行锚点。锚点经 `MarkdownSourcePatchBuilder`
   最小补丁跨编辑平移（恰在插入边界上的锚点保持原位），prepend/append 类外部变更后用户
   停留在同一内容附近。
3. 输入法守卫（6.3）：`EditorTextView`（NSTextView 子类，显式 TextKit 1 栈）覆写
   `setMarkedText` / `unmarkText` 上报组合状态；组合期间同步入口直接返回，绝不触碰文本
   存储；组合期 Escape 交还输入法。测试证明组合窗口内收到外部 revision 不破坏组合文本，
   `unmarkText` 后经同一回调完整提交（不丢字、不重复）。实现注记：当前 macOS 的
   NSTextView/NSResponder 没有 `cancelOperation:` 默认实现（调用 super 会抛
   unrecognized selector），Escape 在子类覆写内完成、组合期静默返回。
4. 样式来源切换：视图不再在每次输入时于主线程同步构建投影，而是消费
   `EditorProjectionEngine` 的后台结果（带 `projection.text == 显示文本` 陈旧守卫，陈旧
   投影不清除既有样式）；仅首次绘制在引擎结果未就绪时用快照路径同步构建一次（复用基线
   range）。投影应用同样保存/恢复选择与滚动锚点。投影 debounce 默认 250 ms → 180 ms
   （回到 §6.3 的 120–200 ms 区间，否则输入到样式稳定会超出 §9.1 的 250 ms 预算）。
5. 详情栏布局（3.1-2）：`InlineMarkdownEditor` 移除外层 SwiftUI `ScrollView`（此前与
   NSScrollView 形成双层滚动）与独立卡片；编辑表面为无边界、无背景的单一滚动面，保存中/
   失败状态为底部固定状态条，加载/错误态与 accessibility identifier 保持不变。文本列经
   `textContainerInset` 与 Reader 内容列等宽居中：新增 `ReaderEditorLayoutToken`
   （760/20/24），Reader 侧字面量同步替换，完成 P1 遗留的共用 presentation token。
6. 测试：新增 `SourcePreservingTextViewTests` 11 例——边框/背景/identifier 契约；输入回传
   draft + revision + UTF-8 选择；undo 撤销输入且 model 同步；echo 更新不重写存储/选择/
   undo；外部归一化为可撤销编辑且 undo/redo 每一步 model 与视图一致（断言不依赖
   NSUndoManager 分组粒度，SwiftPM 与 xcodebuild host 下分组边界不同）；组合文本不被外部
   revision 破坏；Escape/Command-S 路由（组合期 Escape 让行、非匹配键不吞）；heading/code/
   quote 样式落在 UTF-8 映射 range 上且陈旧投影不清除样式；astral + CJK 选择的 UTF-8
   回传；跨块复制/粘贴更新草稿；外部变更保持首个可见行（prepend 后仍在原行，垂直偏移
   一致）。测试以 NSWindow 承载表面——无窗口的 NSTextView 没有 undo manager。
7. 门禁：SwiftPM 全量 299 测试通过；xcodebuild 测试计划 331 测试（含 2 条 UI 冒烟）通过；
   `make check`（swift-format lint --strict、Golden/WebDAV 固定装置、密钥扫描）通过；
   `make build` Debug/Release 通过。已知限制：引用块首版为缩进 + 次级颜色，暂无左侧视觉
   引导线（P4/P6 收口）；阅读→编辑精确位置连续性按计划属 P5；任务标记点击沿用 M3 的
   3 字节替换路径，其交互深化与 VoiceOver 属 P4。

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

#### P4 执行记录（2026-09-30）

1. 自定义绘制（5.3/5.4）：新增 `EditorSurfaceLayoutManager`（`NSLayoutManager` 子类，
   AppKit 侧），替换 task marker 的括号 glyph 绘制为 SF Symbols checkbox
   （`checkmark.square.fill`/`square`，accent 色）。文本存储始终保留原始 `[ ]`/`[x]`
   字节——绘制层用补集分段跳过 marker glyph，不使用零字号、透明字符或附件；编辑选择落在
   marker 所在行时 raw 字节原样显示（3.2 允许的“焦点显示语法”），光标与选择仍按字符系统工作。
   所有 marker/opaque 几何从 text storage 的临时呈现属性实时派生（`.link` toggle URL、
   新增 `bearobsOpaqueRegion` 呈现键），属性随编辑自动平移，不存在会失步的缓存几何。
2. 鼠标命中：`EditorTextView.mouseDown` 对普通单击先询问 coordinator，命中 checkbox 绘制
   矩形（±3pt）即 toggle 并消费事件；`clickedOnLink` 保留为焦点态与属性回退路径。两条路径
   汇入同一 `toggleTaskMarker`：先核对目标字节恰为 `[ ]`/`[x]`，再经 `shouldChangeText` +
   `replaceCharacters` + `didChangeText` 走文本系统主编辑管线——可撤销，并经既有
   `onDraftChange` 进入模型，无第二保存路径。
3. accessibility action：光标所在任务行暴露一个 `NSAccessibilityCustomAction`
   （未完成 → “标记为已完成”，已完成 → “标记为未完成”），handler 复用 `toggleTaskMarker`。
   进入任务行时朗读“未完成任务/已完成任务”，切换后朗读新状态；光标进入 presentable
   opaque 区域时朗读“局部源码区域”（离开再进入重复朗读）。朗读经注入式
   `accessibilityAnnouncer`（默认 `NSAccessibility` announcement），测试注入记录器断言。
   人工 VoiceOver 走查按计划留待 P6 出具 checklist。
4. opaque 焦点呈现：选择头部落在 presentable opaque 区域（解析器的空行兜底不算源码区域）
   时，绘制区域增强填充 + accent 边框 + “局部源码区域” caption（上方空间不足时不画
   caption）；离开后仅停止绘制即恢复 P3 的弱化样式，不触碰存储属性。焦点状态翻转时仅
   失效受影响的行/区域显示。
5. 字节保护：opaque 之外输入、任务 toggle 均为纯文本插入/3 字节替换；测试证明在 opaque
   区域前、后及文末插入后其子串字节不变，且 toggle 的 before/after 字节 diff 完全落在
   marker 3 字节内。parser 将空行兜底为 opaque 并与相邻块合并的行为未改动，由呈现层过滤。
6. 测试：新增 `EditorSurfaceInteractionTests` 12 例（计划 5.2 的测试文件清单之外独立成
   文件），覆盖几何发布、toggle 三字节 diff 与 opaque 字节保真、非 marker range 拒绝、
   checkbox 命中/未命中、link 点击与属性回退、AX action 名称与执行、朗读序列、
   glyph 显隐随焦点、PDF 离屏绘制冒烟、单步 undo。夹具显式区分 UTF-8 字节与 UTF-16
   坐标（经 `MarkdownTextCoordinateMap` 派生）。
7. 门禁：SwiftPM 全量 311 测试通过；xcodebuild 测试计划 343 测试（含 2 条 UI 冒烟）通过；
   `make check`（swift-format lint --strict、Golden/WebDAV 固定装置、密钥扫描）通过；
   `make build` Debug/Release 通过。已知限制：任务 marker 无键盘切换路径（P6）；checkbox
   命中仅覆盖绘制矩形 ±3pt；caption 在上邻行距不足 1 行高度时省略（边框与朗读仍标识源码
   区域）。

### P5：阅读/编辑位置连续性

实现 Reader block source entry、`ReaderViewportTracker` 和 editor restore：

- 长文中部进入编辑不回顶部；
- 编辑保存后仍在同一内容附近；
- 无可靠精确选择时聚焦当前可见区域；
- 切换笔记时清除旧 session 的位置状态。

退出条件：对至少 200 屏高度的 fixture，在上部、中部、尾部三处切换，目标块仍可见且插入点在
可见区域；不得使用固定像素或延时 sleep 猜测位置。

#### P5 执行记录（2026-09-30）

1. Reader block source entry（6.1）：`MarkdownRenderDocument` 的顶层块列表改为带出处的
   `entries`（`blocks` 变为派生属性；测试/预览用的 blocks 构造器合成空区间 entry，永不作为
   锚点）。`MarkdownRenderBlockEntry.id` 固定为 `sourceRange.lowerBound`，`sourceRange` 为原始
   文件 UTF-8 字节区间（含 BOM 与 frontmatter 偏移，与 Wiki Link occurrence 坐标同一空间）：
   swift-markdown `SourceRange` 经 `ReaderBodySource` 行列映射到正文字节再加 `bodyRange.lowerBound`。
   映射失败的节点继承最近可映射父块区间；完全无出处的块携带空区间，不猜测写入范围。嵌套块
   （引用/列表项内部）不产生 entry。渲染测试逐字节核对 entry 区间内容、顺序与不重叠，并覆盖
   BOM+frontmatter 坐标。
2. `ReaderViewportTracker`（6.1）：新文件 `BearObs/Features/Library/ReaderViewportTracker.swift`。
   每个顶层块经 `ReaderBlockAnchorView` 在命名坐标空间 `reader-scroll`（= ScrollView bounds，
   视口顶边恒为 y=0）上报 frame，由 preference 收集，对 LazyVStack 的稀疏/乱序实现集可容忍；
   纯函数 `topmostVisibleFrame` 选出"顶边所在块"（第一个未完全越过顶边的块），
   `snapshot(frames:entries:path:)` 冻结为 `ReaderViewportSnapshot(path, anchorSourceOffset,
   blockSourceRange, verticalOffset)`，其中 verticalOffset 为块顶相对视口顶的偏移（块跨越顶边
   时为负）。ReaderView 在滚动全程持续记录，点击"编辑"时冻结传入会话，path 不匹配的旧快照
   拒用。
3. 编辑态恢复（6.2）：`SourcePreservingTextView` 以 `initialViewport: ReaderViewportSnapshot?`
   取代像素偏移 `initialScrollOffset`。恢复流程：强制布局并把文本视图增长到全文高度（宿主首帧
   未完成布局时几何仍真实）→ 锚点文件字节经 BOM 平移映射为草稿 UTF-8 → UTF-16 → glyph → 行顶；
   verticalOffset 为负（块跨越顶边）时向块内深入滚动，但钳制不超过块在编辑器度量下的高度减一
   行（排版共享前提下保持目标块可见），其余情况 `target = anchorLineTop − verticalOffset`（顶部
   留白自然对齐）。插入点放在可见区域首个非 opaque 位置（跳过插件块等局部源码区域）；整个可见
   区域均为 opaque 时聚焦可见起点。全文不会跳回开头。
4. 编辑器 → 阅读器恢复（6.4/P5）：`EditorFeatureModel.readerRestoreSourceOffset` 把视口锚点从
   草稿坐标经基线最小补丁反向平移回基线字节（替换区域内部钳制到区域起点、插入区域前边界保持
   原位——与 `SourcePreservingTextView` 正向平移同一规则），再加 BOM 偏移；无基线快照时为 nil。
   `ReaderView.prepareReaderRestore`（保存完成与放弃修改两条退出路径共用）把该偏移解析为包含它
   的顶层块 index，经 `ScrollPosition(id:anchor:.top)` 配合 `scrollTargetLayout()` 在阅读面重新
   挂载时定位。`textDidChange` 现在从实时几何重报视口锚点：在可视首行上方输入或撤销后，模型的
   视口不再停留在旧坐标。
5. 会话隔离（P5）：切换笔记时重置 readerViewport、editorViewportRestore、pendingRestoreBlockIndex
   与 scrollPosition；冻结快照按 path 校验。
6. 测试：新增 `ReaderViewportTrackerTests` 10 例（顶边在块内/块间空隙/文档顶部、稀疏乱序、
   无出处 entry、范围外 index、真实 entry 的快照字段与反向包含解析）；`SourcePreservingTextViewTests`
   新增 7 例——400 节（约 250 屏窗口高度）fixture 在中部（块内深入 100pt）、尾部（滚动钳制）、
   顶部三处恢复，断言目标块可见、插入点可见且非顶部，BOM 平移用 1 字节首行段落做可区分断言，
   纯 opaque 可见区域聚焦局部源码，无锚点置顶，以及在可视首行上方经生产编辑管线插入后模型收到
   现坐标锚点（全程几何断言，无固定像素与延时 sleep；顺带修正 `glyphRange(forBoundingRect:)`
   需要容器坐标的 P3 遗留偏差）；`EditorFeatureModelTests` 新增 6 例（干净草稿直映、上方插入/
   删除前缀/替换内部/插入边界的反推、BOM、无快照为 nil）；`MarkdownReaderRendererTests` 新增
   3 例；`ReaderViewRenderingTests` 新增 1 例。
7. 门禁：SwiftPM 全量 338 测试通过；xcodebuild 测试计划 TEST SUCCEEDED（含 2 条 UI 冒烟）；
   `make check`（swift-format lint --strict、Golden/WebDAV 固定装置、密钥扫描）通过；
   `make build` Debug/Release 通过。已知限制：阅读面重新挂载的 `ScrollPosition` 定位由 SwiftUI
   框架应用，无像素级断言（选块与坐标决策已由纯函数测试覆盖）；阅读面重挂载后首帧偏好上报前的
   极短窗口内再次进入编辑会落到顶部。

### P6：键盘、VoiceOver 和失败路径

实现并验证：

- 编辑按钮有键盘入口；Command-S 保存；Escape 经过 dirty guard；
- VoiceOver 读出编辑态、节点类型、任务状态、源码区域、保存中和失败状态；
- 保存失败后焦点仍在编辑器，重试不丢草稿；
- 浅色/深色、最大辅助字号下可操作，焦点和错误不只依赖颜色。

退出条件：AC-REQ-002-04 和 AC-REQ-002-06 对应自动化测试全绿，人工 VoiceOver checklist 留有
日期、系统版本和结果。

#### P6 执行记录（2026-10-01）

1. 键盘入口（AC-06）：编辑动作的键盘入口为菜单命令"编辑笔记"（Command-E，
   `BearObsApp.ReaderEditCommands`）。`ReaderView` 经 `focusedSceneValue(\.readerEditCommand, …)`
   在阅读面显示期间发布当前笔记的编辑闭包，进入编辑态或无编辑数据源时命令自动禁用；
   工具栏编辑按钮保留并标注快捷键提示。与计划的差异：实测（macOS 27）工具栏按钮
   `.keyboardShortcut` 不响应合成键盘事件，且菜单命令是 macOS 键盘入口的标准位置，
   ⌘E 因此由菜单命令持有。进入编辑表面时 `promoteInitialFocusIfNeeded` 把焦点一次性
   落到文本视图（updateNSView 与初始恢复双入口、幂等），键盘用户进入编辑即可输入。
2. Command-S 与 Escape：沿用 P3 的既有路径（AppKit 表面 `performKeyEquivalent` /
   `cancelOperation` → 统一 `saveEditing()` / dirty guard），本轮新增 UI 测试按真实路径
   验证：Command-S 落盘且保存按钮转禁用；Escape 对脏草稿弹出确认，"继续编辑"保草稿、
   "放弃修改"不写盘并返回阅读。
3. 任务 marker 键盘切换（P4 遗留收口）：`EditorTextView.performKeyEquivalent` 新增
   Command-L → `toggleTaskMarkerUnderCaret`，光标所在任务行经 P4 既有
   `toggleTaskMarker` 三字节替换（可撤销、同一 draft 回调、无第二保存路径）；非任务行
   按键穿透。文本视图 accessibilityHelp 补充 Command-S / Escape / Command-L 说明。
4. VoiceOver（AC-06）：
   - 进入编辑朗读"已进入编辑模式"（初始恢复块内、每会话一次）；
   - 光标移动朗读节点类型：一～六级标题（中文数字）、"段落""列表项""引用""代码块"，
     以 `lastAnnouncedNodeKind` 去重；任务行与 presentable 源码区域沿用 P4 的状态朗读
     （"未完成任务/已完成任务"/"局部源码区域"）并重置去重；解析器空行兜底不朗读；
   - 保存状态：`SourcePreservingTextView` 新增 `saveStatus`（isSaving + failureText），
     coordinator 在 `syncIfExternalChange` 边沿检测并朗读"正在保存笔记"/"已保存"/失败
     标题+文案；首次观察与失败条"知道了"关闭静默。`EditorFailure.title` /
     `message(isDirty:)` 提取为共享扩展，失败视图与朗读共用同一文案，无第二份错误文案；
   - 失败视图重构：标题与文案独立可读，按钮不再被 `.combine` 吞并为单一元素
     （VoiceOver 可达），"重试保存"仅对 `.saveFailed` 展示并复用同一 `save` 闭包。
5. 失败路径（AC-04）：模型级 `testRetryAfterSaveFailureResavesTheIntactDraft` 证明
   失败 → 重试走同一保存路径并完整写入草稿；UI 级测试把 Vault 目录临时置为只读制造
   真实保存失败，断言失败条在详情栏内出现、编辑器不关闭、键盘焦点不丢（可继续输入）、
   恢复权限后点"重试保存"成功且草稿完整落盘。
6. 视觉与"不只依赖颜色"（P3/P4 遗留收口）：引用块新增左侧视觉引导线——呈现键
   `bearobsQuoteRegion` + 布局管理器按行绘制 3pt 圆角条（`tertiaryLabelColor`），引用
   段落样式缩进 12→16 为引导线留槽（对应用例同步更新）；深浅色全部使用语义色；焦点
   块有插入光标 + accent 边框 + caption，错误有图标 + 标题 + 文案。
7. 测试基础设施：`AppDirectories` 新增 `BEAROBS_AUTOPEN_VAULT` 启动环境，UI 测试自建
   临时 Vault 并在启动时直接打开（与 `BEAROBS_APP_SUPPORT_ROOT` 同一隔离机制），不读取
   也不写入开发者本机 Vault；失败路径测试无论断言走到哪一步都恢复目录权限后再清理。
8. 测试：新增 `EditorSurfaceInteractionTests` 6 例（Command-L 三态与穿透、节点朗读
   序列与去重、保存状态边沿朗读、进入编辑朗读、进入编辑自动聚焦、引用引导线呈现 +
   PDF 冒烟）；`EditorFeatureModelTests` 新增 1 例（重试不丢草稿）；`BearObsUITests`
   新增 5 例（键盘入口 + Command-S 落盘、Escape dirty guard 两分支、Command-L 任务
   切换、保存失败 + 重试、深色 + 最大辅助字号）。UI 测试内注释记录了快捷键投递的实测
   结论（typeKey 可达编辑表面第一响应者路径、到不了菜单键等价阶段，故 ⌘E 以菜单命令
   的存在/启用/触发验证，绑定本身留待人工走查）。
9. 门禁：SwiftPM 全量 345 测试通过；xcodebuild 测试计划 382 测试（含 7 条 UI）通过；
   `make check`（swift-format lint --strict、Golden Vault 13 例、WebDAV 契约）通过；
   `make build` Debug/Release 通过。
10. 移交与已知限制：人工 VoiceOver 走查清单已出具
    （`REQ-002-voiceover-checklist.md`，含日期、系统版本与自动化证据索引），待人工
    执行后填写结果；macOS 27 下容器 `accessibilityIdentifier` 会传播覆盖失败条子元素
    标识，UI 测试改按用户可见的 label/value 查询（不影响 VoiceOver 朗读）；checkbox
    命中范围 ±3pt（P4 记录维持）。

### P7：收口与文档同步

1. 运行 `make check`、`make test`、`make coverage`、Debug/Release build；
2. 做一次针对输入、链接协议、HTML/插件内容和文件写入的安全审查；
3. 更新 `03-development-design.md` 和 `04-development-plan.md`；
4. 将 REQ-002 的五项收口待办逐项链接到测试或验收证据后再勾选；
5. 只有 AC-REQ-002-01 至 06 全部有证据，才把 REQ-002 状态改成 `completed`。

#### P7 执行记录（2026-10-01）

1. 提交收口：P6 的键盘/VoiceOver/失败路径改动按 §11 第 8 项提交
   （`test: cover REQ-002 macOS acceptance paths`，含人工 VoiceOver 走查清单）。
2. 门禁（本机，2026-10-01）：`make check`（swift-format lint --strict、Golden Vault 13 例、
   WebDAV 契约 9 场景、密钥扫描）通过；`make test` 通过（SwiftPM 345 测试、xcodebuild 测试
   计划 382 测试，含 7 条 UI，0 失败）；`make coverage` 通过，BearObs.app 行覆盖
   85.04%（10480/12324，P0 基线 83.53%）；`make build` Debug/Release 通过。
3. 门禁期间发现两条 UI 偶发（同一提交下可复跑通过，非代码回归）：
   - 最大辅助字号下点击"编辑笔记"菜单项偶发以 INFINITY 命中点抛
     `NSInternalInconsistencyException`（堆栈在 XCUITest 事件合成层，菜单窗口布局期
     AX 框架瞬时无效，App 进程未崩溃）；
   - 全量并行时 `@FocusedValue` 向菜单命令的启用状态传播可能滞后超过 5 s。
   处置：`enterEditingThroughKeyboardEntry` 的启用轮询上限提高到 10 s
   （`test: harden menu entry polling in UI tests`）。实测 `isHittable` 对菜单项不可靠
   （可点击但持续报告 false），不得用作点击前门；INFINITY 命中点属 XCUITest 事件合成层，
   测试侧无法先行探测，作为已知偶发记录。
4. 安全审查（§9.2 逐项，无发现）：
   - 输入：编辑表面为纯文本（`isRichText=false`、`importsGraphics=false`、
     `allowsImageEditing=false`、自动链接检测关闭），粘贴只以纯文本进入草稿，不存在
     属性注入或附件面；输入全部经文本系统单一编辑管线进入模型草稿；
   - 链接协议：Reader 侧仅无凭据 `http`/`https`（必须含 host）与有效 `mailto` 可成为链接；
     内部路由仅承载已验证 `VaultPath`；编辑器内唯一的 `.link` 属性是任务 marker 的
     `bearobs-task://toggle`，点击在进程内消化为 3 字节替换，Markdown 行内链接为普通
     样式文本、不可点击，不产生新系统动作入口；
   - HTML/插件内容：InlineHTML 按原文文本渲染，未知语法以 opaque 局部源码区域显示并逐字节
     保留；应用内无 WebView、JavaScriptCore、`NSWorkspace.open` 或子进程执行面；
   - 文件写入：写入仅经 `LocalVaultStore` 协调原子替换，expected-hash CAS、文件身份与
     `AT_SYMLINK_NOFOLLOW` 检查、SHA-256 校验读、最小补丁写前完整性核对（`patched == candidate`）
     保持不变；错误 UI 全部为静态文案，不泄露路径、异常或文件内容；测试只写临时 Vault
     （`BEAROBS_APP_SUPPORT_ROOT`/`BEAROBS_AUTOPEN_VAULT`）并在结束清理。
5. 文档同步：`03-development-design.md` 新增 13.9 原位编辑表面切片；`04-development-plan.md`
   更新里程碑总览、当前执行位置与 M3 工作流 A 的 REQ-002 记录；REQ-002 需求第 8 节五项收口
   待办逐项链接证据（第 1—4 项勾选，第 5 项待人工 VoiceOver 走查）。
6. AC-REQ-002-01 证据补强：验收矩阵承诺的显式断言（无 sheet、无第二窗口、列表选择不变、
   保存后同一详情栏回显已保存内容）此前仅由全部编辑 UI 测试在主窗口内驱动编辑表面间接覆盖。
   本轮已撰写专项 UI 测试 `testEditingStaysInTheDetailColumnAndSavedContentReturnsToTheReader`
   补齐该断言；撰写完成时本机 GUI 会话进入锁定状态（2026-10-01 01:47 起，新应用激活被系统
   拒绝，UI 测试无法启动），该测试尚未通过一次门禁验证，因此保留在工作区、未随本次收口
   提交；会话解锁后随首个 `make test` 绿线单独提交。
7. 状态决定：AC-REQ-002-01 至 05 的自动化证据齐全（测试矩阵见 §8；AC-01 的显式断言测试
   见第 6 条，落地前由间接证据覆盖）；AC-REQ-002-06 的 VoiceOver 人工走查尚未执行
   （`REQ-002-voiceover-checklist.md`，自动化覆盖已完成并全绿）。依据第 5 步规则，REQ-002
   状态保持 `confirmed`，人工走查完成并在清单记录结果后方可改为 `completed`；实现计划本身
   全部阶段已执行完毕，状态改为 `completed`。

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

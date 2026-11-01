---
title: REQ-005 模块设计与开发任务
date: 2026-11-01
status: ready
requirement_id: REQ-005
tags:
  - requirements
  - ios
  - tasks
---

# REQ-005 模块设计与开发任务

本文件把 [REQ-005](REQ-005-ios-card-review.md) 拆成可独立交给 Cursor 或其他编码 agent 的任务。每个任务自带上下文、文件范围、实现要点、测试与完成定义。一次只派一个任务，完成并验证后再派下一个。

## 1. 怎么用这批任务

1. 按 T0 到 T6 的顺序执行，后一个依赖前一个的产出。
2. 派任务时把「任务正文」整段作为 prompt，并附上 REQ-005 全文。
3. 每个任务遵守仓库既有约束：TDD（先写失败测试）、Swift 6.2、warning 视为 error、不修改 Vault 字节、Mac 端行为不变。
4. 验证命令以该任务的「完成定义」为准，不需要每个任务都跑全量 `make ci`。

## 2. 模块边界

| 模块 | 新建文件 | 依赖 | 不依赖 |
|---|---|---|---|
| 回顾领域 | `BearObs/Domain/Review/ReviewRule.swift`、`ReviewBatch.swift`、`ReviewDrawing.swift` | Foundation | SwiftUI、GRDB、Index |
| 回顾状态 | `BearObs/Infrastructure/UserState/ReviewStateStore.swift` | 回顾领域 | 索引、Vault 文件 |
| 卡片投影 | `BearObs/Features/Library/CardFeedModel.swift` | `IndexedNoteSummary`、现有标签查询 | 回顾领域 |
| iOS 壳层 | `BearObs/App/iOS/` 内新增视图 | 以上三者 | AppKit、编辑面 |

依赖方向只有一条：iOS 壳层 → 卡片投影 / 回顾状态 → 回顾领域 → Foundation。回顾领域不得引用壳层类型。

已有、任务必须复用、禁止改动其字段与语义的类型：

- `IndexedNoteSummary`（`BearObs/Infrastructure/Index/IndexLibraryRepository.swift`）：`path`、`title`、`preview`、`modifiedAt`、`parseStatus`。
- `SQLiteIndexRepository.libraryNotes()`：已按修改时间倒序返回。
- 标签精确匹配语义：完整标签身份匹配，`project` 不包含 `project/mobile`（REQ-001）。
- iOS 只读接缝：`ReaderView` 以 `editorSource: nil` 构造（`BearObs/App/iOS/IOSWorkspaceView.swift`）。

## 3. 共享约定

- 摘要长度 140 个字符，按扩展字形簇截断，超出加 `…`。
- 卡片最多展示 3 个标签，其余折为 `+N`。
- 解析状态 `failed` 的笔记：卡片流里保留并显示「这条笔记暂时无法读取」；回顾候选里排除。
- 日期用用户当前日历的本地日，不使用 UTC 日。
- 固定文案集中在一个文案枚举里，测试比对枚举而不是散落的字符串。
- 新增类型放在对应模块目录，测试放在镜像目录：领域测试在 `BearObsTests/Domain/Review/`，状态测试在 `BearObsTests/Infrastructure/UserState/`。

## 4. 任务

### T0 文档对齐

**目标**：让开发计划承认 REQ-005，避免后续任务改完代码却无追踪。

**范围**：只改 `docs/04-development-plan.md`。

**要点**：在里程碑总览后加一行当前插队项，指向 REQ-005，说明它复用 M-iOS 的只读边界、不改变 M0-M4 顺序、不新增写路径。不要把 M-iOS 标记为完成。

**完成定义**：文档中能从开发计划跳到 REQ-005；`git diff` 只含该文件与本任务相关的文字。

---

### T1 回顾领域模型

**目标**：实现规则、批次与稳定抽取，全部纯逻辑。

**范围**：

- 新建 `BearObs/Domain/Review/ReviewRule.swift`
- 新建 `BearObs/Domain/Review/ReviewBatch.swift`
- 新建 `BearObs/Domain/Review/ReviewDrawing.swift`
- 新建 `BearObsTests/Domain/Review/ReviewDrawingTests.swift`
- `Package.swift` 不需要改，`BearObsDomain` 按目录收录。

**实现要点**：

- `ReviewRule` 为值对象。`contentScope` 取值 `all`、`includingTag(String)`、`excludingTag(String)`、`untagged`。`timeScope` 取值 `all`、`pastYear`、`pastSixMonths`、`pastThreeMonths`、`pastMonth`。`dailyCount` 仅允许 4、8、12、16、20、24，默认 8。
- 标签过滤的标签为空字符串时，规则的 `isSubmittable` 为 false。
- `timeScope` 提供 `cutoff(from now: Date, calendar: Calendar) -> Date?`，`all` 返回 nil。
- `ReviewBatch` 持有 `vaultID: UUID`、`day: DateComponents`（只要年月日）、`rule: ReviewRule`、`orderedPaths: [String]`。
- `ReviewDrawing.draw(candidates:rule:seed:) -> [String]`：先按规则过滤，再稳定洗牌，取前 `dailyCount` 条。候选元素至少含路径、修改时间、标签集合、是否可读取。
- 洗牌算法自定，但必须满足：同一种子与同一输入得到同一顺序。建议用种子化的 Fisher-Yates，随机源由种子决定，不使用 `SystemRandomNumberGenerator`。
- 过滤顺序固定：排除不可读，再按时间下限，再按内容范围。内容范围使用完整标签身份的精确匹配。

**测试（先写，确认失败后再实现）**：

- 默认规则数量为 8，且 `isSubmittable` 为 true。
- `includingTag("")` 不可提交。
- 时间下限：`pastMonth` 排除早于下限的候选。
- `includingTag("project")` 不包含只有 `project/mobile` 的候选。
- `excludingTag` 与 `untagged` 的边界各一条。
- 不可读候选不进入结果。
- 候选少于数量时返回全部。
- 同一种子两次抽取结果完全相同；不同种子允许不同。
- 结果长度不超过 `dailyCount`，且成员都来自候选。

**完成定义**：`swift test --filter ReviewDrawingTests` 通过；新文件不 import SwiftUI 与 GRDB。

---

### T2 回顾状态存储

**目标**：按 Vault 持久化规则与当日批次，可删除重建。

**范围**：

- 新建 `BearObs/Infrastructure/UserState/ReviewStateStore.swift`
- 新建 `BearObsTests/Infrastructure/UserState/ReviewStateStoreTests.swift`

**实现要点**：

- 存在 App 沙箱的用户状态目录下，每个 Vault 一个 `review-state.json`，与 `user-state.json` 并列，具体目录函数复用 `FileUserStateStore` 已有的定位方式，不新建第二套路径规则。
- JSON 只含规则与批次。编码失败返回明确错误，不写半截文件：先写临时文件再原子替换。
- 读取时文件不存在返回空状态，不视为错误。
- 提供 `load(vaultID:)`、`save(vaultID:rule:)`、`save(vaultID:batch:)`、`delete(vaultID:)`。
- 不读写 Vault 目录，测试用临时目录断言 Vault 侧字节不变。

**测试**：

- 保存后重新加载，规则与批次往返相等。
- 文件不存在时加载得到空状态。
- 覆盖保存不留下临时文件。
- 删除后再次加载为空。
- 两个 Vault 的状态互不读取。

**完成定义**：`swift test --filter ReviewStateStoreTests` 通过；用临时目录模拟的 Vault 目录在测试前后字节一致。

---

### T3 卡片投影

**目标**：把索引结果投影成卡片流模型，包含摘要截断、标签折叠与失败降级。

**范围**：

- 新建 `BearObs/Features/Library/CardFeedModel.swift`
- 新建 `BearObsTests/Features/Library/CardFeedModelTests.swift`

**实现要点**：

- `Card` 为值对象：`path`、`title`、`excerpt`、`visibleTags`、`extraTagCount`、`modifiedAt`、`readability`。
- 投影函数是纯函数，输入为 `IndexedNoteSummary` 加该路径的标签列表，不直接读数据库。数据库读取留在调用方。
- 标题为空时用路径的文件名（去掉 `.md`）。
- 摘要按 140 个扩展字形簇截断。
- `parseStatus == .failed` 时 `readability` 为不可读，摘要替换为固定文案。
- 标签按输入顺序取前 3 个，`extraTagCount` 为剩余数量。
- 提供 `filtering(byTag:)` 与 `filtering(bySearch:)` 的纯函数版本，搜索复用调用方传入的匹配路径集合，不在这里重写搜索。

**测试**：

- 空标题落到文件名。
- 140 字边界：140 不截断，141 截断并加省略号。
- 多码点字符（如 emoji）不被从中间截断。
- 5 个标签得到 3 个可见与 `extraTagCount == 2`。
- 失败笔记的摘要为固定文案。
- 标签过滤使用精确匹配。

**完成定义**：`swift test --filter CardFeedModelTests` 通过；投影函数无 I/O。

---

### T4 iOS 卡片流壳层

**目标**：iPhone 上用卡片流替换五入口里的笔记列表。

**范围**：

- 改 `BearObs/App/iOS/IOSWorkspaceView.swift` 的紧凑宽度部分。
- 新建 `BearObs/App/iOS/CardFeedView.swift`。
- 新建 `BearObs/App/iOS/ReviewRootView.swift`（本任务只放占位，T5 填内容）。
- 测试改 `BearObsIOSUITests/BearObsIOSUITests.swift` 中依赖旧五个入口的断言。

**实现要点**：

- 紧凑宽度 `TabView` 改为三个入口：笔记（卡片流）、回顾（占位）、标签。
- 卡片流顶部为搜索框与可清除的标签过滤条，主体为 `Card` 列表。
- 点卡片推入 `ReaderView`，`editorSource` 传 nil。
- 点卡片上的标签设置过滤，不推入阅读。
- 返回时保留滚动位置与过滤，沿用现有 `NavigationStack` 的方式，不要在 `onAppear` 里重置过滤。
- iPad 常规宽度分支（`VaultWorkspaceView`）不动。
- 索引中、空、失败三个状态复用现有文案与互斥状态，不新增第四套。

**测试**：

- 更新 iOS 冒烟：选择 Vault 后看到卡片而不是旧的笔记列表入口。
- 断言紧凑宽度不存在 `ios-tab-recent` 与 `ios-tab-favorites`。
- 断言无编辑入口（沿用 REQ-004 的断言）。

**完成定义**：`make build-ios` 通过；iOS 冒烟 UI 测试通过；Mac 目标的现有测试不需要改断言。

---

### T5 每日回顾页

**目标**：把 T1、T2 接到回顾入口上。

**范围**：

- 实现 `BearObs/App/iOS/ReviewRootView.swift`。
- 新建 `BearObs/App/iOS/ReviewRuleEditor.swift`。
- 新建 `BearObsTests/App/ReviewFlowTests.swift`，测试对象是一个不依赖 SwiftUI 的 `ReviewSessionModel`，放在 `BearObs/App/iOS/ReviewSessionModel.swift`。

**实现要点**：

- `ReviewSessionModel` 持有规则、批次与「未保存」标记，暴露 `open(today:candidates:)` 与 `updateRule(_:today:candidates:)`。
- `open` 实现 REQ-005 §9.4：批次为今天且规则未变则复用，否则调用 `ReviewDrawing.draw` 后经 `ReviewStateStore` 落盘。
- 落盘失败时结果仍返回，`persistenceFailed` 为 true。
- 规则编辑器：内容范围用分段选择，选「含标签 / 排除标签」时展开标签选择；未选标签时完成按钮不可用。时间范围五个选项。数量用步进器，步长 4。
- 确认修改前弹出「按新规则重新抽取今日回顾？」，取消不调用 `updateRule`。
- 候选为空与候选不足的文案按 REQ-005 FR-002 第 5 条。

**测试（针对 `ReviewSessionModel`，不启动 UI）**：

- 同一天第二次 `open` 不改变批次路径顺序。
- 日期加一天后 `open` 重新抽取。
- `updateRule` 后批次按新规则生成。
- store 抛错时 `persistenceFailed` 为 true 且仍有结果。
- 候选为空时批次路径为空。

**完成定义**：`swift test --filter ReviewFlowTests` 通过；回顾页代码不引用 AppKit 与编辑面类型。

---

### T6 收口验证

**目标**：证明这条线和只读边界、Mac 基线都不冲突。

**范围**：只改测试与文档中的证据记录，不改产品代码；产品代码有问题则退回对应任务。

**要点**：

- 跑 `swift test --filter ReviewDrawingTests`、`ReviewStateStoreTests`、`CardFeedModelTests`、`ReviewFlowTests`。
- 跑 iOS 冒烟，确认三个入口、无编辑入口、卡片可推入阅读面。
- 跑 Mac 单元测试一次，确认无新增失败。
- 在 `docs/04-development-plan.md` 的该行补上验证命令与日期。

**完成定义**：上述四组测试与 iOS 冒烟通过，Mac 单元测试无新增失败，开发计划有证据记录。

## 5. 派任务模板

```text
按 docs/requirements/REQ-005-ios-card-review-tasks.md 的 T<n> 执行。
先读 docs/requirements/REQ-005-ios-card-review.md。
只改该任务「范围」里列出的文件，不扩大范围。
先写该任务列出的测试并确认失败，再写实现。
完成后运行该任务「完成定义」里的命令，把结果贴回来。
不要修改 Vault 内容、索引 schema、Mac 端行为。
```

## 6. 不在任何任务里

- 新建笔记、编辑、删除、上传。
- 间隔重复与记忆评分。
- 小组件、推送、锁屏回顾。
- 改动 `IndexedNoteSummary`、索引 schema、`ReaderView` 的编辑分支。
- 改动 iPad 三栏与 Mac 壳层。

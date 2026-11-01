# REQ-004 iOS 待开发与验收交接清单

日期：2026-10-25。执行方：zcode。范围：完成 M-iOS 只读内部 P0。

## 1. 核心判断与执行边界

值得做的是补齐只读版本的可靠性和验收。五入口、本地索引、阅读、收藏、缓存回退与三栏已有实现，不从零重做。

- 业务能力：选择本地/iCloud Drive Vault → 索引 → 浏览、搜索、阅读与本机收藏。
- 应用构件：iOS 壳层和共享 Library/Reader、Index、LocalVault、UserState；不另建同步或导航模型。
- 数据事实源：Vault 的 Markdown/附件；SQLite、正文快照和收藏只能写在 App 自己的目录。
- 技术约束：独立 iOS target，最低 iOS 26.0，固定 Xcode 26.5；编辑 UI 保持编译期隔离，Mac 零回归。

本清单不授权开发编辑、新建、删除、重命名、WebDAV、上传、跨设备收藏、图片附件渲染、小组件或后台刷新。它们属于后续另立需求。

事实依据：

- [REQ-004 原需求](REQ-004-ios-read-only-client.md)，产品验收唯一上游。
- [ADR-010](../adr/ADR-010-ios-platform-strategy.md)，平台边界。
- [开发计划 §8A](../04-development-plan.md)，M-IOS-5 原任务与历史证据。
- [完整测试方案](REQ-004-ios-test-plan.md)，下文测试编号均指向该文件。
- [本次验证报告](REQ-004-ios-test-report-2026-10-25.md)，仅记录实际执行结果。

## 2. 先明确哪些已经存在

| 能力 | 当前实现 | 接手时的动作 |
|---|---|---|
| 五入口与阅读 | `IOSWorkspaceView.swift`、共享 `WorkspaceColumns.swift` / `ReaderView.swift` | 保留，补导航与状态回归 |
| 文件夹选择、书签、切换 | `AppEnvironment.swift`、`VaultSelectionStore.swift` | 补真实 picker/授权与失败恢复验证 |
| 索引容错与缓存正文 | `IncrementalIndexScanner`、全量重建、`IndexedSourceSnapshotStore`、Reader fallback | 保留，补跨层端到端证据 |
| iPad 三栏和恢复 | 复用 `VaultWorkspaceView`；已有 `SceneStorage` 字段 | 重点审查隔离与生命周期，补三栏业务测试 |
| 字号/外观/可访问性 | 已有语义标签、勾选态与离屏渲染测试 | 补真机 VoiceOver 和双宽度走查 |
| CI | 双平台 Debug/Release、iPhone 测试、覆盖率、iPad 空态启动 | iPad 空态不能当三栏验收；补真实门禁 |

现有 11 条 iPhone UI 测试的覆盖映射见测试方案 §3。历史测试数字不代表当前工作树重跑通过。

## 3. 工作包总表

优先级：P0 为只读安全或数据隔离；P1 为 REQ-004 交付必需。两级都要关闭才能完成 M-iOS。
“验证后修复”表示先复现、再按失败事实改代码，不能凭推测增加抽象层。

| ID | 优先级 | 性质 | 工作包 | 前置 | 原计划追踪 |
|---|---|---|---|---|---|
| IOS-DEV-01 | P0 | 基线修复/交付 | 修复 SwiftPM 测试编译、保全工作树、固定输入 | 无 | M-IOS-5.16 |
| IOS-DEV-02 | P0 | 测试开发 | 全 Vault 只读清单与平台隔离门禁 | 01 | AC-004-01/02/08；5.12 |
| IOS-DEV-03 | P0 | 验证后修复 | iPad 恢复状态的 Vault 隔离及无效状态回退 | 01 | M-IOS-5.8/5.12 |
| IOS-DEV-04 | P1 | 测试开发 | iPad 三栏业务测试与双宽度生命周期 | 02、03 | M-IOS-5.11/5.12 |
| IOS-DEV-05 | P1 | 测试开发 | iPhone 完整导航、搜索、标签、链接回归 | 02 | M-IOS-5.12 |
| IOS-DEV-06 | P1 | 测试开发 | 索引、缓存、收藏及选择失败的跨层验证 | 02 | M-IOS-5.3～7/5.12/17/18 |
| IOS-DEV-07 | P1 | 门禁开发/环境 | iOS 26.0 + 当前可用版本测试与证据 | 04～06 | M-IOS-5.11/5.13/5.14 |
| IOS-DEV-08 | P1 | 真机验收 | 文件授权、iCloud 和只读端到端 | 02、06 | M-IOS-5.15 |
| IOS-DEV-09 | P1 | 人工验收/修复 | VoiceOver、字号、外观与 iPad 分屏 | 04、05 | M-IOS-5.9/5.15 |
| IOS-DEV-10 | P1 | 集成验收 | 干净 checkout 全门禁、缺陷关闭与文档更新 | 01～09 | M-IOS-5/5.16 |

### IOS-DEV-01：固定输入，保留已有工作

- 本次已确认失败：`make ci` → `scripts/domain/verify-domain-model.sh` → SwiftPM Release 测试编译，`VaultSelectionStoreTests.swift` 无法访问 `VaultSelectionSaveCheckpoint` 与内部故障注入构造器。该测试的 `SWIFT_PACKAGE` 分支使用普通 `import BearObsUserState`，而 Xcode 分支是 `@testable import BearObs`；先复现并以测试可见性最小修复解决，不要为了测试把内部接缝扩成公共 API。
- 回归命令至少包含 `make domain-model`（含 Release、Debug/覆盖率和 Domain iOS 交叉编译），并完成后续全门禁；不能只跑 Xcode 测试就标完成。
- 接手先记录 HEAD、分支、工作树文件和 diff；当前已有生产代码、测试及开发计划修改，README 也尚未跟踪。
- 分清已有改动和本轮改动；不得 reset、覆盖或丢弃现有文件，不以“从 HEAD 重做”替代保全。
- 将确认属于交付的改动纳入可复现版本；遵循项目提交规则，未经授权不推送或发布。
- 先运行相关现有测试记录基线；新失败记录为基线失败，不能顺手改需求或删断言。
- 先对齐规范与实现的已知差异：REQ-004 §7 仍限制索引 schema 不变且平台接缝清单未列完整，当前计划已记录 schema v6，代码已有 iOS 快照构造与 Reader 缓存重试分支。核对提交/ADR 依据并补充真实接缝及迁移回归；不能为符合过时文字删除已有容错能力，也不能把文档过时当作任意放宽约束的授权。
- 验收：源版本和工作树差异可追溯；最终由 10 完成干净 checkout 验证。对应 B-01、B-09。

### IOS-DEV-02：完整只读证据与编译期隔离

- 现有 UI helper `markdownBytes(in:)` 只看非隐藏 `.md`；无法证明附件、`.obsidian`、其它文件和目录没有被写入。
- 建立合成 Vault 清单比较：全部目录项、普通文件相对路径/类型/大小/SHA-256、符号链接本身的目标（不跟随）；操作前后比较新增、删除、改名和字节变化。清单保存在 Vault 外。
- fixture 包含 Markdown、附件、隐藏 `.obsidian` 配置、Unicode/空格/百分号路径、BOM/CRLF；测试不能在真实用户 Vault 上制造故障。
- 区分 App 主动修改和 File Provider 的下载/元数据变动：本地静态 fixture 做严格清单比较，iCloud 以下载完成后的内容清单及 provider 状态单列证据；不把 atime 变化当写入缺陷。
- 对照 REQ-004 §7 校验 iOS App 源文件成员与编辑 UI 编译守卫；增加破坏性 fixture 验证门禁确实能拒绝编辑面误入，且不误拒绝允许共享的模型/解析代码。
- Release 中测试专用导入接缝不能激活；不要求删除共享核心里未被 iOS 产品入口调用的写能力。
- 验收：Q-01～Q-06、B-02、B-08；所有 iOS 关键流程复用同一清单断言。

### IOS-DEV-03：恢复状态隔离，先写复现

- 位置：`BearObs/App/iOS/IOSWorkspaceView.swift` 的 `IOSVaultWorkspaceView`。
- 现有三字段 `restoredVaultID`、`restoredDestinationID`、`restoredNotePath` 使用共享 SceneStorage key；两个 persist 回调各自只更新部分字段。
- 待复现风险：A 留下收藏入口/笔记路径，切换 B 后只改 B 的笔记或入口，可能把 B 的 ID 与 A 的另一个残留字段组合，导致重启走错入口或笔记。此项是审查风险，尚未判定为已复现缺陷。
- 先覆盖两种回调顺序、同名路径跨 Vault、无效目的地、标签/笔记已被外部删除。需要改动时以完整恢复状态保证一致性，避免更多互相补偿的 if。
- 继续遵守首次进入新 Vault 的默认入口；不要凭本任务改变“每次新选择的 Vault ID”语义，也不要新增阅读历史模型。
- `SceneStorage` 是否足以满足进程终止/系统回收后的恢复必须实测；测试失败再调整最小存储方式，不能以纯编解码单测代替生命周期证据。
- 验收：P-04～P-07、V-07；恢复内容始终属于当前 Vault，无数据时确定性回退。

### IOS-DEV-04：真正的 iPad 业务门禁

- 位置：`BearObsIOSUITests/`、`scripts/ci/test-ios.sh` 和必要的稳定 accessibility identifier。
- 当前 iPad 仅跑 `testLibraryEmptyStateLaunches`，之后 install/launch。保留冒烟测试，同时增加加载合成 Vault 后的三栏断言。
- 验证导航栏职责、列表筛选、详情切换、收藏/搜索/标签、Wiki Link、Vault 入口、错误提示与恢复。
- 三栏断言识别栏位和内容，不锁定绝对像素或系统本地化文案；不能把 iPhone Tab 测试原样塞给 iPad。
- 如增加 DEBUG size-class 接缝，只用于逻辑分支自动化，必须与真实 iPad 分屏证据分开，Release 不生效。
- 验收：P-01～P-09；常规宽度业务 suite 真正进入脚本门禁。真分屏/旋转由 09 关闭。

### IOS-DEV-05：补齐 iPhone 行为测试

- 每个列表进 Reader 再返回：查询、标签和滚动位置保留；同一条笔记可以再次打开。
- 多级 Wiki Link 连续进入、逐级返回；缺失/歧义/非法链接不跳转；外部链接交系统处理。
- 搜索覆盖标题/正文/标签/中文、空查询最近排序、零结果、快速换词及取消；不把“最近”改成最近阅读，当前按文件修改时间排序。
- 标签覆盖父子双向精确匹配、隐式父分组不应被当作真实标签、相同尾段不同完整身份。
- 外链测试可在渲染层记录 OpenURLAction，再在设备上验交接；自动测试不依赖公网或其它 App 已安装。
- 验收：N-01～N-07、S-01～S-06、R-01～R-05；已有同等测试直接复用，不重复计数。

### IOS-DEV-06：错误和恢复必须贯通到用户界面

- 保留 LocalVault、Index、Reader、Favorites 与 Workspace 已有故障注入单测。
- 补 UI/跨层场景：首次索引期间状态、部分文件不可用/恢复、可用旧缓存/无缓存/缓存损坏、收藏持久化失败、切换 Vault 的准备或保存失败。
- 取消选择不弹错误；真正失败保留旧工作区和磁盘选择；重启仍恢复旧 Vault。
- 全量 `rebuild/replaceAll` 取消或数据库错误必须整笔事务回滚；增量 `scan` 按文件提交，允许保留已提交文件，但失败操作不能留下不一致的 note/tags/FTS，错误向上传递且下轮可恢复。不要把增量改成全 Vault 单事务。
- 局部文件不可读不能阻断其它文件或误删旧索引。
- 若 UI 无法稳定注入，复用现有端口/fixture 加最小 DEBUG 测试接缝；不能引入生产设置项或复制生产状态机。
- 验收：V-01～V-09、I-01～I-08、F-01～F-04、E-01～E-04。

### IOS-DEV-07：版本与覆盖率门禁如实报告

- 现有 CI 指定 `CI_IOS_RUNTIME=26.0`，而本机仅有 26.5；必须确认 CI runner 能提供 26.0，缺失时明确环境阻塞，不能自动退到新版本后写成最低版本通过。
- 在可用环境执行 26.0 与当前安装版本（本次为 26.5）；固定准确 runtime/device，报告实际选择。
- 保留核心与变更 Swift 的 80% 行覆盖率和 executable-subrange 代理门禁。它不是真实 Swift 分支覆盖率；报告不能换名。
- PR 运行明确 `COVERAGE_BASE_REF`；仅对空工作树执行 changed gate 会出现 0/0，不能用来冒充变更覆盖率证据。
- 检查证据新鲜度：本轮中断时旧 `coverage-ios-gate.txt` 仍可能保留。测试失败或覆盖率导出失败时，不得读取历史 PASS 文件作为当前结果；以本次退出码及可关联的结果包为准。
- 验收：B-01～B-07、B-09；输出测试数、失败/跳过、覆盖率分母、日志和 `.xcresult`。

### IOS-DEV-08：真机/iCloud 验收与最小修复

- 使用开发签名构建和合成 Vault；真实 picker 选择不可被 `BEAROBS_AUTOPEN_VAULT` 或测试导入接缝替代。
- 验证选择、重启恢复、授权失效、切换、下载完成文件离线阅读、未下载占位文件失败提示与网络恢复。
- 未下载且没有缓存的正文不能保证离线可读。不要把占位文件误识别为删除，也不要显示其它笔记内容。
- 测试 App 本地派生数据与 Mac 收藏互不影响；同时阻断真实同步/远端写路径。
- zcode 交付可执行步骤和设备证据；缺硬件、签名账号或 iCloud 测试条件时标 BLOCKED，并继续其余独立任务。
- 验收：D-01～D-07、Q-04；按测试方案记录 provider 行为与 App 行为。

### IOS-DEV-09：真实可访问性与外观

- 最大辅助字号和普通字号 × 浅/深色；iPhone 与 iPad 常规/分屏布局全部走核心链路。
- 真机 VoiceOver 验证入口、标签完整层级和计数、链接目标、收藏切换与错误；焦点顺序合理，无不可达控件。
- 验证选中态可通过文字/勾选识别，长标题/标签不遮挡操作，旋转与收窄不丢工作区。
- 离屏渲染通过不能替代屏幕阅读器交互验收。先重现具体缺陷再改共享视图，改后重跑 Mac。
- 验收：A-01～A-05、P-03/P-08/P-09。

### IOS-DEV-10：交付关闭

- 本地顺序：`make check` → `make build` → `make test` → `make test-ios` → `make coverage`；完整工程门禁为 `make ci`，包含 Spike 和 Domain 验证。
- 测试不能共享 DerivedData/结果目录并发运行；每次覆盖报告前归档上次证据。
- 运行干净 checkout；PR 使用真实比较基线，保留未过滤测试输出与退出码。
- 逐项更新本清单、测试矩阵执行状态和原开发计划 M-IOS-5；所有人工/环境项未关闭前仍为“进行中”。
- 产出：变更文件与原因、测试映射、缺陷记录、测试报告、设备签名包（条件具备时）；对外发布不在本清单内。
- 验收：全部必需案例 PASS，无 Critical/High 缺陷、无未经解释的 skip；Mac 原有功能零回归。

## 4. 建议执行批次

1. 基线和只读保护：01、02，同时为 03 写最小失败复现。
2. 自动化与必要修复：03～06。可以分工，但 Xcode 测试按顺序运行，避免相互污染。
3. 平台和设备：07～09；人工缺条件不妨碍已授权的自动化开发。
4. 集成关闭：10。不能用“脚本存在”代替“脚本实际通过”。

## 5. zcode 的完成报告格式

每个工作包报告：状态（TODO / IN PROGRESS / PASS / FAIL / BLOCKED）、变更理由、源版本、实际测试编号和结果、证据路径、剩余条件。

开发完成和验收完成分别列出。没有复现的风险写“未复现/已加回归”；缺硬件写 BLOCKED。不要把历史 395/11 用例或旧覆盖率复制成本轮结果。

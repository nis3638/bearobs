# BearObs M0-01～M0-10 工程基线

## 范围

本基线只覆盖独立 Git 边界、macOS 15+ SwiftUI/AppKit 工程、测试 targets、CI、依赖与配置管理、
M0-05 Golden Vault、M0-06 可控 WebDAV fixture、M0-07 GRDB/FTS5 Spike、M0-08 Markdown
Spike、M0-09 Atomic Write Spike，以及 M0-10 Domain Model。项目 Git 根目录固定为
`/Users/ivows/workspace/bearobs`，默认分支为 `main`；父目录仓库不再承载 BearObs 历史。
本文件也持续记录已完成的 M1 生产边界证据，但不代表完整 M1 完成；当前仍不实现生产 WebDAV
客户端、同步执行器或远端写业务。

## 工程约束

- Xcode 固定为 `.xcode-version` 中的 26.5，最低部署版本为 macOS 15.0。
- M-iOS 起新增 iOS 只读 App target（`BearObsIOS`，最低部署版本 iOS 26.0，与
  `Package.swift` 的 `.iOS(.v26)` 平台声明一致）和 iOS 冒烟 UI Test target；
  平台策略见 [ADR-010](adr/ADR-010-ios-platform-strategy.md)。
- 共享源码以文件成员方式同时进入 Mac 与 iOS App target；AppKit 编辑面文件仅进入 Mac
  target。每次新增共享源文件必须同时登记两侧成员，两平台构建门禁负责兜底。
- 共享 `BearObs` scheme 必须提交；CI 不读取 `xcuserdata`。
- Bundle ID 集中在 `Config/App.xcconfig`，当前初始化值为 `com.ivows.bearobs`；
  iOS App target 的 Bundle ID 集中在 `Config/App-iOS.xcconfig`。
- Debug 和 Release 都把编译 warning 当 error。

## 本地与 CI 命令

```bash
make check      # swift-format、秘密模式和工程卫生检查
make build      # macOS + iOS 模拟器 Debug/Release 双平台构建门禁
make test       # Unit Test + UI Test
make build-ios  # 与 make build 相同的双平台构建门禁（M-iOS 兼容入口）
make test-ios   # 共享核心 iOS 模拟器测试 + iOS 冒烟 UI 测试（M-iOS 起）
make dist-macos # macOS Release 包：ad-hoc 签名 .app + zip + dmg，输出到 out/dist/
make dist-ios   # iOS 开发签名 .ipa，需 DEVELOPMENT_TEAM=<team id>（M-iOS 起）
make coverage   # Unit Test coverage，输出到 .build/reports/
make spike-grdb # GRDB/FTS5 测试、覆盖率门禁和 macOS 15 交叉编译
make spike-markdown # Markdown 测试、覆盖率门禁和 macOS 15 交叉编译
make spike-atomic-write # 原子替换、SIGKILL、覆盖率和 macOS 15 交叉编译
make domain-model # 领域模型 host XCTest、覆盖率和 macOS 15 交叉编译
make ci         # 与 CI 相同的完整顺序
```

可用 `CI_DESTINATION='platform=macOS' make test` 显式指定 Mac 测试目标。
未指定时，脚本使用当前 macOS host 作为默认测试目标。可用 `CI_DEVICE_TYPE` 显式替换目标，
但 CI 基线不使用浮动目标。

## 覆盖率口径

当前只有工程壳层，coverage job 的目标是证明采集和报告链路可重复执行，不设置虚假总量门槛。
当 M0-10 及后续核心模块出现后，应仅对 Domain、Markdown、Vault、Sync 和 WebDAV 安全边界执行
行覆盖率与分支覆盖率 80% 门禁；生成代码和纯布局代码不得稀释分母。

## M0-05 Golden Vault

- fixture 位于 `BearObsTests/Fixtures/GoldenVault`，并作为目录资源复制到 Unit Test bundle；
- 所有内容均为合成数据，`contract.json` 显式声明不含真实用户内容；
- 13 个稳定 parser case 覆盖 YAML 标签、Inline/嵌套标签、代码排除、同名和显式路径
  Wiki Link、Unicode/空格/百分号路径、图片与缺失附件、无效 Frontmatter、BOM、LF/CRLF
  和不支持语法的原文降级；
- 性能基线包含精确 1 MiB Markdown 和 256 个小文件；M1/M4 的 10,000 文件性能验收应由
  独立扩容 profile 生成，不能把 256 文件基线冒充最终规模验收；
- `scripts/fixtures/verify-golden-vault.swift` 是无需 Simulator 的 fixture 完整性门禁；
- `GoldenVaultContractTests` 验证 test bundle 集成，并为后续 parser golden tests 提供
  可解码的期望结构。

机械样本由 `scripts/fixtures/generate-golden-vault-assets.swift` 确定性生成。语法样本保持
手写和可审查，避免把兼容性语义藏进生成器。

## M0-06 可控 WebDAV fixture

- fixture 位于 `BearObsTests/Fixtures/WebDAV`，只含合成 Markdown、静态 `207 Multi-Status`
  响应和显式 `contract.json`；
- `ControlledWebDAVFixture` 通过每个测试独立的 HTTPS `.invalid` origin 和 session-local
  `URLProtocol` 提供 PROPFIND Depth:1、精确字节 GET、已有文件条件 PUT、412/428 和 405；
- 资源状态统一为百分号编码路径、正文、ETag、Last-Modified 和 revision；路径只解码一次，
  PUT 只有强 ETag 精确匹配才提交，失败不得修改正文或 validator；
- contract 引用的 fixture 文件在实际读取边界拒绝绝对路径、`.`、`..`、空段和解析后越根
  的符号链接；门禁同时用 traversal 与 symlink 样本验证；
- 故障队列按 method 和编码路径 FIFO 一次性消费，支持 401/503、`URLError`、部分响应后
  中断；不使用随机延迟、真实端口或公网服务；
- 请求诊断只保留 method、编码 path、body 长度和结果，不记录 Authorization、URL query、
  userinfo 或正文；
- `scripts/fixtures/verify-webdav-fixture.swift` 验证静态契约、资源、场景和 XML 元数据；
  `verify-webdav-behavior.swift` 在无 Simulator 条件下编译并执行同一份 fixture 行为；
- 11 个 XCTest 契约已通过 Swift 6 严格并发 `build-for-testing`，WebDAV 目录已验证复制到
  Unit Test bundle。

本机当前没有可用的 macOS UI 自动化运行目标，因此本轮
`make test` 无法启动运行目标。该环境缺口不影响 host 行为验证、Debug/Release 构建
或 test bundle 编译；配置可用的 Mac UI 测试目标后，现有 test plan 会直接执行这些 XCTest。

该 fixture 只证明 HTTP 客户端接缝，不证明真实 TLS、认证 challenge、重定向或厂商方言；
这些仍由 M0-11 和 M2-A6 的真实服务认证负责。

## M0-07 GRDB / FTS5 Spike

- 隔离包位于 `Spikes/M007GRDBFTS5`，不提前冻结 M1 的生产索引 schema；
- GRDB 精确锁定为 7.11.1，revision 为
  `b83108d10f42680d78f23fe4d4d80fc88dab3212`，并提交 `Package.resolved`；
- 两段 migration 验证 v1 普通表升级、v2 FTS5 `unicode61` 建表和旧数据回填，重复打开幂等；
- `DatabasePool` 原生 async read/write 在并发批量写和并发读取下保留全部 1,000 条记录；
- 普通表与 FTS 表在单个 GRDB 写事务中更新，替换记录后旧词项不可查、新词项精确命中；
- 批处理中途注入 SQLite 错误后，已经执行的普通表和 FTS 变更全部回滚；
- 10,000 条合成数据多轮 Release 单事务写入观测为 2.855～3.204 秒，每轮 30 次唯一词
  搜索 P95 为 0.302～0.330 毫秒；
- Spike 源码行覆盖率为 99.02%，region 覆盖率为 95.00%，arm64 macOS 15 Release 交叉编译通过。

10k 数字来自 arm64 macOS 26.5 开发机，只是工程基线，不替代最低目标 Mac 真机的
NFR-03 验收。`unicode61` 只确认大小写、音调符号和连续中文短语的已知行为；中文分词质量
仍须在 M1 使用真实合成/授权语料测量。

## M0-08 Markdown Spike

- 隔离包位于 `Spikes/M008Markdown`，复用 M0-05 Golden Vault，不复制或改写 fixture；
- `swift-markdown` 精确锁定为 0.8.0，revision 为
  `3c6f9523da3a1ec2fd829673e472d95b8097a3b8`；Yams 精确锁定为 6.2.2，revision 为
  `a27b21e0c81c5bf42049b897a62aaf387e80f279`；
- 标准 Markdown 由不可变 AST 遍历，代码、标准链接/图片和 HTML 的 `SourceRange` 统一转换为
  UTF-8 字节遮罩，再由独立扫描器提取 Inline Tag、Wiki Link 和 Embed；
- Frontmatter 只读取 `title` 与字符串/数组 `tags`，无效或未闭合 YAML 产生诊断并保留可读正文，
  原始 `Data` 始终不变；
- 14 个 XCTest 覆盖 AST、标准链接/图片、YAML 字符串/数组、空白和无效 Frontmatter、
  代码/URL/HTML 排除、链接可见文字、Wiki Link/Embed 转义、Golden Vault 契约、Unicode、
  BOM、LF/CRLF、无效 UTF-8、1 MiB 和 256 小文件；
- 本机三次 Release 基线为 1 MiB 约 74.6～101.9 毫秒、256 个小文件约 22.6～40.5 毫秒；
  源码行覆盖率 93.74%，arm64 macOS 15 Release 交叉编译通过。

这些性能数字来自 arm64 macOS 26.5 开发机，只证明方案没有明显数量级问题，不替代最低目标
Mac 的 NFR。`diagnosticHTML` 是依赖输出的未清洗诊断值，禁止进入 WebView 或作为可信 HTML；
M1 Reader 必须建立原生渲染边界。Spike 不解析链接目标路径、不决定同名链接、不写回 YAML，
也不冻结 M1 的领域模型。生产入口还必须加入文件大小/YAML 复杂度上限。

## M0-09 Atomic Write Spike

- 隔离包位于 `Spikes/M009AtomicWrite`，无第三方依赖，不链接 App target；
- 只替换已有 regular file，拒绝缺失目标、目录、符号链接和非文件 URL；
- 打开稳定父目录 descriptor，在其内以 `O_CREAT | O_EXCL | O_NOFOLLOW` 创建 sibling staging，
  完整写入、保留 POSIX rwx mode、`fsync` 并关闭后，核对 staging/目标 inode，再用单次
  `rename` 提交、同步父目录并重读校验；清理同样按 inode 约束，降低误删同名替换文件风险；
- 提交前 ENOSPC、permission、file sync、close 和 rename 失败均保留完整旧文件；目录同步
  失败报告耐久性未确认，目录已同步后的重读失败则明确报告已持久化但校验失败；
- Writer 只处理 `Data`，BOM、LF/CRLF、混合换行、空文件和任意非 UTF-8 字节逐字节保留；
- 15 个 XCTest 通过，覆盖短写/EINTR 和 destination、staging、父路径、发布后 FIFO 竞争；
  library region coverage 87.04%、line coverage 94.88%；Xcode 26 未为 Swift-only target 生成 branch
  records，因此临时以 region ≥ 80% 加显式故障/分支矩阵门禁，不能把 `0/0` 冒充 branch
  coverage 通过；独立子进程在 7 个 staging/publish 边界接受 SIGKILL 后，父进程只观察到
  完整旧版或完整新版；
- arm64 macOS 15 Release 交叉编译通过。

SIGKILL 只证明进程终止，不冒充物理断电测试。Spike 不承诺 ACL、extended attributes、
ownership、macOS Keychain 与文件访问保护、祖先目录 symlink、Vault containment 或 expected-hash/CAS；
inode 核对只是 best-effort，`fstatat -> renameat/unlinkat` 仍有非原子 check/use 窗口，不等于
内容级并发控制；M3 必须用 Vault actor、文件协调、expected hash 和恢复策略闭合。崩溃残留
staging 没有 action ledger 时不得自动提升。

## M0-10 Domain Model

- 生产源码位于 `BearObs/Domain` 并直接进入 App target；仓库根 `Package.swift` 只是复用同一
  源码和 XCTest 的 macOS host verification 接缝，不产生第二份实现或 App 运行时依赖；
- `VaultPath` 区分本地已解码和远端百分号编码入口，严格只解码一次，执行 NFC，拒绝绝对
  路径、空段、`.`、`..`、NUL、反斜杠及解码后穿越，Codable 不能绕过校验；
- `SyncPlanner` 显式区分 tracked、initialImport、conservativeRecovery；无可靠远端 revision
  或写前置条件时绝不上传，download/upload/removeLocal 均携带执行前 CAS；强 ETag 从完整
  单值响应头解析，远端内容身份与当前写保护条件分别建模；
- 无基线且双方存在时，只有已验证内容 hash 相同才建立基线，不同则冲突，未知则保守恢复；
- 相同 revision 却带来与基线矛盾的已验证 hash 时强制冲突；tracked 3×5 与恢复 3×4 决策矩阵
  逐格断言精确结果；
- 11 类统一错误各自唯一映射恢复动作；诊断只允许 operation、subsystem、numeric code 和
  correlation ID，不接受 URL、header、底层描述或正文；
- 22 个 host XCTest 全部通过，覆盖路径编码/Unicode/穿越、同步矩阵、账本恢复、CAS 和错误
  映射；Domain region coverage 98.89%、line coverage 99.44%，Xcode test bundle 编译和
  arm64 macOS 15 Release 交叉编译通过。

本地未安装 Simulator runtime 时，`make domain-model` 仍执行同一组纯领域 XCTest；完整 App
`make test` 继续要求 CI 或开发机安装与 `.xcode-version` 匹配的 macOS SDK。M0-10 不实现
WebDAV origin 映射、symlink-safe containment、I/O 执行器、账本或冲突副本生命周期。

## M1 Markdown 生产解析边界

- `BearObsMarkdown` 正式使用 `FrontmatterParseResult.bodyRange` 作为唯一正文边界；标准 AST 和
  Obsidian 扩展扫描不重复猜测 Frontmatter，也不改写原始字节；
- `ObsidianSyntaxScanner` 通过 AST UTF-8 source range 遮罩代码、标准链接目标、图片与 HTML，
  仅恢复标准链接的可见文本；排除范围无法安全映射时返回空扩展结果，禁止 fail-open 误索引；
- Inline Tag、Wiki Link 与 Embed 以 occurrence 建模，保留原始 source 和原笔记绝对 UTF-8
  半开 byte range；扫描保持线性，未闭合或跨行 bracket token 原文降级；
- `MarkdownNoteParser` 是唯一公开生产解析入口，输入为原始 `Data` 与已验证的 `VaultPath`；默认
  在 UTF-8/YAML/AST 分配前拒绝超过 1 MiB 的 note，并集中管理 64 KiB Frontmatter、2,048
  YAML nodes、32 层 YAML 深度、128 个 aliases、1,024 个 Frontmatter tags、10,000 个扩展
  语法 occurrence、4 KiB 单 token、1,024 个唯一标签和 200 个摘要 Character 的上限；
- Frontmatter byte cap 与 libyaml event 级 depth/node/alias 预算在 `Yams.compose` 前生效，预算
  直接消费真实 YAML events 并可在 Node 构造前中止；构树后仍以真实 Node 结构复核 node/depth。
  低层 Frontmatter、AST 和扩展扫描入口只保留模块内部可见性，外部调用者不能绕过统一限制；
- 标题事实源固定为非空 Frontmatter title、正文首个顶层 ATX H1、`VaultPath` 文件名 stem；摘要
  取标题后的首个顶层语义 Paragraph，保留可见文本并跳过 heading、image、code、HTML 与
  Embed，折叠空白后按 extended grapheme cluster 截断且不添加 UI 省略号；
- 标签按 Frontmatter 顺序再按 Inline Tag 源码顺序聚合；display 采用 NFC，identity 采用固定
  `en_US_POSIX` locale 的 Unicode case-insensitive folding 后再 NFC，首次形式获胜。聚合不得
  删除、重排或重算 A4 occurrence 及绝对 UTF-8 byte range；
- invalid/unclosed/resource-limited Frontmatter、extension range 与输出截断进入固定结构化
  diagnostic 并得到 `degraded`；超 note 大小和 invalid UTF-8 是 typed fatal error，不伪造
  部分 `ParsedNote`；
- M1-A5 新增 22 个 XCTest，SwiftPM 全量 77 测试通过；`MarkdownNoteParser.swift` region
  88.17%、line 95.08%，相关生产文件总 region 92.81%、line 96.53%。Xcode 26 未生成 Swift
  branch records，因此继续使用 region ≥ 80% 加显式分支矩阵；`make check` 与 macOS 15 Release
  交叉编译通过。本机未安装 Simulator runtime，Xcode scheme 的最终 build/test 重跑仍属于上文
  已记录的基础设施缺口；
- 扫描和聚合层仍不做路径解析、同名消歧、附件存在性、HTML 渲染或智能摘要；这些能力必须由
  后续索引、跳转和 Reader 消费层承担。

## M1 `index.sqlite` 生产迁移边界

- 正式 `BearObsIndex` 模块精确锁定 GRDB 7.11.1；统一数据库配置开启 SQLite foreign keys，
  避免调用者忘记连接级开关后让 schema 的级联约束静默失效；
- `v1_create_index_tables` 建立 notes、tags、note_tags、links 和 attachments：路径和标签身份为
  主键，关联表使用复合主键，笔记删除级联清理所有 occurrence；内容 hash、byte size、解析状态、
  link resolution、attachment cache state 和 UTF-8 半开 range 均由 CHECK 约束守住；
- Wiki Link 与 Embed 使用自增 occurrence ID，并以 note path 加 source start 唯一定位；同一 target
  在不同源码位置可重复存在，禁止在 schema 层错误去重或丢失 A4 的语法事实；
- `v2_create_note_fts` 建立 path、title、body、tags 四列 FTS5 表，path 不参与分词，tokenizer 固定
  为 `unicode61`；从 v1 升级时按稳定标签顺序回填已有 notes，重复打开不会重复创建或插入；
- B1 不实现 B2 的 upsert/delete 事务、B3 的 hash skip、B4 查询排序或 B6 中文质量决策；FTS 正文
  的持续更新仍必须由 B2 在与普通表相同的事务中完成；
- 7 个 XCTest 覆盖新库建表、真实磁盘重开幂等、v1→v2 `unicode61` 回填、v2 失败不误记、外键
  级联、非法状态/range 拒绝和重复 target occurrence 保真；`IndexSchema.swift` region/line 均为
  100%，SwiftPM 全量 84 测试、`make check` 和 arm64 macOS 15 Release 交叉编译通过；
- Xcode 已成功解析并锁定 GRDB，App 与 Unit Test targets 均完成项目接线。本机未安装可用的 Mac UI
  test destination，因此 scheme build/test 无法启动；该环境缺口不影响上述 host
  测试和 macOS SDK 交叉编译证据。

## M1 `index.sqlite` 生产索引与搜索边界

- 单笔记写入、失败降级、删除、普通 FTS 与中文 FTS 必须处于同一 SQLite 事务；任何 occurrence
  约束失败都回滚整篇笔记，禁止留下新 notes 配旧 FTS 的撕裂状态；
- `v5_create_note_diagnostics` 保存固定结构化诊断码；degraded 与 fatal 解析结果都保留诊断，但
  不保存任意错误文本、堆栈或额外正文；
- 本地读取继续使用 descriptor-relative `openat`、`O_NOFOLLOW` 和稳定读取前后 `fstat`，读取时
  流式计算 SHA-256；超过解析上限的内容只保留 hash 和安全文件名，不把整份超限正文留在内存；
- 增量扫描先比较 path、size、mtime，再对可疑项比较 hash；hash 不变只刷新文件属性，删除项仅在
  完整枚举成功后清理，避免一次根目录读取失败被误判成“全部删除”；
- 查询长度上限 256 字符、limit 为 1...100，用户内容只通过参数绑定进入 SQL；普通 FTS 的 bm25
  权重固定为 title 10、tags 5、body 1，空查询按 modified_at 倒序；
- `v3_upgrade_occurrence_metadata` 兼容升级已经执行过 B1 的数据库，重建 note_tags/links 并保留
  旧 occurrence；`v4_create_cjk_note_fts` 从普通 FTS 流式回填汉字 unigram+bigram。中文语料
  6 个正向查询的召回率由裸 `unicode61` 的 2/6 提升为 6/6；2 个负向组合查询无测得误匹配。
  10,000 篇合成笔记查询 P95 0.808 毫秒，中文 FTS 页占用为普通 FTS 的 3.44 倍；纯汉字查询
  使用 phrase 匹配，防止相邻 bigram 分散命中的假阳性。完整决策见 ADR-008；
- 全量重建在单个写事务内逐篇读取、解析和插入，峰值内存按单篇 note 上限有界。注入 rebuild
  trigger 失败时旧 notes、occurrence 和双 FTS 保持完整可用；重建永不修改 `sync.sqlite`、
  Markdown 字节或用户状态；
- M1-B2 至 B6 共新增 24 个索引/文件读取测试；SwiftPM 全量 108 测试通过，全量生产源码
  region 92.44%、line 96.83%；`make check` 与 arm64 macOS 15 Release 交叉编译通过。

## M1-C1 Library 只读边界

- `IndexLibraryRepository` 只暴露不可变 `IndexedNoteSummary`，稳定按修改时间倒序和 path 排序；
  parse status 在仓储边界转换为闭合枚举，UI 不接触 GRDB row 或任意诊断文本；
- `LibraryDataSource` 分离读取和刷新端口；`LibraryFeatureModel` 仅拥有互斥界面状态与用户意图，
  刷新失败保留旧列表，取消恢复稳定状态，后发 operation 阻止慢的旧结果覆盖新内容；
- SwiftUI Library 使用原生 NavigationStack、List 和 ContentUnavailableView，展示标题、摘要、
  相对修改时间以及带图标和文字的降级/失败状态；加载、索引、空态和错误都有独立可访问标识；
- C1 新增 7 个仓储/Feature Model 测试，SwiftPM 全量 115 测试通过；包含声明式 SwiftUI View 的
  全量生产源码 region 86.31%、line 89.05%，排除纯布局后的核心逻辑 region 92.13%、line 96.87%。
  App 壳纳入独立 SwiftPM executable target，host 编译与 arm64 macOS 15 Release 交叉编译通过；本机
  缺可用的 Mac UI 测试 destination，Xcode UI build 在编译前被 destination 检查阻断，
  未把该基础设施缺口记为源码通过。

## M1-C2 标签导航边界

- `IndexTagRepository` 在 index.sqlite 内聚合标签稳定展示名和 note count，按标签读取继续返回
  `IndexedNoteSummary`，使用参数绑定并复用 modifiedAt/path 稳定排序；
- 标签列表和标签笔记页各自使用闭合状态枚举。刷新失败保留旧标签并显示固定提示，取消恢复旧状态，
  operation ID 阻止慢的旧查询覆盖新结果；UI 不重新解析标签，也不直接读取 Markdown；
- App 壳使用 macOS 原生 `NavigationSplitView` 固定“主侧边栏导航与标签树—笔记列表—详情”三栏；
  标签直接在最左侧可折叠树中选择，标签结果复用中栏笔记摘要列表，不进入独立标签页；状态不只依赖颜色，
  空态和错误均提供明确文字；
- C2 新增 7 个仓储/Feature Model 测试，SwiftPM 全量 122 测试通过；包含两个声明式 SwiftUI View
  的全量生产源码 region 83.77%、line 85.66%，排除纯布局后的核心逻辑 region 92.00%、line
  96.95%；`make check` 与 arm64 macOS 15 Release 交叉编译通过。

## M1-C3 搜索和摘要边界

- `SearchDataSource` 只暴露一个异步查询端口；Feature Model 与 SwiftUI 不接触 GRDB、SQLite 或
  FTS 语法，空查询和普通/CJK 查询继续复用 B4/B6 已验证的仓储语义；
- 搜索结果只包含不可变摘要和闭合 parse status，不加载 Markdown 正文。loading、content、empty、
  failure 为互斥状态，operation ID 阻止旧查询覆盖新输入，结构化取消恢复上一个稳定状态；
- App 壳新增原生 Search Tab，使用 searchable、List 和 ContentUnavailableView；底层错误不透传，
  降级状态同时使用文字和图标。结果打开 Reader 明确保留给 C4；
- C3 新增 3 个 Feature Model 测试，SwiftPM 全量 125 测试通过；全量生产源码 region 81.86%、line
  83.27%，排除三个纯声明式 SwiftUI View 后核心逻辑 region 91.77%、line 96.91%，Search Feature
  Model line 97.14%；10,000 篇中文合成语料本轮查询 P95 0.831 毫秒；arm64 macOS 15 Release
  交叉编译通过。

## M1-C4 Markdown Reader 边界

- `ReaderDataSource.localVault` 按规范 `VaultPath` 调用现有 descriptor-relative 文件读取，并在独立
  actor 上完成稳定读取、统一 Markdown 解析和渲染模型转换；View 不读取 SQLite 或文件字节；
- `MarkdownRenderDocument` 是闭合、不可变、Sendable 的 block/inline 值，覆盖标题、段落、强调、
  粗体、删除线、列表、任务列表、引用、行内/块代码和标准链接；HTML、未知节点及尚未进入 C5
  的 Obsidian 跳转语法只显示为文本；
- 仅无凭据的 HTTP/HTTPS 和有效 mailto 保留点击动作；自定义 scheme、相对目标和含 user/password
  的 URL 降级为不可点击文本。Reader 底层失败不透传，取消恢复稳定内容，旧加载不能覆盖新结果；
- Library、Tags、Search 三个入口均按 path 导航到 Reader；C4 新增 6 个渲染、状态、真实本地适配
  和 SwiftUI 离屏渲染测试，SwiftPM 全量 132 测试通过；全量生产源码 region 80.81%、line 81.56%，
  排除四个纯声明式 View 后核心逻辑 region 90.46%、line 96.47%；10,000 篇中文检索本轮 P95
  0.806 毫秒；`make check` 与 arm64 macOS 15 Release 交叉编译通过。

## M1-C5 Wiki Link 跳转边界

- `IndexWikiLinkRepository` 在一次扫描或重建结束后，以当前 notes 路径集合批量解析所有 link
  occurrence；顺序固定为显式 Vault 路径、源笔记目录、Vault 根和唯一文件名。同名多候选标记
  ambiguous，缺失和非法 target 标记 missing，任何状态都不在 View 层重新猜测；
- 解析状态和 `resolved_path` 使用参数绑定写回 SQLite。逐篇 replace 只写 unresolved occurrence，
  避免首次扫描形成逐篇全表归一的平方级写放大；
- Reader 使用原笔记绝对 UTF-8 半开 range 合并 scanner occurrence 与索引结果；范围或源文本不一致
  时保留原文。resolved link 只携带已验证 `VaultPath`，missing、ambiguous、unresolved 只显示别名或
  target，不创建动作；
- 内部路由严格限定 `bearobs://note?path=...` 的单一形状，拒绝凭据、端口、额外参数、fragment
  和所有不合法 Vault path；普通 HTTP/HTTPS/mailto 仍遵守 C4 的外部链接白名单；
- C5 新增 7 个仓储、渲染、路由和真实扫描到 Reader 集成测试，SwiftPM 全量 139 测试通过；全量
  生产源码 region 81.20%、line 82.56%；10,000 篇中文检索本轮 P95 0.836 毫秒；`make check`、
  Xcode 工程解析、pbxproj 校验和 arm64 macOS 15 Release 交叉编译通过。本机仍无可用 macOS UI 运行环境
  runtime，因此没有伪报模拟器测试。

## M1-C6 收藏与最近内容边界

- 收藏事实只保存在当前本地 Vault 的 `Metadata/user-state.json`，由 `FileUserStateStore` actor
  通过同目录临时文件、`fsync` 和单次 `rename` 原子提交；索引重建、扫描和删除绝不修改收藏状态，
  stale path 只在展示层与当前索引求交，不做静默迁移或清理；
- `AppEnvironment` 是生产组合根，按固定的 `Application Support/BearObs/Vaults/default/`
  布局创建 `Files/`、`Metadata/`，并将 `LocalVaultStore`、`SQLiteIndexRepository`、
  `IncrementalIndexScanner`、`FileUserStateStore` 组装到 Library、Tags、Search、Favorites、Recent
  和 Reader 的应用端口；索引首次读取由一个 actor 门控扫描，避免最近/收藏读取看到尚未建立的空索引；
- 所有入口共享同一个 `FavoritesFeatureModel`。Reader 首次进入并行加载正文和持久化收藏状态，
  状态未就绪或更新中禁用星标；底层写失败只映射固定文案并保留旧内存状态。并发旧写入完成后按
  最新用户意图补偿一次底层幂等写，确保 UI 与磁盘最终一致；
- 最近页不新增数据表或缓存，空查询直接复用 `SQLiteIndexRepository.search("")` 的
  `modified_at DESC, path` 稳定排序；收藏页只展示索引中仍存在的收藏，Reader、Wiki Link 递归导航
  始终沿用同一 favorites 模型和 reader source；
- C6 SwiftPM 全量 176 测试通过，包含持久化收藏、Reader 首次加载、双向星标、失败恢复、并发旧写入
  补偿以及 Favorites/Recent/Library/Reader 离屏渲染；`swift-format lint --strict`、`git diff --check`、
  pbxproj 校验和 arm64 macOS 15 Release 交叉编译通过。

## M1-C7 可访问性自动化边界

- Library 与 Search 摘要行在普通字号维持紧凑横向标题/日期，在辅助功能字号切换为纵向并取消
  标题和摘要截断；Tags 名称与计数同样在辅助功能字号强制纵向，避免压缩后仍被错误判定为可用布局；
- Reader Markdown 标题同时暴露 header trait 和 H1-H6 heading level，引用竖线与分隔线从
  VoiceOver 树隐藏；不得把可能包含 URL/Wiki Link 的列表正文合并为静态元素，必须保留内部链接动作
  和横向代码滚动语义；
- 收藏按钮分别朗读“正在读取收藏状态”“正在更新收藏状态”“收藏”“取消收藏”，并提供添加/移除
  hint；Tag 行使用单一“名称，N 篇笔记”标签。失败和解析状态正文使用系统 primary，橙/红/黄只
  强化图标，任何状态都不只依赖颜色；
- 自动化矩阵在 390x844、Dynamic Type AX5 下分别渲染 light/dark 的 Library、Search、Tags 和
  Reader 内容，并固定收藏/标签朗读文案契约；macOS UI 自动化 以 AX5 + Dark 启动并检查三个 Tab 可操作。
  ImageRenderer 只证明布局可生成，不等价于无截断、对比度审计或 VoiceOver 可操作性验收；
- M1-C7 只有在可用 macOS UI 运行环境上人工走查主导航、Reader heading、标准/Wiki Link、
  引用、任务列表、收藏按钮和代码横向滚动后才能标记完成。当前机器缺可用 Simulator runtime，
  因此本节记录自动化完成，人工验收仍开放。

## 依赖与配置

- 当前 App target 第三方运行时依赖为 GRDB 7.11.1、swift-markdown 0.8.0、Yams 6.2.2，
  以及 swift-markdown 传递依赖 swift-cmark 0.8.0。
- 格式检查使用 Xcode 工具链自带的 `swift-format`，版本随 Xcode 26.5 一并锁定。
- 后续 Swift Package 必须使用稳定版本约束并提交 `Package.resolved`；禁止 branch 依赖。
- swift-markdown、Yams 和 GRDB 已分别在 M1 正式 parser 与索引边界链接 App target。
- `Config/Secrets.xcconfig`、`.env*` 和构建产物被忽略。源码和普通配置不得存放凭据。
- WebDAV 凭据未来只进入 Keychain；CI 凭据只进入 CI secret store。
- 零依赖静态检查覆盖常见云端、GitHub、Slack、OpenAI、私钥和认证头模式，并同时扫描
  当前工作树与所有 Git revisions；输出只报告命中，不回显可能的秘密。

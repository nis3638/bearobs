# REQ-004 iOS 完整测试与验收方案

日期：2026-10-25。范围：iOS 只读内部 P0，以及共享改动引起的 macOS 回归。

关联：[待开发清单](REQ-004-ios-development-backlog.md) · [原需求](REQ-004-ios-read-only-client.md) · [本次执行报告](REQ-004-ios-test-report-2026-10-25.md)。

## 1. 测试口径

本文件是完整验收规格，不是通过报告。下表均为必须检查的案例；已有实现或已有同等单测可复用，但必须记录实际执行目标、结果和证据。新增 UI 测试由 zcode 按开发清单补齐。

- U：单元/纯状态；X：跨模块集成；UI：XCTest App 交互；M：真机人工；G：构建/静态门禁。
- PASS：实际环境执行且全部断言成立；FAIL：执行且断言失败；BLOCKED：缺 runtime/硬件/授权等外部条件；NOT RUN：未执行。skip 不能记 PASS。
- UI 自动化使用合成 fixture；等待可观察状态，不依赖固定 sleep。失败保存 `.xcresult`、相关日志/截图；重试不掩盖首次失败。
- 边界和故障主要在 U/X 确定性注入，关键成功/失败链路进入 UI；不为每个纯函数再造 UI 测试。
- 新行为先失败测试再最小实现。发现旧测试表达错误时先说明契约依据，不为通过而削弱断言。

## 2. 环境与数据

### 2.1 环境矩阵

| 环境 | 必测范围 | 证据限制 |
|---|---|---|
| iPhone 模拟器 iOS 26.0 | 共享核心、全部紧凑 UI、最低系统兼容 | 2026-10-25 本机未安装，需其它环境或补 runtime |
| iPhone 模拟器当前安装版本 | 同上；本次为 26.5 | 不可替代 26.0 |
| iPad 模拟器 26.0/当前安装版本 | 真实有 Vault 的常规宽度业务 suite | 空态启动只算冒烟 |
| iPhone 真机，记录型号/系统 | 真实 picker、授权、重启、iCloud、VoiceOver | 开发签名；不可用模拟导入代替 |
| iPad 真机，记录型号/系统 | 三栏、真实分屏、宽度切换、旋转、状态恢复、可访问性 | DEBUG 强制 size class 不是分屏证据 |
| macOS host，记录实际版本 | 共享核心、既有全部 UI、编辑与原子保存回归 | iOS 改动不能破坏 Mac |

### 2.2 合成 fixture

复用 `BearObsTests/Fixtures/GoldenVault` 与 `ChineseSearchVault`；扩展数据应放在现有 fixtures/test support 结构内，不复制一份生产解析器。

| fixture | 内容与用途 |
|---|---|
| Local-A / Local-B | 同名路径不同正文、互不相同标签/收藏；验证隔离，不使用真实笔记 |
| Navigation | 至少 60 篇可区分标题的笔记，可滚动到中部；源→目标→第三篇链接链 |
| Tags | `project`、`project/mobile`、`other/mobile`；仅存在子标签时的隐式父节点；40 个以上长标签 |
| Reader | 标题、强调、段落、列表、任务、引用、代码、合法外链；缺失/歧义/非法 Wiki Link；图片/embed/HTML 等安全降级 |
| Encodings | Unicode/emoji、组合字符、空格、字面 `%`、BOM、LF/CRLF、无效 UTF-8、无效 Frontmatter |
| ReadOnly | 普通笔记、附件二进制、隐藏 `.obsidian` 配置、非 Markdown 文件及空目录；可选 symlink（不追踪） |
| Availability | 通过现有端口注入临时不可读、恢复、数据库失败、取消、快照缺失/损坏、收藏写失败 |
| iCloud | 同内容合成副本：下载完成、未下载占位；先确认实际 provider 状态，再断网测试 |

本地完整清单在 Vault 外保存，比较全部项类型、相对路径、文件字节哈希、链接目标；禁止遗漏隐藏文件和附件。不以 atime 变化判失败。iCloud 的下载和系统元数据由 provider 管理，必须单列，不将其误报为 App 写文件。

### 2.3 每个测试的公共前后置

1. 独立 App support 根目录和合成 Vault；确认目标系统/设备及宽度。
2. 保存操作前完整只读清单；需要变更源文件的用例由测试夹具执行，并记录允许差异。
3. 执行业务操作，断言可见结果和持久化结果；重启场景明确关闭/再启动或实际系统回收条件。
4. 等待持久化完成，再比较清单。允许写 App 索引、快照、收藏及选择状态，禁止其进入 Vault。
5. 记录版本/工作树、案例编号、实际结果、失败原因和证据，再清理测试自己的目录。

## 3. 当前 iPhone UI 测试清点

文件：`BearObsIOSUITests/BearObsIOSUITests.swift`。映射表示已有部分断言，不表示覆盖同组全部案例。

| 现有方法 | 已有断言 | 仍需补充 |
|---|---|---|
| `testLibraryEmptyStateLaunches` | 无 Vault 空态入口 | 非三栏业务验收 |
| `testSeededVaultOpensAndTheReaderStaysReadOnly` | 自动注入目录、读笔记、返回、无编辑按钮 | 真 picker 完整选择、全部文件清单、列表位置 |
| `testCompactTabsExposeTheFixedEntries` | 五 Tab 存在 | 每个 Tab 的导航与状态 |
| `testOpenedVaultExposesHittableOpenVaultAction` | 点击入口出现系统 picker | 真机选择成功/取消/授权恢复 |
| `testSwitchingVaultsKeepsIndexesAndFavoritesIsolated` | A→B 隔离、B 重启、Markdown 字节 | SceneStorage 恢复字段交错、非 Markdown/隐藏项 |
| `testFailedVaultSwitchKeepsTheCurrentAndPersistedWorkspace` | 缺失目录切换失败、旧 Vault 重启恢复 | 准备/持久化失败跨层矩阵 |
| `testInvalidSavedBookmarkFallsBackToTheSelectionPrompt` | 损坏书签安全提示 | 真授权失效/陈旧书签 |
| `testTagListScrollsToLastNestedTagAndExposesItsCount` | 长标签滚动、计数、子标签精确筛选、刷新 | 父→子反向排除、同尾段标签、真实 VoiceOver |
| `testSearchFavoriteAndRelaunchKeepVaultBytesUnchanged` | 正文单词查询、收藏重启、Markdown 字节 | 标题/标签/中文、取消收藏/失败、全部文件 |
| `testResolvedWikiLinkNavigatesToTheTargetReader` | Alias 单跳 | 连续跳转/逐级返回、无效链接、外链 |
| `testCompactWorkspaceRemainsOperableAtLargestTypeInDarkMode` | 最大字号深色、部分入口可点击 | 全部操作、浅色、iPad、VoiceOver |

## 4. 逐项测试矩阵

### 4.1 Vault 选择与恢复（V）

| ID | 层级 | 步骤/输入 | 必须断言 |
|---|---|---|---|
| V-01 | UI/M | 全新启动，无保存选择 | 显示打开入口和说明，不显示错误、不假装空 Vault |
| V-02 | UI/M | 真实 picker 选择本地合成目录 | 建索引后可读；重启恢复相同 Vault；清单不变 |
| V-03 | U/UI/M | 空态/已打开状态取消 picker | 无错误提示；旧入口/工作区/选择文件不变 |
| V-04 | U/X/UI | picker 真失败、非法/不可访问 URL | 固定可理解文案，不暴露路径；旧工作区仍可用 |
| V-05 | U/UI/M | 书签缺失、损坏、过期/失权 | 缺失正常引导；异常安全回选择/提示；无崩溃 |
| V-06 | U/X/M | 陈旧书签能重新解析 | 在合法 scope 中刷新并保存；下次可恢复；失败保留一致状态 |
| V-07 | X/UI | A→B 同名笔记和不同收藏/标签，重启 | 索引/收藏/恢复目标不串 Vault；B 首次默认入口正确 |
| V-08 | U/X/UI | B 准备失败或选择保存失败 | 内存和磁盘仍指向 A；临时 B 派生数据正确清理 |
| V-09 | U/X | 再选当前已打开目录 | 保持已有身份和当前状态；不重建无意义的第二工作区 |

### 4.2 iPhone 导航（N）

| ID | 层级 | 步骤/输入 | 必须断言 |
|---|---|---|---|
| N-01 | UI | 逐一进入五 Tab | 职责对应；没有写操作入口；每个入口可打开 Vault |
| N-02 | UI | 各列表滚至中部→阅读→返回 | 原滚动锚点、查询和筛选保留，不意外回顶 |
| N-03 | UI | 同一笔记读→返回→再次点开 | 每次均能进入，选择状态不阻断第二次打开 |
| N-04 | UI | 搜索/标签阅读中切 Tab，再返回 | 无串列表/错 Reader；独立导航栈行为稳定 |
| N-05 | UI | 标签树→标签列表→Reader→逐级返回 | 回到正确标签列表/标签树，保留选择与滚动 |
| N-06 | U/UI | 加载/索引中/空/失败/旧内容可用状态 | 按共享状态机互斥呈现；支持降级的入口保留旧内容/警告；查询失败不把上一查询结果冒充当前结果 |
| N-07 | UI/M | 阅读或索引期间退后台再回前台 | 当前 Vault 和导航可用，未卡死、无错误内容 |

### 4.3 搜索与标签（S）

| ID | 层级 | 步骤/输入 | 必须断言 |
|---|---|---|---|
| S-01 | U/X/UI | 标题、正文、标签、中文词、Unicode 查询 | 命中集合正确，无其它 Vault 结果；沿用现有搜索契约 |
| S-02 | U/X/UI | 空查询/纯空白→最近入口 | 最近按修改时间降序、同时间路径稳定排序；不是阅读历史 |
| S-03 | U/UI | 零命中、清空查询、取消、快速换词 | 空态明确；新请求胜出，晚返回旧结果不能覆盖新结果 |
| S-04 | U/X/UI | 分别选择 `project` 与 `project/mobile` | 双向精确匹配；父不含仅子标签，子不含仅父标签 |
| S-05 | U/UI | `project/mobile` 与 `other/mobile`；隐式父节点 | 完整身份无混淆；隐式父只是分组，计数与选择语义正确 |
| S-06 | UI/M | 长标签/40+标签/最大字号，刷新失败→恢复 | 末项可达、完整层级和计数可读；旧内容保留且可重试 |

### 4.4 Reader 与链接（R）

| ID | 层级 | 步骤/输入 | 必须断言 |
|---|---|---|---|
| R-01 | U/X/UI | Reader fixture 全部标准块 | 标题/强调/段落/列表/任务/引用/代码按共享契约显示；任务不可写回 |
| R-02 | U/X/UI | `[[Note]]`、Alias、显式路径与 Unicode 目标 | 跳到正确笔记，不二次 URL 解码或串同名文件 |
| R-03 | UI | 源→目标→第三篇，再逐级返回 | 栈顺序和正文正确，最后回原列表及筛选位置 |
| R-04 | U/UI | 缺失/歧义/非法 Wiki Link、伪造 internal route | 不跳错目标，以安全原文/不可用形式呈现；无越界访问 |
| R-05 | U/UI/M | HTTPS 外链及不支持语法/HTML/embed/图片 | 合法外链交系统；不执行不安全内容；未支持语法按共享契约降级，不要求附件渲染 |

### 4.5 收藏（F）

| ID | 层级 | 步骤/输入 | 必须断言 |
|---|---|---|---|
| F-01 | U/UI | Reader 收藏→收藏列表→取消 | 即时反馈，两处状态一致；取消最后一项显示空态 |
| F-02 | X/UI/M | 收藏落盘→退出重启 | 当前 Vault 收藏保持；不依赖先访问收藏 Tab |
| F-03 | U/X/UI | 写失败、取消、快速连续切换 | 保留最后稳定状态/固定错误；取消不误报；晚完成不覆盖新状态 |
| F-04 | X/UI/M | A/B 同名路径、Mac 与 iOS 同份内容 | 本机用户状态相互独立；不在 Vault 新建状态文件 |

### 4.6 索引、缓存、恢复（I）

| ID | 层级 | 步骤/输入 | 必须断言 |
|---|---|---|---|
| I-01 | U/X/UI | 首次打开，受控挂起首次扫描 | 显示索引中且只启动一次扫描；完成后才发布内容/空态 |
| I-02 | U/X | 未变化/mtime变但hash同/正文变/外部删除 | 跳过不必要解析；正确更新；仅完整可信枚举才协调删除 |
| I-03 | U/X/UI | 全量与增量中单文件暂不可读 | 其它文件继续；旧项保留、新项跳过；匿名计数和陈旧提示正确 |
| I-04 | U/X/UI | 源不可读但有匹配哈希快照 | 展示正确缓存正文及警告；只使用匹配索引的快照 |
| I-05 | U/X/UI | 无缓存/损坏缓存/不可读新文件 | 明确暂不可用；不显示空正文冒充成功，不串其它缓存 |
| I-06 | U/X/UI | 源恢复、正文已变化，重试/刷新 | 转回实时正文；更新索引/快照，清除旧警告和计数 |
| I-07 | U/X | 全量重建/增量扫描取消、数据库失败、根/目录错误 | 全量事务回滚；增量允许保留已提交文件但单文件 note/tags/FTS 一致；错误不吞为成功，下次可恢复 |
| I-08 | U/X/UI | 五入口逐一刷新不可用→恢复 | 共用可用性状态及时更新；旧内容保留，无内容时提供重试 |

### 4.7 错误、数据边界（E）

| ID | 层级 | 步骤/输入 | 必须断言 |
|---|---|---|---|
| E-01 | U/X | 遍历、符号链接、目录伪装笔记、非法百分号路径 | 服从 VaultPath/LocalVault 契约，不越根、不跟随不可信链接 |
| E-02 | U/X | 无效 UTF-8/Frontmatter、BOM、LF/CRLF | 安全降级/固定失败；不崩溃、不修改输入字节 |
| E-03 | U/X/UI | App 状态目录不可写、选择/收藏写失败 | UI 与持久化一致；错误不泄露系统路径/正文等私有信息 |
| E-04 | U/X | 快照目录/文件替换、损坏与写失败 | 沿用现有 no-follow/身份检查；不污染主索引，恢复后可自愈 |

### 4.8 iPad（三栏、恢复、宽度）（P）

| ID | 层级 | 步骤/输入 | 必须断言 |
|---|---|---|---|
| P-01 | UI/M | 常规宽度加载非空 Vault | 导航—列表—详情职责清晰，三栏可实际完成操作 |
| P-02 | UI/M | 各入口/标签筛选、选笔记、Wiki Link、收藏 | 列表/详情正确更新，入口不跳错栏，无布局失稳 |
| P-03 | M | 从常规宽度进入系统实际判定为 compact 的分屏，再展开 | 宽度对应五入口/三栏；无空白、错内容、不可达操作；不假设所有分屏比例都为 compact |
| P-04 | UI/M | 选标签/笔记→退后台→关闭重启 | 按 REQ-004 恢复上次目的地/选中笔记；记录实际生命周期条件 |
| P-05 | U/X/UI | A 留目的地/路径→切 B→仅选 B 笔记→重启 | B 不继承 A 的目的地；三个恢复字段属于同一状态 |
| P-06 | U/X/UI | A 留路径→切 B→仅改 B 入口→重启 | B 不显示 A 同名/旧路径内容；不混拼恢复字段 |
| P-07 | U/X/UI | 无效 restoration ID、删除已选标签/笔记 | 确定性回默认/空详情；无循环恢复/越界选择 |
| P-08 | UI/M | 三栏最大字号、长列表/标题、开关侧栏 | 栏位职责稳定、内容可达，不依赖像素位置断言 |
| P-09 | M | Reader、搜索及 picker 打开期间旋转/收窄/展开 | 当前 Vault 一致、可继续操作；状态符合既有导航契约 |

### 4.9 真机与 iCloud（D）

| ID | 层级 | 步骤/输入 | 必须断言 |
|---|---|---|---|
| D-01 | M | 开发签名真实安装→picker 选择本地文件夹 | 非测试注入；授权范围内能索引/读/搜，清单不变 |
| D-02 | M | 进程退出/系统回收后再启动；本地与 iCloud 各一次 | 书签恢复可用；失效时安全提示；不能只用后台切回代替 |
| D-03 | M | iCloud 下载完成→索引/缓存完成→断网 | 已缓存笔记读/搜可用；收藏仍本地持久化 |
| D-04 | M | 未下载占位文件、无缓存→断网打开 | 固定不可用提示；其它可用笔记继续，不能保证未下载正文可读 |
| D-05 | M | 含占位文件索引→网络恢复并下载→刷新 | 不误删旧索引，恢复实时正文和诊断；记录 provider 可观察状态 |
| D-06 | M | 目录移动/撤权/不可用后重启或重选 | 安全回选择/保留旧稳定状态；无崩溃或路径泄露 |
| D-07 | M | 真 picker 切 A→B、取消、失败，再重启 | 与 V-03/V-07/V-08 同契约；下载元数据和内容字节分别记录 |

### 4.10 可访问性与外观（A）

| ID | 层级 | 步骤/输入 | 必须断言 |
|---|---|---|---|
| A-01 | UI/M | 普通/最大辅助字号 × 浅/深色，核心链路 | 所有入口/列表/Reader/错误/收藏可达，文本可滚动，无遮挡 |
| A-02 | M | 真 VoiceOver 从选 Vault 到 Reader/返回 | 焦点顺序合理；按钮有可理解名称；状态变化可获知 |
| A-03 | U/M | 标签父子、计数、长路径、选中态 | 朗读完整身份和数量；不只依赖颜色区别选中 |
| A-04 | U/M | Wiki Link/外链、收藏切换与失败提示 | 目标和动作语义可理解，无无名或不可操作控件 |
| A-05 | M | iPad 三栏和实际 compact 分屏重复 A-01～04 | 不把 iPhone/离屏渲染结果当作 iPad 或 VoiceOver 通过 |

### 4.11 只读、隔离与交付门禁（Q/B）

| ID | 层级 | 步骤/输入 | 必须断言 |
|---|---|---|---|
| Q-01 | X/UI | 遍历五入口、阅读、收藏、链接、刷新 | 全 Vault 清单不变，包含隐藏项、附件和非 Markdown |
| Q-02 | X/UI | 首次索引、重启、切换/切换失败、错误恢复 | 零新增/删除/改名/字节修改；派生物全在 App 目录 |
| Q-03 | G/UI | iOS 源成员/编译守卫 + 实际产品入口 | 编辑 UI 不进 iOS；无编辑、新建、删除、重命名、上传入口 |
| Q-04 | M | 真机完整链路前后清单 | 验证覆盖全部内容；iCloud provider 下载变动单列 |
| Q-05 | U/X | 人为变更 fixture 附件/隐藏文件/新增/删项 | 清单检查器必须逐种检出，避免“检查器通过但漏测” |
| Q-06 | G | 人为破坏 target 成员/编译守卫 fixture | 门禁能拒绝违规且不误杀合法共享模块 |
| B-01 | G | 固定 Xcode/SDK/依赖，记录 HEAD 与工作树 | 满足项目基线；接缝清单/schema 规范差异已核对；不浮动升级依赖替代修复 |
| B-02 | G | Mac+iOS Debug/Release 与无签名设备归档 | 编译零 error/warning；设备归档含图标和应用隐私清单 |
| B-03 | U/X/UI/G | Mac 全量现有测试与单测覆盖率 | 编辑、原子保存、导航等无回归；新共享源文件成员完整 |
| B-04 | U/X/UI/G | iOS 两 runtime × iPhone/iPad 适用 suites | 实际执行版本与设备明确；缺环境 fail/blocked，不能悄悄降级 |
| B-05 | G | 核心/变更覆盖率，真实 PR base | 四项 ≥80%；拒绝 0/0；subrange 明示为代理而非真实分支 |
| B-06 | G | 格式、秘密模式/历史、脚本自测、部署目标校验 | `make check` 成功；新门禁失败路径有自测 |
| B-07 | G | CI 缺指定 runtime/缺报告/测试失败 fixture | 明确非零退出，不能只生成“成功”文本 |
| B-08 | G/M | Release 包在测试环境变量存在时启动 | DEBUG 测试导入/强制布局接缝不生效；真实文件选择仍工作 |
| B-09 | G | 干净 checkout 全套 `make ci` | 源版本/比较基线/退出码/完整报告可追溯，人工缺口单列 |

### 4.12 性能和资源回归（T）

不新增未经确认的耗时承诺。PRD NFR-03 以 macOS 为目标，不能直接套为 iOS 发布时限；iOS 项目先记录基线，只有实际卡死、内存失控或明显回退才阻断并建缺陷。

| ID | 层级 | 步骤/输入 | 必须记录/断言 |
|---|---|---|---|
| T-01 | X/M | GoldenVault 256 小文件 + 1 MiB，重复首扫/增量/阅读 | 耗时、峰值内存和界面可响应；无正文全量长期驻留 |
| T-02 | X/M | 可复现生成 10k profile（独立于小 fixture） | 首扫/重启/搜索 P50/P95/峰值内存；不能以 256 文件冒充 10k |
| T-03 | X/M | 连续切换 Vault、搜索/开关 Reader/旋转 | 无持续资源累积或死锁；中断后可恢复操作 |

## 5. 需求到案例映射

| 验收标准 | 案例族 |
|---|---|
| AC-REQ-004-01 选择与恢复 | V、I、D、Q |
| AC-REQ-004-02 紧凑导航 | N、Q-03 |
| AC-REQ-004-03 阅读与跳转 | R、I-04～06、N-02/N-05 |
| AC-REQ-004-04 搜索与标签 | S、I-08 |
| AC-REQ-004-05 收藏 | F、E-03、Q |
| AC-REQ-004-06 iPad 三栏 | P、D、A-05 |
| AC-REQ-004-07 可访问性与外观 | A、N-06、S-06、P-08 |
| AC-REQ-004-08 平台隔离 | Q-03/Q-06、B |

## 6. 执行命令与证据

从仓库根目录顺序执行，避免并发 Xcode 测试争用同一 `.build/DerivedData` / `.xcresult`。

```bash
make check
make build
make test
make test-ios
make coverage
```

完整工程门禁（额外包含 GRDB/Markdown/Atomic Write Spike 和 Domain 冻结验证）：

```bash
make ci
```

指定最低 runtime；当前版本运行则明确设成实际安装版本，不称“最新系统”：

```bash
CI_IOS_RUNTIME=26.0 make test-ios
CI_IOS_RUNTIME=26.5 make test-ios
```

在干净 checkout/PR 上使用真实 Git 比较基线以获得有效变更文件分母：

```bash
COVERAGE_BASE_REF=<真实基线提交> CI_IOS_RUNTIME=26.0 make test-ios
```

尖括号内容是待替换值，不可原样执行。`make build-ios` 当前等同双平台 `make build`，不是独立更轻的构建。

无签名设备归档用于检查设备目标和资源，不能替代真机安装。固定工具链后，从仓库根目录执行（目录名按本轮唯一编号替换，避免覆盖已有证据）：

```bash
env -u __CFBundleIdentifier -u LaunchInstanceID xcodebuild \
  -project BearObs.xcodeproj -scheme BearObsIOS \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .build/DerivedData \
  -disableAutomaticPackageResolution \
  -archivePath .build/archives/REQ-004-ios-unsigned.xcarchive \
  CODE_SIGNING_ALLOWED=NO archive
```

归档后检查 `Products/Applications/BearObs.app/Info.plist` 的最低版本/设备族，确认 `Assets.car`、iPhone/iPad 图标与应用级 `PrivacyInfo.xcprivacy` 存在且隐私清单可解析。归档成功只关闭 B-02 的构建/资源部分，不关闭 D 组真机案例。

`test-ios.sh` 当前会清理同名结果，因此切换 runtime 前先复制结果到独立归档目录。不要让后一次结果覆盖前一次证据后声称两版本均通过。

证据位置：`.build/TestResults/Tests.xcresult`、`Coverage.xcresult`、`iOS-All.xcresult`、`iOS-iPad-Regular.xcresult`；`.build/reports/coverage-ios*`、`ios-destinations.txt`、`ios-ipad-layout-gate.txt`。新增 iPad suite 后应同步修正报告名称/描述，准确说明覆盖范围。

如需开发签名包，条件具备后执行 `DEVELOPMENT_TEAM=<实际团队ID> make dist-ios`；不将签名、真机安装、TestFlight 或 App Store 审核写成模拟器构建结果。

## 7. 人工操作脚本与报告模板

### 7.1 本地/授权

1. 在系统 Files 中准备合成 Vault A/B；启动开发签名 App，不设置测试导入变量。
2. 从真实 picker 选择 A，逐一浏览五入口、搜索中文、连续 Wiki 跳转、收藏并返回。
3. 退出再启动，检查选择和收藏；iPad 同时检查目的地/笔记恢复。
4. 选择 B，验证无 A 内容/收藏；取消另一次选择，现状不变。
5. 在测试允许的范围移动/使目录不可用，再启动，检查安全失败与重选恢复。
6. 比较内容清单，记录系统授权行为；不要通过生产 App 修改文件来“制造测试条件”。

### 7.2 iCloud

1. 准备已下载笔记 X 与占位笔记 Y，确认状态；X 完成索引和正文缓存。
2. 断网，读/搜 X 并收藏，退出重启验证；尝试 Y，检查明确不可用和其它笔记仍可操作。
3. 恢复网络，等待系统确实下载 Y，刷新后读到新内容，旧警告清除。
4. 对 iCloud 目录重复真实 picker/重启/切换；将下载造成的状态变化与 App 主动写入分开记录。

### 7.3 iPad/可访问性

1. 非空 Vault 下在常规宽度走导航—列表—详情，选择标签/笔记后退出重启。
2. 与其它 App 分屏到实际 compact 宽度，再展开和旋转；在搜索、阅读、picker 状态重复。
3. 普通/最大辅助字号 × 浅/深色走核心链路。
4. 开启真实 VoiceOver，完成打开、标签、Reader 链接、收藏、错误及返回；记录焦点或朗读缺陷。

每个手工案例按以下字段填报：

| 日期/源版本/工作树 | 设备/系统/宽度/provider 状态 | 案例编号 | 实际步骤/观察 | 结果 | 证据/缺陷 | 执行人 |
|---|---|---|---|---|---|---|
| 待填 | 待填 | 待填 | 待填 | NOT RUN | 待填 | 待填 |

## 8. 退出条件

- 8 个 AC 均有对应实际通过证据；必需案例无未解释的失败/跳过，Critical/High 缺陷关闭。
- 真机授权、iCloud、iPad 实分屏和 VoiceOver 不得由模拟器或离屏渲染冒充完成。
- 最低版本与 Mac 回归通过；只读清单覆盖全部 Vault 内容；所有变更可从干净 checkout 复现。
- T 项未定义阈值时只报告基线与实测缺陷；不擅自扩大当前版本的性能合同。
- 有 BLOCKED/NOT RUN 时，报告“自动化完成/人工未闭合”等准确状态，M-IOS 保持进行中。

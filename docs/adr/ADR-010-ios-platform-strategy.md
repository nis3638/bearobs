# ADR-010：iOS 只读客户端平台策略

- 状态：Accepted
- 日期：2026-10-01
- 关联：[REQ-004](../requirements/REQ-004-ios-read-only-client.md)、D-01（PRD 1.3 修订）

## 上下文

D-01 原判断是 iOS 客户端在 Mac MVP 稳定后建设。产品决定将**只读**纵切提前插入当前计划
（M-iOS），编辑与同步仍后置。约束条件：

- WebDAV 拉取（M2）延期未开工，iOS 第一版不能依赖它；
- `Package.swift` 已声明 `.iOS(.v26)` 平台并把核心拆成六个可复用模块；
- `VaultSelection` 安全书签代码已预留 `os(macOS) || os(iOS)` 分支；
- UI 层的 AppKit 依赖只有编辑面两个文件（`SourcePreservingTextView`、
  `EditorSurfaceLayoutManager`），Reader 与各 Feature Model 均为跨平台 SwiftUI/Foundation;
- 工程是手工维护的 pbxproj,App target 平铺编译全部源码,测试宿主为 Mac App。

## 决策

1. **数据来源 = 本地文件夹**。iOS 通过系统文件选择器选择本地或 iCloud Drive 的 Vault
   文件夹,复用既有本地索引/搜索/阅读管线;不建第二套同步。WebDAV 拉取待 M2 完成后作为
   iOS 二期复用同一套模块。
2. **独立 iOS App target,共享平铺源码**。同一 `BearObs.xcodeproj` 新增 `BearObsIOS`
   target,以文件成员方式共享现有源码;不启用 Mac Catalyst,不把工程迁移到 SPM 构建。
   两个 AppKit 编辑文件不进入 iOS target,保证只读属性由编译期成员而非运行时开关承载。
3. **平台差异只允许出现在记录在案的接缝**:
   - `ReaderView` 编辑分支用 `#if os(macOS)` 包裹(编辑按钮、编辑面调用);
   - `VaultSelection` 书签创建选项按平台分支(iOS 不使用 macOS 专属的
     `.withSecurityScope` 创建选项);
   - App 入口与壳层文件按平台分离(Mac 保留 `BearObsApp` + 三栏壳;iOS 新增入口与壳)。
   其余共享文件不得出现平台条件编译。
4. **导航形态按宽度分级**。紧凑宽度(iPhone)为固定五入口 TabView + NavigationStack 推入;
   常规宽度(iPad)复用与 Mac 相同职责的三栏 `NavigationSplitView`。三栏壳层组件从
   `ProjectShellView` 抽取为共享文件,Mac 行为不变。
5. **部署目标 iOS 26.0**,与 `Package.swift` 的 `.iOS(.v26)` 声明和 Xcode 26.5 工具链一致。
6. **测试策略**:共享核心的验证延伸到 iOS 模拟器——`BearObsIOSTests` 以只读 App 为
   宿主,镜像 Mac 单元测试成员(排除三个引用编辑面的测试文件);另建最小 iOS 冒烟
   UI 测试(选择 Vault→列表→阅读)。CI 增加 iOS 构建门禁(`make build-ios`/
   `make test-ios`)。

## 不做什么

- 不引入跨平台 UI 框架,不做 Catalyst;
- 不为 iOS 提前建 WebDAV、同步或冲突代码;
- 不在共享模块中新增平台抽象层;接缝数量固定并在 REQ-004 §7 登记;
- 不在 iOS 端提供任何写路径,包括"临时"的本地编辑。

## 后果与复审

- pbxproj 手工维护成本 +2 个 target(iOS App、iOS UI Test);每次新增共享源文件需要同时
  登记两侧成员,CI 的两平台构建门禁负责兜底;
- 书签与安全作用域在 iOS 模拟器上的行为需在 M-iOS 验收时以真机复核一次;
- iOS 二期(WebDAV 拉取)启动时复审:是否把共享源码改为按模块拆分 target 引用,以及
  同步账本在 iOS 沙箱中的位置;
- 若未来共享文件数超过手工登记的承受范围,优先考虑生成 pbxproj,而不是引入 Catalyst。

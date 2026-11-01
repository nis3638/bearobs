# REQ-004 iOS 本次测试报告（2026-10-25）

## 1. 执行范围与基线

- 目的：为 zcode 接手提供当前代码基线和实测结果，不在本轮开发产品功能。
- 源 HEAD：`078270fd9508eafdd87a1401aad99d2af6481fcd`。
- 输入：已有未提交生产/测试修改及 `docs/04-development-plan.md`，另有未跟踪 README；本次交接文档新增于其上。不是干净 checkout，不能作为最终交付基线。
- 工具：Xcode 26.5（17F42）。本机安装 iOS 模拟器 runtime 只有 26.5（23F77）；iOS 26.0 实跑未具备环境。
- 命令：`make ci`，顺序覆盖静态检查、离线 fixture、三个 Spike、Domain、Mac/iOS 构建、Mac 测试、iOS 测试与覆盖率、Mac 覆盖率。
- 原始日志：`/private/tmp/bearobs-ios-handoff-20261025-ci.log`、`/private/tmp/bearobs-ios-handoff-20261025-build.log`、`/private/tmp/bearobs-ios-handoff-20261025-ios.log`；结果目录为仓库 `.build/TestResults/` 与 `.build/reports/`。
- 本轮证据归档：`.build/reports/ios-handoff-20261025/`，包含上述日志副本、工作树摘要和本次实际生成的报告。开发机临时日志不是长期交付件，交接时应一起复制证据归档。

## 2. 本次结果

完整 `make ci` 已因测试编译失败退出（退出码 2）；后续 App 门禁独立执行，以免被前序失败遮住。未完成项不得读作 PASS。

| 项目 | 本次状态 | 说明 |
|---|---|---|
| 工程检查/离线 fixture | PASS | 脚本自测、格式、秘密模式与历史、117 个离线验证器测试、GoldenVault/WebDAV 契约/行为通过 |
| GRDB / Markdown / Atomic Write Spike | PASS | 各 Release/Debug 测试 7/14/15 个通过；覆盖率门禁与目标构建通过，原子写 7 个 SIGKILL 阶段通过 |
| Domain 冻结验证 | FAIL（前置编译） | 根包 Release 测试编译失败，尚未执行 Domain 验证和后续覆盖率/交叉编译 |
| Mac+iOS Debug/Release | INTERRUPTED / 未完成 | 独立 `make build` 首个 Mac Debug 在构建描述/工具探测阶段持续无新进展，主动中止；不能据此判代码编译失败或四构建通过 |
| Mac 单元与 UI | NOT RUN | 前序 CI 退出；独立 App 构建未完成，未继续启动同工具链的重复门禁 |
| iPhone 核心与 UI / iOS 覆盖率 | INTERRUPTED / 无有效结果 | 独立 `make test-ios` 在 26.5 iPhone 17 构建描述/工具探测阶段再次无新进展后中止；没有可用 xccov，本轮无通过数/覆盖率数值 |
| iPad 常规宽度空态冒烟 | INTERRUPTED / 门禁失败 | 中断后脚本继续到 iPad 目标，测试也未完成；test=75。安装/启动返回成功只说明既有产物可启动，不能证明本次构建或业务测试通过 |
| Mac 单测覆盖率 | NOT RUN | 同上；历史报告不能作为本次结果 |

本次结论：**完整 CI 未通过，App 回归未完成；交接规格已完成，产品验收未完成。** 本轮没有修改产品实现或测试代码，不提交、不发布。

### 本次已确认的失败

`BearObsTests/Infrastructure/UserState/VaultSelectionStoreTests.swift` 的 `SWIFT_PACKAGE` 分支是普通 `import BearObsUserState`，新增测试却使用内部 `VaultSelectionSaveCheckpoint` 和带故障注入闭包的内部构造器。实际编译报错：找不到 checkpoint 类型、无法解析 `.beforeFileSync/.beforeRename`、构造器多余尾随闭包。

故障阻断根包 Release 测试编译，不是 Domain 逻辑断言失败。最小修复方向为测试可见性，对应开发清单 IOS-DEV-01；本轮只记录和交接，不代 zcode 修改生产代码或测试。

### App 门禁的执行限制

Mac 构建与单独 iOS 测试均停留在 `CreateBuildDescription` / `ExecuteExternalTool clang -v -E -dM` 阶段，未产生源码编译结论。直接运行相同 Clang 探测命令可立即完成，但不足以定位 Xcode 内部等待原因；不将其猜测成 App 缺陷。

等待持续无进展后主动中止，日志含 `BUILD INTERRUPTED` / `TEST INTERRUPTED`；编译器没有给出新的源码错误。iOS 脚本最终报告 phone test=75、iPad test=75、覆盖率无法导出，外层会话退出码 130；这不等于任何测试断言已失败，也不等于通过。后续应在正常 Xcode 环境重跑，若仍复现再单独诊断。

注意报告新鲜度：本次生成的 `coverage-ios.txt/json/archive.json` 为空，而 `coverage-ios-gate.txt` 可能仍是 2026-10-04 的旧文件。**旧的 89.61%/80.56% 等覆盖率不可作为本次结果**；归档故意不收集旧 gate 文件。

## 3. 未完成的验收（与自动化通过无关）

| 项目 | 状态 | 原因/后续动作 |
|---|---|---|
| iOS 26.0 最低版本 | BLOCKED | 本机未安装；由 IOS-DEV-07 关闭 |
| iPad 有 Vault 三栏完整业务 suite | NOT RUN / 待补自动化 | 当前脚本只跑空态；IOS-DEV-04 |
| 真机 picker / scope / 书签恢复 | NOT RUN | 本轮未执行真机；IOS-DEV-08 |
| iCloud 占位/离线/恢复 | NOT RUN | 本轮未执行真实 provider 流程；IOS-DEV-08 |
| iPad 实际分屏 / VoiceOver / 设备外观 | NOT RUN | 人工设备验证；IOS-DEV-09 |
| 全 Vault 文件清单只读断言 | 待开发 | 当前 UI helper 只比较非隐藏 Markdown；IOS-DEV-02 |
| 恢复字段跨 Vault 混拼风险 | 待复现 | 尚不能称为已复现缺陷；IOS-DEV-03 |
| 干净 checkout 全门禁 | NOT RUN | 当前含已有改动；IOS-DEV-01/10 |

## 4. 如何使用本报告

- 本次自动化结果只证明当前已有测试覆盖的行为，不覆盖[完整测试方案](REQ-004-ios-test-plan.md)中的全部新增/人工案例。
- 待办执行与验收口径见[开发清单](REQ-004-ios-development-backlog.md)。
- 覆盖率中 executable subrange 是分支/区域代理，不是真实 Swift branch coverage。
- 总体交付状态仍为 M-iOS 进行中。后续开发需更新源版本和实测证据，不能复用本报告作为新版本的通过证据。

# BearObs

BearObs 是一个本地优先的 macOS 原生 Obsidian Vault 客户端:以 Vault 中的 Markdown 和附件为内容事实源,提供受 Bear 和 Apple Notes 启发的信息架构与交互效率,并通过 WebDAV 与既有 Vault 安全地交换文件。

> 用接近 Bear 的桌面体验,安全地浏览和编辑 Obsidian Vault。

## 产品定位

- **内容开放**:不创建只有 BearObs 才能读取的笔记格式,不锁定用户内容。
- **Vault 优先**:Markdown 和附件是事实源,本地索引(`index.sqlite`)只是可随时删除重建的派生物。
- **本地优先**:已同步内容断网时仍可阅读、搜索和编辑。
- **不静默覆盖**:本地与远端同时变化时必须进入显式冲突,所有写入先本地原子落盘,再尝试远端条件上传。
- **最小改写**:保存笔记不无关地重排 Frontmatter 或格式化全文。

详细的产品原则与功能需求见 [docs/01-product-requirements.md](docs/01-product-requirements.md)。

## 当前状态

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M0 | 工程与风险基线 | ✅ 完成 |
| M1 | Mac 本地只读闭环 | ✅ 完成 |
| M2 | Mac WebDAV 拉取 | ⏸ 延期,在本地编辑闭环后恢复 |
| M3 | Mac 编辑与条件上传 | 🚧 进行中(原位编辑已完成,上传未开始) |
| M-iOS | iOS 只读纵切(插队执行) | 🚧 进行中 |
| M4 | Mac 冲突处理与发布加固 | ⬜ 未开始 |

实时进度与工作项证据见 [docs/04-development-plan.md](docs/04-development-plan.md)。

## 仓库结构

```text
BearObs/                  # 源码(按 target 分层)
  Domain/                 #   领域模型,纯逻辑无依赖
  Markdown/               #   Markdown/YAML 解析与保源编辑
  Infrastructure/
    LocalVault/           #   本地 Vault 文件访问
    Index/                #   GRDB + FTS5 全文索引
    UserState/            #   本机用户状态(收藏、Vault 选择等)
  Features/Library/       #   笔记库能力
  App/                    #   macOS App 壳层(含 iOS/ 只读入口)
BearObsTests/             #   单元测试(含 GoldenVault / ChineseSearchVault fixtures)
BearObsIOSUITests/        #   iOS 冒烟 UI 测试
BearObsUITests/           #   macOS UI 测试
Config/                   #   Bundle ID 等 xcconfig
docs/                     #   产品需求、技术路线、设计、开发计划、ADR
scripts/                  #   CI、构建、验证脚本
Tools/                    #   独立工具(如坚果云 WebDAV 验证器)
Spikes/                   #   技术验证 spike
```

核心 SwiftPM 模块(`Package.swift`):`BearObsDomain`、`BearObsLocalVault`、`BearObsMarkdown`、`BearObsIndex`、`BearObsLibrary`、`BearObsUserState`,可执行壳层为 `BearObsAppShell`。

## 环境要求

- Xcode 26.5(见 `.xcode-version`),编译 warning 视为 error;
- 最低部署版本:macOS 15.0 / iOS 26.0;
- Swift 工具链 6.2;
- 第三方依赖只有三个:GRDB.swift(7.11.1)、swift-markdown(0.8.0)、Yams(6.2.2)。

## 常用命令

```bash
make check        # swift-format、秘密模式与工程卫生检查
make build        # macOS + iOS 模拟器 Debug/Release 双平台构建门禁
make test         # macOS Unit Test + UI Test
make test-ios     # iOS 模拟器共享核心测试 + iOS 冒烟 UI 测试
make coverage     # 单测覆盖率,输出到 .build/reports/
make ci           # 与 CI 相同的完整顺序

make dist-macos   # macOS Release 包(.app + zip + dmg),输出到 out/dist/
make dist-ios     # iOS 开发签名 .ipa,需 DEVELOPMENT_TEAM=<team id>
```

打包发布命令仅限内部构建形态;对外发布(签名、公证)属于 M4 范围,尚未实现。

## 文档索引

| 文档 | 内容 |
|---|---|
| [01-product-requirements.md](docs/01-product-requirements.md) | 产品目标、范围与验收标准 |
| [02-technical-roadmap.md](docs/02-technical-roadmap.md) | 架构原则、数据流与能力顺序 |
| [03-development-design.md](docs/03-development-design.md) | 详细设计 |
| [04-development-plan.md](docs/04-development-plan.md) | 里程碑、工作项与执行证据 |
| [05-engineering-baseline.md](docs/05-engineering-baseline.md) | 工程约束、CI 与覆盖率口径 |
| [adr/](docs/adr/) | 关键决策记录(内容源、路径身份、三路同步、iOS 策略等) |
| [requirements/](docs/requirements/) | 逐项功能需求(侧边栏导航、原位编辑、iOS 只读等) |

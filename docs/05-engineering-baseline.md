# BearObs M0-01～M0-06 工程基线

## 范围

本基线只覆盖独立 Git 边界、iOS 26+ SwiftUI 工程、测试 targets、CI、依赖与配置管理、
M0-05 Golden Vault，以及 M0-06 可控 WebDAV fixture。项目 Git 根目录固定为
`/Users/ivows/workspace/bearobs`，默认分支为 `main`；父目录仓库不再承载 BearObs 历史。
本文件不代表完整 M0 完成，也不实现 Vault、Markdown parser、索引、生产 WebDAV 客户端
或同步业务。

## 工程约束

- Xcode 固定为 `.xcode-version` 中的 26.5，最低部署版本为 iOS 26.0。
- 工程保持一个 App target、一个 Unit Test target、一个 UI Test target。
- 共享 `BearObs` scheme 必须提交；CI 不读取 `xcuserdata`。
- Bundle ID 集中在 `Config/App.xcconfig`，当前初始化值为 `com.ivows.bearobs`。
- Debug 和 Release 都把编译 warning 当 error。

## 本地与 CI 命令

```bash
make check      # swift-format、秘密模式和工程卫生检查
make build      # Debug + Release simulator build
make test       # Unit Test + UI Test
make coverage   # Unit Test coverage，输出到 .build/reports/
make ci         # 与 CI 相同的完整顺序
```

可用 `CI_DESTINATION='platform=iOS Simulator,id=<UDID>' make test` 显式指定模拟器。
未指定时，脚本用固定的 iOS 26.5 runtime 和 iPhone 16 device type 创建一次性 Simulator，
执行后自动删除。可用 `CI_DEVICE_TYPE` 显式替换 device type，但 CI 基线不使用浮动目标。

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

本机当前没有已安装的 iOS Simulator runtime，`simctl list runtimes` 为空，因此本轮
`make test` 无法启动运行目标。该环境缺口不影响无 Simulator 行为验证、Debug/Release 构建
或 test bundle 编译；安装 iOS 26.5 runtime 后，现有 test plan 会直接执行这些 XCTest。

该 fixture 只证明 HTTP 客户端接缝，不证明真实 TLS、认证 challenge、重定向或厂商方言；
这些仍由 M0-11 和 M2-A6 的真实服务认证负责。

## 依赖与配置

- 当前第三方运行时依赖：无。
- 格式检查使用 Xcode 工具链自带的 `swift-format`，版本随 Xcode 26.5 一并锁定。
- 后续 Swift Package 必须使用稳定版本约束并提交 `Package.resolved`；禁止 branch 依赖。
- GRDB、swift-markdown 和 YAML parser 必须等对应 M0 Spike 验证后再加入，不能提前假装已锁定。
- `Config/Secrets.xcconfig`、`.env*` 和构建产物被忽略。源码和普通配置不得存放凭据。
- WebDAV 凭据未来只进入 Keychain；CI 凭据只进入 CI secret store。
- 零依赖静态检查覆盖常见云端、GitHub、Slack、OpenAI、私钥和认证头模式，并同时扫描
  当前工作树与所有 Git revisions；输出只报告命中，不回显可能的秘密。

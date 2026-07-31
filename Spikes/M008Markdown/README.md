# M0-08 Markdown Spike

这个隔离 Swift Package 验证 Markdown 解析接缝，不是生产 parser。它直接读取
`BearObsTests/Fixtures/GoldenVault`，不复制 fixture，也不修改输入字节。

## 结论

- `swift-markdown` 0.8.0 可为标准 Markdown 构建 AST，并通过 `MarkupWalker` 与
  `SourceRange` 提供结构和源码位置；
- Yams 6.2.2 可只读提取 Frontmatter 的 `title` 与字符串/数组 `tags`；
- 先用 AST 范围遮罩代码、标准链接/图片和 HTML，再单遍扫描 Obsidian Tag、Wiki Link、
  Embed，可避免为每种语法建立互相冲突的 parser；
- UTF-8 BOM、LF、CRLF 和 Unicode 源码位置可显式处理，原始 `Data` 保持不变；
- 两个依赖及其 C 依赖可编译为 arm64 iOS 26 Release target。

锁定版本与 revision：

| 包 | 版本 | Revision |
|---|---:|---|
| swift-markdown | 0.8.0 | `3c6f9523da3a1ec2fd829673e472d95b8097a3b8` |
| Yams | 6.2.2 | `a27b21e0c81c5bf42049b897a62aaf387e80f279` |
| swift-cmark（传递依赖） | 0.8.0 | `924936d0427cb25a61169739a7660230bffa6ea6` |

## 验证

```bash
make spike-markdown
```

该命令执行 Release 测试、Debug 覆盖率与 80% 行覆盖率门禁，并交叉编译
`arm64-apple-ios26.0`。在禁止 SwiftPM 子进程沙箱的受控开发环境中可显式使用：

```bash
BEAROBS_DISABLE_SWIFTPM_SANDBOX=1 make spike-markdown
```

默认和 CI 不关闭 SwiftPM sandbox。

本轮结果：14 个 XCTest 通过，源码行覆盖率 93.74%，iOS 交叉编译通过。本机 arm64 macOS
26.5 三次 Release 观测范围为：

- 1 MiB Markdown：约 74.6～101.9 毫秒；
- 256 个小文件：约 22.6～40.5 毫秒。

这只是 Spike 基线，不是最低目标 iPhone 上的产品 NFR。

## 明确非目标

- 不做 Wiki Link 路径解析、同名消歧或附件存在性决策；
- 不决定标题优先级、摘要或索引 schema；
- 不把 AST 序列化回原文，不写回 YAML；
- 不把依赖的 HTML formatter 当成生产 Reader。

`diagnosticHTML` 是未清洗的诊断输出，可能保留原始 HTML。禁止把它送入 WebView 或作为
可信 HTML。M1 必须建立原生渲染边界，并在不可信文件入口增加文件大小和 YAML 复杂度上限。

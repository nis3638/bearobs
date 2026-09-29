# ADR-005：Markdown 原文编辑而非 AST 全文回写

- 状态：Accepted
- 日期：2026-08-01

## 上下文

Obsidian Vault 是用户长期拥有的文件集合。将 AST 或 YAML 再序列化成全文会改变空格、注释、字段
顺序和未支持语法，等同于隐性内容损坏。

## 决策

- 阅读、提取、渲染和索引使用 Markdown AST 与只读 Frontmatter。
- 编辑已有笔记时处理原始字节流，尽量保留 BOM 和换行风格；写入通过同目录原子替换发布。
- 不支持的语法安全降级为原文显示；不做富文本、自动格式化或 AST 全文回写。

> 2026-09-28 修订：原“不做 Live Preview”一项由 [ADR-009](ADR-009-source-preserving-live-preview.md)
> 替代；原始 Markdown 事实源与禁止 AST 全文回写两条不变量继续有效。

## 不做什么

不把标签、链接或 Frontmatter 提取结果作为可直接重建源文件的格式化模型。

## 后果与复审

M3 编辑器必须实现局部文本修改并为换行、BOM、无效 Frontmatter 和未知 Obsidian 扩展保留回归测试。

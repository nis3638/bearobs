---
title: REQ-002 编辑态 VoiceOver 人工走查清单
date: 2026-10-01
status: pending-manual-review
requirement_id: REQ-002
tags:
  - accessibility
  - voiceover
  - checklist
---

# REQ-002 编辑态 VoiceOver 人工走查清单

## 1. 环境记录

- 日期：2026-10-01（清单出具日）
- 系统版本：macOS 27.0（Build 26A428），Apple Silicon（MacBook Pro）
- 构建工具：Xcode 26.5
- 被测构建：REQ-002 P6 完成时的 Debug 构建（`make build` 通过）

## 2. 走查状态

- [ ] 人工 VoiceOver 走查已执行（下方第 4 节逐项勾选）
- 自动化覆盖：第 3 节所列测试于 2026-10-01 全绿
  （xcodebuild 测试计划 382 通过 0 失败；SwiftPM 345 通过 0 失败）

> 说明：本清单随 REQ-002 P6 交付出具。自动化测试已覆盖全部条目的可编程部分，
> 但 VoiceOver 的实际朗读效果（时机、清晰度、焦点顺序）必须由人工在真实
> VoiceOver 开启状态下确认，结果填入第 4 节"结果"栏。全部条目勾选前，
> REQ-002 收口待办第 5 项（macOS UI 验收）不得标记完成（P7 执行）。

## 3. 自动化证据索引

| 走查项 | 自动化证据 |
|---|---|
| 进入编辑朗读"已进入编辑模式" | `EditorSurfaceInteractionTests.testEnteringTheSurfaceAnnouncesEditingMode` |
| 进入编辑后焦点落在编辑表面 | `EditorSurfaceInteractionTests.testEnteringTheSurfacePromotesInitialFocus`、UI `testKeyboardEntersEditingAndCommandSSavesTheDraft`（无需点击即可输入） |
| 光标移动朗读节点类型（标题/段落/列表项/引用/代码块），同类不重复 | `EditorSurfaceInteractionTests.testNodeTypeAnnouncementsFollowTheCaretWithoutRepeating` |
| 任务行朗读未完成/已完成状态 | `EditorSurfaceInteractionTests.testSelectionAnnouncesTaskStateAndLocalSourceRegion` |
| 局部源码区域朗读 | 同上（"局部源码区域"序列） |
| Command-L 切换任务并朗读新状态 | `EditorSurfaceInteractionTests.testCommandLKeyboardEquivalentTogglesTaskUnderCaret`、`testToggleAnnouncesTheNewTaskState`；UI `testCommandLTogglesTheTaskMarkerOnTheCaretLine` |
| 任务切换的自定义 AX 操作（标记为已完成/未完成） | `EditorSurfaceInteractionTests.testAccessibilityActionTogglesTaskUnderCaret` |
| Command-S 保存中/完成朗读（"正在保存笔记"/"已保存"） | `EditorSurfaceInteractionTests.testSaveStatusTransitionsAreAnnounced` |
| 保存失败朗读失败标题与文案 | `testSaveStatusTransitionsAreAnnounced`（失败文本经 `EditorFailure.title/message` 注入） |
| 保存失败焦点留在编辑器、重试不丢草稿 | `EditorFeatureModelTests.testSaveFailurePreservesDraftSelectionAndViewport`、`testRetryAfterSaveFailureResavesTheIntactDraft`；UI `testSaveFailureKeepsTheEditorAndRetryPreservesTheDraft` |
| Escape 经过 dirty guard | UI `testEscapeGoesThroughTheDirtyGuard` |
| 深色 + 最大辅助字号可操作 | UI `testEditorOperatesInDarkModeAtLargestAccessibilitySize`、`testLibraryRemainsOperableAtLargestAccessibilitySizeInDarkMode` |
| 编辑表面快捷键帮助文本（Command-S / Escape / Command-L） | `SourcePreservingTextView.swift` `setAccessibilityHelp`（构建契约） |

## 4. 人工走查项（开启 VoiceOver：Command-F5）

每项记录：朗读内容与预期是否一致、是否可独立完成操作。结果栏填"通过 / 不通过（现象）"。

| # | 操作 | 预期朗读/行为 | 结果 |
|---|---|---|---|
| 1 | 阅读面按 Command-E（或菜单 文件 → 编辑笔记） | 朗读"已进入编辑模式"；焦点落在"可编辑笔记内容"，直接输入不丢焦点 | |
| 2 | 光标依次移入 标题 / 段落 / 列表项 / 引用 / 代码块 | 分别朗读"一级标题"（级别对应）、"段落"、"列表项"、"引用"、"代码块"；同行内移动不重复 | |
| 3 | 光标移入任务行 | 朗读"未完成任务"或"已完成任务" | |
| 4 | 光标在任务行按 Command-L | marker 翻转，朗读新状态；再按一次翻回 | |
| 5 | VoiceOver 光标停在任务行，用 VO+空格 触发自定义操作 | 操作名"标记为已完成"/"标记为未完成"，执行后任务状态翻转 | |
| 6 | 光标移入 `%% … %%` 等局部源码区域 | 朗读"局部源码区域"，可见区域出现边框与"局部源码区域"标注（不只靠颜色） | |
| 7 | 按 Command-S | 朗读"正在保存笔记"，完成后朗读"已保存" | |
| 8 | 修改后按 Escape | 弹出"放弃未保存的修改？"，"继续编辑"/"放弃修改"两个按钮可达且朗读清楚；继续编辑后草稿保留 | |
| 9 | 制造保存失败（如临时将 Vault 目录设为只读后 Command-S） | 朗读"无法保存笔记。原文件保持不变…"；焦点仍在编辑器，可继续输入；"重试保存"按钮可达，恢复权限后重试成功且草稿完整 | |
| 10 | 引用块 | 缩进 + 左侧引导线 + 次级颜色，不只靠颜色表达引用 | |
| 11 | 深色模式下重复 1–8 | 全部条目表现一致 | |
| 12 | 系统设置 → 辅助功能 → 显示 → 文本大小调到最大，重复 1–6 | 编辑表面可操作，朗读一致 | |

## 5. 已知限制

- 合成键盘事件（XCUITest）无法到达菜单键等价阶段，Command-E 的 ⌘E 绑定
  本身只能由本清单第 1 项人工确认；菜单命令的存在性、启用时机与触发链路
  已由自动化覆盖。
- 朗读通过 `NSAccessibility` announcement（`.announcementRequested`）实现，
  VoiceOver 何时播报公告由系统调度；若发现公告被吞，属于系统调度行为，
  在本清单记录现象即可，不构成代码缺陷。

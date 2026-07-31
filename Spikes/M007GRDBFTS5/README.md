# M0-07 GRDB / FTS5 Spike

## 结论

GRDB 7.11.1 在 Xcode 26.5、Swift 6.3.2 下通过 macOS 可执行测试和 iOS 26 交叉编译，
可以作为 M1 `index.sqlite` 实现的锁定候选版本。依赖使用精确版本并提交
`Package.resolved`，不使用 branch 约束。

本目录是隔离的技术 Spike，不是生产索引模块。M1 才会建立正式的
`notes`、`tags`、`note_tags`、`links`、`attachments` 和 `note_fts` schema，并把 GRDB
链接到 App target。

## 验证的数据结构

- `spike_documents`：以 `path` 为主键，仅保存 title 和 body；
- `spike_document_fts`：独立 FTS5 虚表，path 不参与索引，title 和 body 使用
  `unicode61`；
- `v1_create_spike_documents` 先建普通表；
- `v2_create_spike_fts` 建 FTS5 表，并回填 v1 已有记录；
- 每批 upsert 在 GRDB 单个写事务中同步更新普通表和 FTS 表。

这个最小结构专门消除错误假设，不冻结 M1 的生产数据模型。

## 可执行验证

在仓库根目录执行：

```bash
make spike-grdb
```

受另一层 macOS sandbox 管理、且 `sandbox-exec` 无法嵌套时，可显式执行
`BEAROBS_DISABLE_SWIFTPM_SANDBOX=1 make spike-grdb`。默认和 CI 都保留 SwiftPM sandbox，
不能无条件关闭供应链隔离。

门禁覆盖：

- migration 从 v1 升级到 v2、旧数据回填和重复打开幂等；
- `DatabasePool` 原生 async read/write，并发写入 1,000 条无丢失；
- upsert 后旧 FTS 词项消失，新词项可查；
- 批处理中途注入 SQLite 错误后，普通表和 FTS 变更一起回滚；
- `unicode61` 大小写和音调符号归一化；
- 连续中文短语可查，但不声称具备中文分词质量；
- 精确 10,000 条合成数据写入和 30 次预热后搜索；
- Spike 源码行覆盖率不低于 80%；
- 使用 iPhoneOS 26.5 SDK 的 arm64 iOS 26 Release 交叉编译。

## 10k 基线

2026-07-30 在 arm64、macOS 26.5、Xcode 26.5、Swift 6.3.2 上重复执行 Release 构建：

| 指标 | 重复观测 |
|---|---:|
| 文档数 | 10,000 |
| 单事务 upsert | 2.855～3.204 秒 |
| 唯一词搜索 P95 | 0.302～0.330 毫秒 |
| 每轮搜索样本 | 30 |
| 结果正确性 | `notes/9999.md` 精确命中 |

覆盖率运行得到源码行覆盖率 99.02%，region 覆盖率 95.00%。

这些数字只证明技术路线有可用基线。PRD 的搜索 P95 不高于 300 毫秒要求以最低目标 iPhone
真机和真实 10,000 文件 Vault 为准；开发 Mac 的结果不能冒充正式性能验收。中文 tokenizer
选择同样留到 M1 用真实语料测量。

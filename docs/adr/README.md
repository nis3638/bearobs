# Architecture Decision Records

这些 ADR 只冻结已验证的架构决策。`Accepted` 表示当前实现和计划必须遵守；服务选择的
`Accepted` 不等于该服务的上传能力已经认证，能力矩阵仍必须保留实测状态。

| ADR | 状态 | 主题 |
|---|---|---|
| ADR-001 | Accepted | Vault 内容事实源与本地工作副本 |
| ADR-002 | Accepted | 路径作为 MVP 文件身份 |
| ADR-003 | Accepted | 索引、同步账本与用户状态物理隔离 |
| ADR-004 | Accepted | 三方同步与无静默覆盖 |
| ADR-005 | Accepted | Markdown 原文编辑 |
| ADR-006 | Accepted（认证待完成） | 首个认证 WebDAV 服务与能力矩阵 |
| ADR-007 | Superseded by ADR-008 | 中文 FTS 初始策略 |
| ADR-008 | Accepted | 汉字 unigram+bigram 双 FTS |
| ADR-009 | Accepted | 源码保留的编辑即预览 |

ADR-006 已选择坚果云；在取得专用测试账号、应用密码和认证证据前，禁止为其开启条件上传。

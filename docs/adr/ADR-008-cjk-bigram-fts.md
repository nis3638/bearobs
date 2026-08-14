# ADR-008：汉字 unigram+bigram 双 FTS

- 状态：Accepted
- 日期：2026-08-13

## 上下文

ADR-007 要求在 M1 用授权或合成中文 Vault 实测召回、误匹配、索引体积和查询延迟，再决定
是否扩展 `unicode61`。裸 `unicode61` 会把连续汉字视为一个 token，能命中完整短语，却无法
命中用户常用的双字子串；SQLite trigram tokenizer 又无法处理两个汉字的查询。

## 测量

固定合成语料包含离线、全文检索、同步冲突和研发标签场景：

- 6 个正向自然查询中，裸 `unicode61` 命中 2/6；候选策略命中 6/6；
- 加入 2 个跨笔记组合的负向查询后，裸方案完整满足 4/8 个期望结果集，候选策略为 8/8，
  未出现测得的误匹配；
- 10,000 篇合成中文笔记、30 次唯一查询的 macOS host Debug 测量中，候选查询 P95 为
  0.808 毫秒，低于 NFR-03 的 300 毫秒预算；该数据是回归基线，不代替真机 P95；
- SQLite `dbstat` 测得普通 FTS shadow tables 为 1,400,832 bytes，中文 FTS 为
  4,812,800 bytes，约 3.44 倍，低于本阶段设定的 8 倍上限。

## 决策

- 保留 `note_fts` 的 `unicode61`，继续服务拉丁文本、数字和完整 token 查询；
- 增加独立 `note_cjk_fts`，只对连续汉字生成单字 token 与相邻双字 token；
- 纯汉字查询使用 FTS phrase 匹配，混合查询使用 all-token 匹配；
- 两张 FTS 与 notes、tags、links、attachments 在同一事务更新；
- `v4_create_cjk_note_fts` 从已有普通 FTS 流式回填，旧 migration 不原地修改；
- 真机性能、真实用户语料和磁盘占用继续在 M4-08 复测。未达到 NFR-03 时再比较 ICU、可插拔
  分词器或更紧凑的 n-gram 表达。

## 后果

中文双字查询获得可接受召回，同时引入约 3.44 倍的 FTS 存储开销和额外事务写入。索引仍是
可删除重建的派生数据，不改变 Markdown、同步账本或用户状态。

# ADR-002：路径作为 MVP 文件身份

- 状态：Accepted
- 日期：2026-08-01

## 上下文

WebDAV 服务普遍不给稳定对象 ID。过早引入伪造 ID 或服务专属元数据只会制造不可迁移状态。

## 决策

- MVP 用 NFC、区分大小写的 `VaultPath` 作为文件身份。
- `VaultPath` 分开接收已解码本地路径与百分号编码远端路径；远端路径按段且仅解码一次。
- 拒绝绝对路径、空段、`.`、`..`、NUL、反斜杠及解码后才出现的分隔符或穿越。
- 重命名在 MVP 中表现为旧路径删除加新路径新增；不提供 App 内创建、删除和重命名。

## 不做什么

不做大小写折叠、兼容 Unicode 归一化、完整 URL 身份或 `RawRepresentable` 字符串绕过入口。

## 后果与复审

M2 的适配器负责 HTTPS origin、WebDAV 根路径剥离和 URL 映射；`LocalVaultStore` 负责
descriptor-relative、symlink-safe containment。服务若提供可靠移动语义，必须另立 ADR 后才能改变
身份模型。

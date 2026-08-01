# ADR-006：首个认证 WebDAV 服务与能力矩阵

- 状态：Proposed
- 日期：2026-08-01

## 上下文

本地 fixture 已覆盖受控 PROPFIND、GET、条件 PUT 和 412，但不能证明真实 TLS、认证 challenge、
重定向或厂商行为。产品文档原计划按坚果云实施；尚无专用账号或实例配置，因此任何服务都还没有
认证证据。

## 候选与建议

技术建议优先选择**用户控制的 Nextcloud 专用测试用户和空目录**，运行在可信 CA 的 HTTPS 实例上。
官方文档明确其 `/remote.php/dav` 文件 WebDAV 路径、Basic/app password、PROPFIND、GET、PUT
及带引号 ETag 示例；但没有把 `If-Match` PUT 语义当作可直接假设的承诺，必须实测。

- [Nextcloud WebDAV client API](https://docs.nextcloud.com/server/stable/developer_manual/client_apis/WebDAV/basic.html)
- [Nextcloud Docker image](https://github.com/nextcloud/docker)

Apache `mod_dav` 可作为可重复协议对照，不是厂商认证替代品。坚果云仍是产品文档中的既有计划；
本 ADR 的技术建议尚未改变该计划，必须由用户确认坚果云或 Nextcloud，并提供可测试账号和服务端
能力证据后才做最终选择。

## 拟议决策

在用户确认可用实例后，选定一个唯一服务作为首个认证目标；其他 WebDAV 服务仅作尽力兼容，不作
上传承诺。测试只能写入专用空目录和合成 Markdown，凭据仅通过 Keychain、受控环境变量或 CI
secret store 注入，禁止进入仓库、日志和报告。

## 接受门槛

真实服务必须实测并留存脱敏证据：可信 TLS/主机名、401 challenge、认证成功、Depth 0/1 `207`、
Unicode/空格/`%25` 路径、GET 字节和 ETag、匹配 ETag 的 PUT、陈旧 ETag 的 412 且远端内容不变，
以及实际远端删除。弱/缺失 ETag、403/5xx、跨 origin 重定向等客户端安全降级由受控 fixture 覆盖；
真实服务没有提供这些情形时，只记录能力缺失，不要求人为制造故障。

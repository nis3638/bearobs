# ADR-006：首个认证 WebDAV 服务与能力矩阵

- 状态：Accepted（服务选择；认证能力移交 M2-A6，不阻塞 M1）
- 日期：2026-08-01
- 最近更新：2026-08-12

## 上下文

本地 fixture 已覆盖受控 PROPFIND、GET、条件 PUT 和 412，但不能证明真实 TLS、认证 challenge、
重定向或厂商行为。坚果云已被选为首个认证服务；尚未完成本机真实服务人工验证。为了不让外部
厂商协议阻塞无网络依赖的本地只读纵切，原 M0-11 的验证工作完整移交 M2-A6，不按完成处理。
这项顺序调整不改变任何远端能力的安全门槛。

## 决策

首个认证目标固定为坚果云 WebDAV：`https://dav.jianguoyun.com/dav/`。使用坚果云账号和为
BearObs 单独生成的第三方应用密码；不得使用账号登录密码。官方说明的免费版访问频率为每 30 分钟
不超过 600 次、单次目录请求最多 750 个条目且需分页、默认上传上限为 500 MB。500 MB 是服务硬
上限；BearObs 仍保持产品既定的单附件默认 50 MB 上限，除非另有产品决策。这些限制必须进入 M2
枚举、限流和附件策略。

- [坚果云第三方应用授权 WebDAV 开启方法](https://help.jianguoyun.com/?p=2064)
- [坚果云 WebDAV 地址与应用密码配置](https://help.jianguoyun.com/?p=5677)

本地 fixture 和 Apache `mod_dav` 可作为可重复协议对照，不是坚果云厂商认证替代品。其他服务
仅作尽力兼容，不承诺上传能力。

## 本机一次性人工验证边界

原 M0-11、现 M2-A6 使用仅在 macOS 本机运行、仅由开发者显式触发的一次性验证工具。真实网络验证不得进入
CI、XCTest、定时任务或常规 `check`/`test` 目标，也不得在无人值守环境运行。

### 凭据

本工具的坚果云凭据只能存入 macOS Keychain，不允许使用环境变量或 CI secret store。Keychain
条目固定为：

- service：`com.bearobs.m0-11.jianguoyun`；
- account：`credentials-v1`；
- class：Generic Password；
- Keychain 实现：当前用户的登录钥匙串（file-based Keychain）；
- 同步：关闭，不写入 iCloud Keychain；
- 查询边界：保存、读取、更新、删除和删除确认必须使用同一 Keychain 实现。

本工具是本机一次性 SwiftPM CLI，当前没有 Apple Developer 签名身份、provisioning profile 或
app-like bundle。Data Protection Keychain 的访问组依赖代码签名授权；在这个边界下强行启用只会
产生不可运行且难以稳定复现的命令。因此本工具明确使用当前用户登录钥匙串；未来若改为签名的
macOS app-like bundle，必须另起 ADR 迁移到 Data Protection Keychain，禁止两个实现混查或混删。

用户名和第三方应用密码共同编码进版本化的 `kSecValueData`；真实用户名不得写入 Keychain 的
account、label、comment 等元数据。工具直接使用 Security.framework，不得调用会把密码暴露在
进程参数中的 `security ... -w PASSWORD`。重复条目不得静默覆盖，替换前必须再次人工确认。

工具只提供交互式 `store-credentials`、`verify` 和 `delete-credentials` 动作。用户名、应用密码和
专用远端目录均在运行时交互读取，密码输入必须关闭终端回显；这些敏感值不得通过 argv、环境变量、
配置文件或 stdin 重定向注入，也不得进入 Shell 历史、日志、报告、测试附件、artifact 或 Git 仓库。
Keychain 读取失败必须直接失败，不得回退到其他凭据来源。

### 专用目录与精确清理

验证只能访问用户事先在坚果云中明确创建的专用空目录，禁止指向或读取真实 Vault。工具先以
Depth 1 `PROPFIND` 确认目录为空；目录非空、路径不在固定 `/dav/` 根内或响应无法证明边界时，
必须在零远端写入的状态下退出。

工具只创建本次运行生成的合成 Markdown，用高熵运行标识登记每个将要创建的资源，并覆盖 Unicode、
空格和字面 `%` 路径。每次 mutation 前先记录 intent；正常结束和失败路径都只能按本次登记清单逐项
删除，并再次确认资源已消失。禁止递归删除专用根，禁止扫描后按前缀或目录批量删除，禁止删除未由
当前运行明确登记的对象。用于崩溃恢复的本机私有清理账本必须位于仓库外，目录权限为 `0700`、文件
权限为 `0600`，完成清理后立即删除；账本状态不一致时停止自动删除并转人工复核。

### TLS、认证与重定向

- 仅允许固定 HTTPS origin `https://dav.jianguoyun.com`，使用系统默认 TLS 信任和主机名校验，
  不提供证书、主机名或信任绕过；
- 请求 URL 禁止 userinfo 和 query；每个最终响应 URL 及每个 PROPFIND `href` 都必须重新验证
  同 origin、仍位于 `/dav/` 且没有越出用户输入的专用根；
- 验证工具拒绝所有 HTTP 重定向；跨 origin、HTTPS 降级到 HTTP 或越出 `/dav/` 根的跳转必须
  明确失败，不能携带或重试凭据；
- 初始请求不得预置 `Authorization`。未认证 `401` 检查与认证请求使用相互隔离的 ephemeral
  session，禁用共享 credential storage；
- 只响应固定 origin 的 Basic 或 Digest challenge，凭据 persistence 为 `none`；未知认证方法、
  重复认证失败或来自其他 host 的 challenge 一律拒绝。

## 人工执行流程

1. 开发者在坚果云中人工创建专用空目录，并生成 BearObs 专用第三方应用密码；关闭终端录制、
   HTTP 代理抓包和会保存会话内容的调试工具。
2. 显式运行 `store-credentials`，交互输入用户名和应用密码，将版本化 payload 写入上述固定
   Keychain 条目。
3. 显式运行 `verify`，交互输入专用目录；工具先执行未认证 Depth 0 `PROPFIND` 并要求 `401`
   challenge，再认证执行 Depth 0/1 `PROPFIND` 并要求可解析的 `207 Multi-Status`。
4. 工具确认专用目录为空后，只写入本次合成 Markdown；随后验证路径往返、GET 字节一致、强 ETag、
   匹配 ETag 的条件 PUT、旧 ETag 的条件 PUT 和条件 DELETE 均返回 `412`，并在两次 `412` 后
   再次 GET 证明远端正文和当前强 ETag 均未改变。
5. 只有条件 DELETE 探针通过后，工具才按本次登记清单和刚证明的当前强 ETag 逐项 DELETE，并确认
   每个资源消失；通过结果必须先持久化为清理授权状态。若进程在探针通过前崩溃，恢复流程只可
   读取并确认资源不存在；只要登记资源仍存在，就停止自动删除并要求人工复核。任何中途失败都
   不得扩大删除范围。
6. 工具输出严格脱敏的能力矩阵。需要时显式运行 `delete-credentials` 删除固定 Keychain 条目。

## 报告与证据

报告只允许包含 case/capability 名称、`PASS`/`FAIL`/`BLOCKED`/`UNAVAILABLE`、HTTP 状态码、固定
原因码、时间戳、工具版本或 Git revision、ETag 强弱类别、字节/hash 是否一致和清理状态。

报告不得包含完整 URL、用户名、密码、专用目录、对象名、认证头、原始 `WWW-Authenticate`、realm、
请求或响应正文、原始 ETag、Keychain 查询字典、HAR、代理抓包、截图或终端录制。只有该脱敏报告
可以作为 M2-A6 证据；原始网络内容不得保存为 artifact。

## 接受门槛

真实服务必须实测：可信 TLS/主机名、未认证 `401` challenge、challenge 后认证成功、Depth 0/1
`207`、Unicode/空格/字面 `%` 路径、GET 字节和强 ETag、匹配 ETag 的 PUT、陈旧 ETag 的条件
PUT 与条件 DELETE 均返回 `412` 且远端内容不变，以及实际远端删除和清理确认。弱/缺失 ETag、
403/5xx、跨 origin 重定向等客户端
安全降级由受控 fixture 覆盖；真实服务没有提供这些情形时，只记录能力缺失，不人为制造故障。

坚果云文档只说明单次目录请求最多 750 个条目，但没有给出可验证的厂商分页协议。工具不得臆造
私有分页 API，也不得通过 751 次 PUT 制造远端数据。因此分页项必须报告
`BLOCKED vendor-pagination-protocol-undocumented`，不能伪装成 `PASS`。

在真实人工执行及脱敏证据审查完成前，M2-A6 保持 `NO-GO`，不得发布坚果云 profile，也不得开放
远端上传。该状态不阻塞 M1 的本地枚举、索引、搜索和阅读。即使其他真实服务 case 全部通过，只要
分页项仍为上述 `BLOCKED`，就不得关闭 M2-A6；只有取得厂商协议证据或通过新的 ADR 明确调整服务
能力边界后才能关闭该工作项。

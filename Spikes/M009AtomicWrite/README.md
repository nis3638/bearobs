# M0-09 Atomic Write Spike

这个隔离 Swift Package 验证“已有文件的字节级原子替换”，不是编辑器、同步器或生产
`LocalVaultStore`。它不解析 Markdown，只接收最终 `Data`。

## 核心结论

安全写序只有一条：

```text
open parent directory without following its final symlink
  -> inspect existing regular file relative to stable directory fd
  -> create exclusive sibling staging relative to the same fd
  -> write complete bytes
  -> preserve rwx mode
  -> fsync staging
  -> close staging
  -> single rename publish
  -> fsync parent directory
  -> reread and verify exact bytes
```

- staging 是目标同目录的唯一隐藏文件，因此与目标处于同一卷；整个事务固定在同一个父目录
  descriptor 上，父路径被改名或复用也不会把后续操作重定向到另一个目录；
- staging 使用 `O_CREAT | O_EXCL | O_NOFOLLOW`，不会截断或跟随碰撞的符号链接；
- 发布与失败清理前重新核对 destination/staging 的 device + inode，可发现检查前发生的并发
  替换；POSIX 的 `fstatat -> renameat/unlinkat` 不是原子 CAS，不能宣称关闭全部恶意竞态；
- 目标不存在、目录、符号链接和非文件 URL 全部拒绝；MVP 编辑只更新已有 Markdown；
- `rename` 是唯一提交点，禁止 `O_TRUNC` 目标或 `remove + move`；
- 提交前失败返回 `notCommitted`，旧文件保持逐字节完整；
- `rename` 后目录同步失败返回 `committedButDurabilityUncertain`；目录同步成功后若重读失败或
  不一致，返回 `committedAndDurableButVerificationFailed`。两者的目标都已是完整新版，调用方
  不得假装旧版仍在或盲目重试；
- Writer 对编码无知，UTF-8 BOM、LF、CRLF、混合换行、空文件和任意非 UTF-8 字节都不变。

Swift Foundation 当前的原子写实现同样采用父目录临时文件、`fsync` 和 `rename`。本 Spike
没有直接调用 `Data.write(.atomic)`，因为黑盒 API 无法精确注入 ENOSPC、sync、close、rename
和提交后故障。

## 可执行验证

在仓库根目录执行：

```bash
make spike-atomic-write
```

受另一层 macOS sandbox 管理、且 SwiftPM sandbox 无法嵌套时，可显式执行：

```bash
BEAROBS_DISABLE_SWIFTPM_SANDBOX=1 make spike-atomic-write
```

默认和 CI 保留 SwiftPM sandbox。门禁包括：

- 15 个 XCTest：成功顺序、mode、字节透明、路径/符号链接、staging 碰撞、ENOSPC、
  permission、file sync、close、rename、directory sync、重读不一致、cleanup 失败、短写/
  `EINTR`、零进度写入，以及 destination、staging、父路径和发布后 FIFO 四类竞争条件；
- 独立 `AtomicWriteCrashProbe` 子进程在 7 个阶段接受 `SIGKILL`，父进程重启读取后只允许
  完整旧版或完整新版；
- library 源码 region coverage 87.04%，line coverage 94.88%；当前 Xcode 26 的 Swift-only
  coverage 未生成 branch records（报告为 0），因此本 Spike 以 region ≥ 80% 和显式故障/
  分支矩阵作为临时门禁；一旦工具生成 branch records，仍执行 branch ≥ 80% 门禁；
- arm64 iOS 26 Release 交叉编译。

## 明确非目标

- `SIGKILL` 只验证进程终止，不等于断电或闪存控制器耐久性认证；
- `fsync` 结论不冒充 `F_FULLFSYNC` 真机断电测试；
- 只保留 POSIX rwx mode，不承诺 ACL、extended attributes、owner 或 iOS Data Protection；
- 不处理 `VaultPath` containment、父目录 symlink 或外部文件协调；
- inode 核对只是 best-effort 检测，不等于 expected-hash/CAS；同路径并发 writer 仍需上层
  Vault actor、文件协调、内容前置条件和恢复策略；
- 崩溃残留 staging 只可发现和保守清理，不能在没有 action ledger 时自动提升；
- 不更新索引、`localModified`、同步账本或远端基线。

这些边界分别由 M0-10 的领域模型和 M3 的编辑保存用例闭合。

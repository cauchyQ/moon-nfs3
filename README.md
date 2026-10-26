# MoonNFS3

MoonNFS3 是用 MoonBit 实现的 NFSv3/TCP 客户端，可以直接访问服务器导出的文件和目录，无需在操作系统中挂载 NFS。

项目支持文件读写、目录管理、流式传输、稳定写入和 COMMIT 校验恢复，并提供有资源上限的目录遍历、目录树传输、前缀校验续传、原子文件发布，以及不同连接之间的复制能力。适合在 MoonBit 后端程序、命令行工具和文件备份流程中接入 NFS 存储。

NFS 客户端和连接管理逻辑由本项目实现；XDR 编解码与 RPC 线格式使用 [`kekeshuo/moonxdr@0.2.0`](https://github.com/kekeshuo/moonxdr)，网络与文件异步 I/O 使用 `moonbitlang/async@0.22.1`。

## 从 MoonCake 安装

在现有 MoonBit 项目中添加依赖：

```sh
moon add cauchyQ/moon-nfs3@0.1.0
```

在使用该库的 `moon.pkg` 中导入 `"cauchyQ/moon-nfs3" @nfs`，具体用法见下文“作为库使用”。

## 从源码运行

```sh
git clone https://github.com/cauchyQ/moon-nfs3.git
cd moon-nfs3
moon update
moon check --deny-warn
moon test --deny-warn
moon run cmd/main -- --help
```

项目默认使用 `wasm` 后端，CI 同时检查 Linux `native` 后端。

本地开发和 CI 固定使用编译器 `v0.10.14+7d59c7ec9`，以避免较新格式化工具迁移语法或整数类型名称所带来的差异。Linux 下可按以下方式安装对应工具链：

```sh
curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash -s -- '0.10.14+7d59c7ec9'
```

## 连接与文件传输

命令行参数的基本顺序为：`命令 服务器 导出路径 [操作参数]`。下面的 `server.example` 和 `/shared` 需要替换为实际服务器地址和导出路径。

```sh
moon run cmd/main -- ls server.example /shared /
moon run cmd/main -- stat server.example /shared reports/data.bin
moon run cmd/main -- get server.example /shared reports/data.bin ./data.bin
moon run cmd/main -- put server.example /shared ./output.bin reports/output.bin
moon run cmd/main -- mkdir server.example /shared reports/new
moon run cmd/main -- mv server.example /shared reports/output.bin reports/new/output.bin
moon run cmd/main -- rm server.example /shared reports/new/output.bin
moon run cmd/main -- rmdir server.example /shared reports/new
moon run cmd/main -- space server.example /shared
```

`get` 创建新的本地文件，`put` 创建新的远端文件；目标已存在时会报错。下载会先检查远端源文件，上传会先打开并检查本地普通文件，再创建目标。传输中途失败可能留下不完整文件；普通上传、下载采用流式处理，不提供并发修改下的文件快照。`mv` 遵循服务器的 RENAME 语义，可能替换已存在的目标。

默认 UID/GID 为 `65534`。AUTH_SYS 传输的是调用者声明的数字身份，不提供加密或强身份认证，应配合可信网络和正确的服务器导出权限使用。部分服务器要求客户端使用保留源端口，目前未提供绑定此类端口的接口。

可通过以下环境变量调整命令行行为：

| 环境变量 | 默认值 | 说明 |
| --- | --- | --- |
| `NFS_UID`, `NFS_GID` | 65534 | AUTH_SYS 使用的 UID 和 GID |
| `NFS_PORT` | 0 | NFS TCP 端口；`0` 表示通过 portmapper v2 发现 |
| `NFS_MOUNT_PORT` | 0 | MOUNTv3 TCP 端口；`0` 表示自动发现 |
| `NFS_BLOCK_SIZE` | 65536 | 客户端传输缓冲区上限，单位为字节 |
| `NFS_MAX_RECORD` | 1048576 | RPC/XDR 记录的大小上限，单位为字节 |
| `NFS_TIMEOUT_MS` | 10000 | 单次 RPC 的超时时间，单位为毫秒 |
| `NFS_MAX_ENTRIES` | 100000 | 单目录条目上限；本地目录树传输等操作也将其用作总节点上限 |
| `NFS_DEST_PORT`, `NFS_DEST_MOUNT_PORT` | 源连接的端口配置 | 跨连接复制时的目标端口 |
| `NFS_DEST_UID`, `NFS_DEST_GID` | 源连接的身份配置 | 目标连接使用的 AUTH_SYS 身份 |

`verify` 默认使用较小的传输块和记录上限（分别为 `4096`、`8192` 字节），用于检验分块和目录分页。它会创建、验证并删除一个独立命名的测试目录，请在可写的临时测试导出中运行。

## 目录传输、续传与原子发布

```sh
moon run cmd/main -- tree server.example /shared reports
moon run cmd/main -- cp-tree server.example /shared reports backups/reports
moon run cmd/main -- get-tree server.example /shared reports ./reports-copy
moon run cmd/main -- verify-tree server.example /shared ./reports-copy reports
moon run cmd/main -- resume-get server.example /shared large.bin ./partial.bin
moon run cmd/main -- resume-put server.example /shared ./large.bin partial.bin
moon run cmd/main -- atomic-put server.example /shared ./result.bin result.bin .result-upload.tmp
moon run cmd/main -- copy-to source-server /source data.bin target-server /target data.bin
```

目录传输要求目标尚不存在。续传要求目标已存在，并逐字节校验已有前缀；前缀不一致或元数据校验发现文件变化时会报错。原子发布先写入新建的暂存文件，再发布到最终路径；失败或操作结果不明时，可能需要检查并处理暂存文件。

完整参数、覆盖规则、资源上限和异步 I/O 用法见[进阶使用说明](docs/usage.md)。

## 作为库使用

在 `moon.pkg` 中导入 `"cauchyQ/moon-nfs3" @nfs`，并在 `moonbitlang/async` 运行时中调用异步接口。以下代码应放在异步入口函数体内：

```moonbit
let client = @nfs.connect_export("server.example", "/shared")
defer client.close()
let handle = client.resolve("reports/data.bin")
let attrs = client.getattr(handle)
let first = client.read_at(handle, 0UL, 1024)
println("文件大小=\{attrs.size}，首块字节数=\{first.data.length()}")
```

`connect_export` 支持自动发现或显式指定端口，通过 MOUNTv3 获取根文件句柄，并通过 FSINFO 协商读写上限。`Options` 可配置 UID/GID、附加组、超时和资源上限。

同一个客户端连接只允许同时执行一个 RPC；并行操作请使用独立客户端。NFS 文件句柄是不透明值，不需要像打开的文件描述符一样在服务器端关闭。`close()` 关闭 TCP 连接；如需清理 mountd 的挂载记录，可另行调用 `unmount_export`。

| 功能 | 主要接口 |
| --- | --- |
| 属性与状态 | `stat`, `getattr`, `metadata`, `access`, `readlink`, `space`, `fsinfo`, `pathconf`, `health_check`, `ping` |
| 查找与路径 | `root_handle`, `lookup`, `resolve`, `canonical_path`, `resolve_following`, `exists` |
| 读取 | `read_at`, `read_exactly_at`, `read_bytes`, `read_text`, `download_to`, `download`, `download_range`, `open_reader` |
| 写入 | `write_at`, `write_all`, `commit`, `write_committed`, `write_bytes`, `write_text`, `upload_from`, `upload`, `upload_range`, `open_writer` |
| 文件管理 | `create_file`, `mkdir`, `ensure_directory`, `setattr`, `set_attributes`, `chmod`, `chown`, `truncate`, `touch`, `rename`, `remove`, `symlink`, `hard_link`, `mknod` |
| 目录遍历 | `read_directory`, `list_dir`, `scan_directory`, `open_directory`, `walk`, `collect_tree`, `disk_usage` |
| 复制与续传 | `copy_file`, `copy_file_checked`, `copy_range`, `copy_tree`, `upload_tree`, `download_tree`, `resume_upload`, `resume_download` |
| 原子发布 | `upload_atomic`, `download_atomic`, `copy_atomic` |
| 跨连接复制 | `copy_file_to`, `copy_tree_to`, `resume_copy_to` |
| 校验与诊断 | `compare_files`, `compare_trees`, `verify_local_file`, `verify_local_tree`, `benchmark_read`, `statistics` |
| 原始字节文件名 | `lookup_bytes`, `create_entry`, `remove_entry`, `rename_entry` |

`read_directory` 支持按页处理，`list_dir` 最多收集 `Options.max_entries` 个条目。原始目录名和符号链接目标使用 `Bytes`，高层路径使用 UTF-8 字符串。普通路径解析拒绝父级遍历，也不会隐式跟随符号链接；这些客户端规则不能替代服务器端的导出权限控制。

`stat` 和下载会复用最后一次 LOOKUP 返回的文件属性，服务器已提供属性时可省去一次 GETATTR；属性缺失或查询导出根目录时会回退到 GETATTR，不跨调用缓存属性。

## 协议行为与支持范围

- 短读按实际返回字节数推进位置，是否到达文件结尾以服务器的 EOF 标志为准；短写只继续发送尚未确认的数据。零进度、长度不一致和 64 位偏移溢出均会报错。
- `write_at`、`write_all` 默认要求 FILE_SYNC，服务器返回更弱的承诺时会报错。`write_committed` 保留有大小上限的数据窗口，提交 UNSTABLE 写入；仍有未持久化的数据或元数据时再校验 COMMIT。若所有写入已确认 FILE_SYNC，则省去额外 COMMIT。待提交数据的服务器重启校验值发生变化时，会在有限重试次数内重放窗口；此机制不提供并发写入保护。
- 目录 cookie 是不透明的分页标识。cookie 失效、校验值变化或分页游标循环时会报错，不会静默重新遍历。
- RPC 帧格式错误、XID 不匹配或传输失败会关闭连接。修改操作的 RPC/NFS 回复丢失或无法解码时会报告 `OutcomeUnknown`，因为服务器可能已执行该操作，客户端不会盲目重试。
- `create_file` 默认使用 GUARDED 模式。显式传入八字节校验值时改用 EXCLUSIVE 模式，并按协议要求随后设置属性。

当前实现覆盖使用 TCP 和 AUTH_SYS 的 NFSv3 过程号 `0` 至 `21`。NFSv4、UDP、Kerberos/RPCSEC_GSS、NLM 锁及内核挂载不在本版本范围内。服务器状态码通过 `NfsError::Status` 保留；特殊节点创建及其他可选能力仍取决于服务器支持和导出权限。

## 测试与验证

```sh
moon check --deny-warn
moon build --deny-warn
moon test --deny-warn
moon info
moon fmt
git diff --exit-code
python validation/source_lines.py --min-implementation 4000
```

故障测试使用独立的模拟 TCP 对端，覆盖短读写、64 位偏移、写入校验值变化、XID 不匹配、回复丢失、过期目录 cookie 和分页循环等场景。该对端仅为测试夹具。

完整联调使用 NFS-Ganesha 4.3 的 VFS 后端，在真实本地文件系统上验证指定端口和端口发现两种连接方式，覆盖二进制及空文件往返、SHA-256 比对、多页目录、属性与时间戳、链接和 FIFO 创建、COMMIT、重命名、截断、清理、覆盖保护、重叠区间复制、续传、原子发布、目录树及跨连接复制。CI 会重复执行这些外部服务器检查。

复现步骤和测试证据见[真实服务器联调说明](validation/README.md)。尚未验证断电后的物理持久性、大型稀疏文件、其他 NAS 产品或与其他客户端的性能对比。

`validation/source_lines.py` 会分别统计实现和测试代码，实现行数排除空行、整行注释、依赖、生成接口、测试文件、内嵌测试及 CLI 的 `verify` 自检代码。CI 会检查实现代码保持在 4,000 行以上；代码行数不能替代行为验证。

## 参考资料与来源说明

协议实现依据：

- [RFC 1813](https://www.rfc-editor.org/rfc/rfc1813.html)：NFSv3 与 MOUNTv3。
- [RFC 5531](https://www.rfc-editor.org/rfc/rfc5531.html)：ONC RPCv2。
- [RFC 4506](https://www.rfc-editor.org/rfc/rfc4506.html)：XDR。
- [RFC 1833](https://www.rfc-editor.org/rfc/rfc1833.html)：portmapper v2。

设计背景参考 Sandberg 等人的 *Design and Implementation of the Sun Network Filesystem*（USENIX 1985），以及 Pawlowski 等人的 *NFS Version 3: Design and Implementation*（USENIX 1994）。协议行为以 RFC 为准，不以历史论文中的性能数字作为本项目的性能依据。

## 许可证

本项目采用 Apache-2.0，详见 [LICENSE](LICENSE)，开发过程中使用了 AI 辅助。MoonXDR 采用 MIT 许可证，官方 MoonBit core/async 采用 Apache-2.0。仓库未打包 libnfs、go-nfs-client 或 NFS-Ganesha 的源码；测试数据由本地生成，Ganesha 配置与验证脚本由本项目编写。

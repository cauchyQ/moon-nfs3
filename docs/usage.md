# 进阶使用说明

所有路径均相对于选定的导出目录。普通路径解析不会跟随符号链接；需要显式调用 `canonical_path` 或 `resolve_following`。它们会限制跟随链接的次数，并拒绝越过导出根目录的目标。绝对链接目标以导出根目录为起点，不以服务器操作系统的根目录为起点。

## 查询和修改元数据

`metadata(handle)` 返回包含纳秒精度的访问、修改和状态变更时间，以及设备号和普通文件属性。`set_attributes` 可以分别指定权限、UID、GID 和大小；访问时间和修改时间支持 `KeepTime`（保持不变）、`ServerTime`（服务器当前时间）及 `ExactTime(Timestamp)`（指定时间）。可选参数 `ctime_guard` 对应 NFS SETATTR 的状态变更时间检查，检查不通过时返回服务器状态错误。

```sh
moon run cmd/main -- inspect server /shared reports/result.bin
moon run cmd/main -- chmod server /shared reports/result.bin 640
moon run cmd/main -- chown server /shared reports/result.bin 1000 -
moon run cmd/main -- settime server /shared reports/result.bin 1700000000 123456789
moon run cmd/main -- symlink server /shared latest reports/result.bin
moon run cmd/main -- readlink server /shared latest
moon run cmd/main -- realpath server /shared latest
moon run cmd/main -- doctor server /shared
```

`chown` 中的 `-` 表示保持对应身份不变。`touch` 请求使用服务器当前时间，需要服务器正确实现该请求。`mkfifo` 创建命名管道；库还提供块设备、字符设备和套接字节点的创建接口，具体支持和权限由服务器决定。

## 有资源上限的遍历与目录树传输

`open_directory` 返回一个目录游标，最多持有一页已解码的目录条目。`walk` 使用显式目录栈进行深度优先遍历，并检查目录循环、深度上限和节点数量上限。遍历会返回符号链接条目，但不会跟随它们。两种游标均会在出错时停止，也可以提前关闭。

高层目录树路径要求文件名是 UTF-8；基于文件句柄和字节文件名的接口可保留任意合法的 NFS 文件名字节。遍历过程不提供目录快照。

```sh
moon run cmd/main -- tree server /shared reports
moon run cmd/main -- du server /shared reports
moon run cmd/main -- mkdirs server /shared backups/2026/october
moon run cmd/main -- cp-tree server /shared reports backups/reports
moon run cmd/main -- diff-tree server /shared reports backups/reports
moon run cmd/main -- get-tree server /shared reports ./reports-copy
moon run cmd/main -- verify-tree server /shared ./reports-copy reports
moon run cmd/main -- put-tree server /shared ./reports-copy uploads/reports
```

目录树的目标路径必须尚不存在。远端目录树复制会保留符号链接，并可选择保留权限；复制过程中先赋予新建目录和文件可供所有者写入的权限，完成后再恢复最终权限。本地目录树传输仅接受普通文件和目录，在预检查阶段拒绝符号链接和特殊节点。文件名使用可跨平台映射的子集，并检查 Windows 保留设备名等情况。

传输失败可能留下不完整的目标。并发修改下的源文件和目标文件不受快照或事务保护。

`disk_usage` 对同一 inode 的字节数只统计一次，避免重复计算硬链接。`compare_trees` 会读取大小相同的普通文件进行内容比较，不会仅凭时间戳或文件大小判定相等。`verify_local_tree` 采用相同原则校验本地与远端目录树。

`rm-tree` 用于显式递归删除：先收集受数量和深度上限约束的遍历结果，拒绝删除导出根目录，再检查文件身份，按先子项后父目录的顺序删除。并发重命名仍可能使删除失败。

## 区间操作与续传

```sh
moon run cmd/main -- get-range server /shared huge.bin ./slice.bin 4294967296 65536
moon run cmd/main -- copy-range server /shared huge.bin scratch.bin 0 1048576 65536
moon run cmd/main -- resume-get server /shared huge.bin ./partial.bin
moon run cmd/main -- resume-put server /shared ./huge.bin partial.bin
```

区间操作保留 64 位偏移，并限制传输缓冲区大小。同一远端 inode 内的区间重叠时，`copy_range` 会按需要从后向前复制，也支持通过不同硬链接访问同一文件的情况。`read_exactly_at` 会累积短读结果，提前到达 EOF 时会报错。

续传要求目标已存在且为普通文件，追加前会逐字节比较已有前缀。目标比源更大或前缀不一致时会报错，不会静默重新开始或替换已有文件。首次追加前还会检查远端版本和本地时间戳，续传下载完成后再次检查远端源版本。这些检查用于发现元数据中可见的变化，不提供文件锁或快照。

续传上传的尾部块大小使用上传缓冲区上限，不受服务器 READ 上限限制；目标已完整时，只进行一次最终远端版本查询。

文件比较和跨连接前缀校验会保留较大回复中尚未比较的数据，避免另一侧发生短读时重复下载。每个输入最多保留一个读取块。

## 原子文件发布

```sh
moon run cmd/main -- atomic-put server /shared ./result.bin result.bin .result-upload.tmp
moon run cmd/main -- atomic-replace server /shared ./result.bin result.bin .result-upload.tmp
moon run cmd/main -- atomic-copy server /shared source.bin copy.bin .copy.tmp
moon run cmd/main -- atomic-get server /shared result.bin ./result.bin ./result-download.tmp
```

远端暂存文件必须尚不存在，并与最终目标位于同一目录。不覆盖模式通过 LINK 发布，利用服务器的 EXIST 错误保护已存在的目标；允许替换的模式使用 RENAME。服务器需要支持对应操作。

原子下载会先创建新的本地暂存文件，校验远端版本，同步并关闭文件后，再请求不覆盖目标的重命名。暂存文件应放在目标所在的本地文件系统中。

服务器或客户端崩溃、清理失败、修改结果不明时，都可能留下暂存文件或已经发布的目标，重试前应先检查。客户端不会盲目回滚或重放修改操作。当前未显式同步目录项，因此不能据此保证任意客户端断电后的持久性。

`FileVersion` 检查大小、inode 身份，以及纳秒精度的修改和状态变更时间。时间戳精度不足或服务器未正确更新时间时，部分变化可能无法被发现。这属于乐观校验，不是文件锁。

## 不同连接之间的复制与异步 I/O

```sh
moon run cmd/main -- copy-to source-server /source data.bin target-server /target data.bin
moon run cmd/main -- resume-to source-server /source data.bin target-server /target partial.bin
moon run cmd/main -- tree-to source-server /source reports target-server /target reports
moon run cmd/main -- stream-copy server /shared source.bin dest.bin
```

跨连接复制接口接收目标 `Client`，两端各自使用协商后的传输上限。命令行可通过 `NFS_DEST_*` 覆盖目标连接的端口和身份。当前联调验证了访问同一导出的不同连接，尚未验证两种独立 NAS 产品之间的迁移。

`open_reader` 使用 async/io 公开的 `MemoryReader` 适配器，通过背压控制数据流。`RemoteWriter` 实现 async/io 的 `Writer` 接口，并处理 FILE_SYNC 短写。

停止读取时应关闭 reader。reader 可能在后台执行 RPC，因此关闭前应保留其客户端连接，避免并发执行其他操作。如果消费端也需要执行 NFS RPC，请使用另一客户端；`stream-copy` 会为此创建第二个连接。

## 诊断与读取基准测试

```sh
moon run cmd/main -- exports server
moon run cmd/main -- services server
moon run cmd/main -- mounts server
moon run cmd/main -- bench-read server /shared data.bin 3
```

`statistics` 统计 RPC 尝试次数、完整回复数、载荷字节数和失败次数，字节数不含传输帧开销。`health_check` 进行只读的服务、访问权限、容量和文件系统能力检查。

`benchmark_read` 限制总读取字节数，并在每轮读取后检查源文件版本。计时使用毫秒精度的系统时钟，服务器及操作系统缓存会影响吞吐结果；不能用单次本地结果推断优于其他客户端。

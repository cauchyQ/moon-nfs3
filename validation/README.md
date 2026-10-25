# 真实服务器联调说明

本目录中的配置和验证脚本由本项目编写。NFS-Ganesha 需要单独安装，仓库不分发其服务器源码或第三方测试数据。所有测试数据均由本地生成，完整联调使用 VFS 后端，在真实本地文件系统中的临时目录上运行。

## 准备测试服务器

在临时 Ubuntu 测试环境中执行以下命令。VFS 后端要求底层文件系统支持文件句柄。

```sh
sudo apt-get install nfs-ganesha nfs-ganesha-vfs rpcbind
sudo systemctl stop nfs-ganesha
sudo systemctl start rpcbind
sudo mkdir -p /run/ganesha /var/tmp/moonnfs3-vfs
sudo ganesha.nfsd -f "$PWD/validation/ganesha-vfs.conf" -L /tmp/moonnfs3-ganesha.log -p /run/ganesha/moonnfs3.pid
python validation/integration.py
python validation/integration.py --discovery
```

访问 WSL 或其他 Linux 机器时，可传入 `--host HOST`；使用其他导出目录时，可传入 `--export PATH`。测试脚本仅为这套临时测试配置选择 UID/GID `0`，会创建独立命名的远端子目录，并在成功后删除；失败时可能留下该目录。不要把这套允许读写且不压缩 root 身份的测试导出暴露到公网。

## 验证内容

CLI 的 `verify` 使用 8 KiB 记录上限和 4 KiB 传输块，以触发分块和目录分页。联调脚本还会通过实际 CLI 命令，对外部服务器验证以下行为：

- 空文件及 400,128 字节文件传输、SHA-256 一致性和覆盖保护。
- 下载源缺失或不是普通文件、本地目录作为上传源时的预检查。
- 完整元数据、纳秒精度时间设置、使用服务器时间的 `touch`、权限及身份设置、FSINFO、导出和挂载列表、portmapper 映射、只读健康检查。
- 符号链接、硬链接、链接循环、越过导出根目录的目标拒绝，以及 FIFO 创建。
- 有大小上限的区间下载，以及通过硬链接访问同一文件时的重叠区间复制。
- 校验已有前缀后续传，以及前缀不一致时的拒绝行为。
- 普通文件复制、版本校验复制、async/io 流式复制及不同连接之间的复制。
- 经暂存文件进行的不覆盖发布和替换发布、暂存文件清理、本地已有目标保护，以及远端原子复制。
- 目录树上传下载、空文件及空目录、隐藏文件和 Unicode 文件名、字节内容校验、远端及跨连接目录树复制、权限比对和递归删除。
- 限制总读取字节数并检查文件版本的只读吞吐测量。

## 已验证的环境与结果

2026-10-25，Windows/WSL 下针对 NFS-Ganesha 4.3 VFS 后端的指定端口、端口发现两种联调均已通过。使用的编译器为 `v0.10.14+7d59c7ec9`，依赖版本为 async `0.22.1`、moonxdr `0.2.0`。

测试数据的 SHA-256：

- 400,128 字节：`8e8b15de9040324a494685ad7fa5ef3f5840340e44f00cf308dc8326bfaf6b91`。
- 160,007 字节：`1b6a3f047dc8ece74f09b4a9d94c4f14533507ab9e3d974cd2f1caef861b9a25`。

较早的 `ganesha.conf` 保留为 MEM 后端的基础测试配置。扩展测试时，Ganesha 4.3 MEM 在 SET_TO_SERVER_TIME 后返回了值为 `1073741823` 的时间戳纳秒字段；独立的原始 RPC 探测确认了该越界回复。客户端仍拒绝该值，因此完整联调改用 VFS；`ServerTime` 的编码另有协议级测试。

模拟 TCP 对端用于补充故障注入测试，覆盖短读写、超过 4 GiB 的偏移、服务器重启校验值变化、修改回复丢失或格式错误、XID 不匹配、过期 cookie、游标循环、重叠复制方向和遍历数量上限。这些是测试夹具，不作为生产服务器实现。

回归测试还覆盖不对称短读的缓冲复用、精确的前缀长度边界、两侧同时提前 EOF、续传追加前的元数据变化，以及 READ 上限仅一字节时的上传。在四字节短读测试中，比较只需要五次 READ RPC，每侧的每个输入字节只读取一次。

上述测试尚未验证断电后的物理持久性、大型稀疏文件、其他 NAS 产品、跨产品迁移、真实服务器上的块设备或字符设备创建、内存性能分析，以及与其他客户端的性能对比。不能从单机 VFS 联调推断这些性质。

## 复核代码行数

以下脚本分别统计实现和测试代码。实现行数排除测试文件、内嵌测试、CLI 自检、空行、整行注释、依赖和生成接口：

```sh
python validation/source_lines.py --min-implementation 4000
python validation/source_lines.py --details
```

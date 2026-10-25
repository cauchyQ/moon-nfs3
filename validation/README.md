# External-server verification

Configuration and test scripts are original. NFS-Ganesha is installed separately;
no server source or third-party fixture data is redistributed. All payloads are
generated locally. The full suite uses the VFS backend and a disposable directory
on an actual local filesystem.

On a disposable Ubuntu host (the filesystem must support file handles for VFS):

```sh
sudo apt-get install nfs-ganesha nfs-ganesha-vfs rpcbind
sudo systemctl stop nfs-ganesha
sudo systemctl start rpcbind
sudo mkdir -p /run/ganesha /var/tmp/moonnfs3-vfs
sudo ganesha.nfsd -f "$PWD/validation/ganesha-vfs.conf" -L /tmp/moonnfs3-ganesha.log -p /run/ganesha/moonnfs3.pid
python validation/integration.py
python validation/integration.py --discovery
```

Use `--host HOST` for WSL or another Linux machine and `--export PATH` for another
export. The runner selects UID/GID 0 only for this fixture. It creates unique
remote subdirectories and removes them after success; failures may leave their
directory behind. Do not expose this RW/no-root-squash test export publicly.

The CLI `verify` selects 8 KiB record and 4 KiB transfer budgets to force block
boundaries and directory pagination. The runner also exercises these actual CLI
paths against the external server:

- Empty and 400,128-byte file transfer, SHA-256 equality and overwrite protection.
- Missing/non-regular download sources and local directory upload preflight.
- Full metadata, exact nanosecond time setting, server-time touch, chmod/chown,
  FSINFO, export and mount lists, portmapper mappings and read-only health checks.
- Symbolic links, hard links, link loops, root escape rejection and FIFO creation.
- Bounded range downloads and overlapping range copies through hard-link aliases.
- Resume with a verified prefix, including mismatched-prefix rejection.
- File copies, checked copies, async/io streaming and distinct-connection copies.
- Staged no-replace and replacement publication, staging cleanup, existing local
  destination guards and atomic remote copy.
- Directory upload/download, empty/hidden/Unicode entries, byte-content verification,
  remote and cross-client tree copies, mode comparison and recursive removal.
- Read-only throughput measurement with a byte budget and version checks.

Windows/WSL local VFS result (2026-10-25): explicit-port and discovery runs passed
against NFS-Ganesha 4.3. Compiler `v0.10.14+7d59c7ec9`, async `0.22.1`, moonxdr `0.2.0`.

Payload SHA-256 values:

- 400,128 bytes: `8e8b15de9040324a494685ad7fa5ef3f5840340e44f00cf308dc8326bfaf6b91`.
- 160,007 bytes: `1b6a3f047dc8ece74f09b4a9d94c4f14533507ab9e3d974cd2f1caef861b9a25`.

The older `ganesha.conf` remains a MEM-only fixture for the earlier basic suite.
During extension testing, Ganesha 4.3 MEM returned timestamp nanoseconds
`1073741823` after SET_TO_SERVER_TIME. An independent raw RPC probe confirmed the
out-of-range value in the reply. The client continues rejecting it. The full suite
therefore uses VFS; the ServerTime discriminant has a separate wire-level test.

Synthetic TCP peer tests complement server interop: short I/O, offsets above 4 GiB,
changed boot verifiers, lost/malformed mutation replies, XID mismatch, stale
cookies, cursor loops, overlap direction and traversal budgets. This is fault
injection, not another implementation claimed as a production server.
Additional regressions check asymmetric short-read buffering, exact prefix bounds,
equal early EOF, metadata changes before resume append and an upload with a one-byte
READ maximum. In the four-byte short-read fixture, comparison needs five READ RPCs
instead of refetching the larger input for each byte; each input byte is fetched once.

Physical power-loss durability, large sparse files, independent NAS products,
cross-product migration, block/character device creation on real servers, memory
profiling and comparative performance remain unvalidated. VFS tests on one host
do not establish those properties.

Count source without tests, inline test blocks, CLI self-checks, blank/comment
lines, dependencies or generated interfaces:

```sh
python validation/source_lines.py --min-implementation 4000
python validation/source_lines.py --details
```

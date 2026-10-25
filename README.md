# MoonNFS3

Access an NFSv3 export from a MoonBit program over TCP, without mounting it
in the operating system. The library supports file and directory operations,
streaming transfers, stable writes and verifier-checked COMMIT recovery.
It also includes bounded directory traversal, tree transfer, prefix-checked
resume, atomic file publication and cross-connection copies.

This repository implements the connection and NFS client. It uses
[`kekeshuo/moonxdr@0.2.0`](https://github.com/kekeshuo/moonxdr) for XDR and RPC
wire data, and `moonbitlang/async@0.22.1` for sockets and file I/O.

## Run from source

```sh
git clone https://github.com/cauchyQ/moon-nfs3.git
cd moon-nfs3
moon update
moon check --deny-warn
moon test --deny-warn
moon run cmd/main -- --help
```

Current installation is from source; the package has not been published to
MoonCake. The default backend is `wasm`; Linux native is also included in CI.
Local development uses compiler `v0.10.14+7d59c7ec9`.
CI pins that toolchain because newer formatters may migrate syntax and integer
type names. On Linux it can be installed with
`curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash -s -- '0.10.14+7d59c7ec9'`.

## Connect and transfer

The CLI takes a command, host, export, then command-specific paths:

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

`get` creates a fresh local file; `put` creates a fresh remote file.
An existing destination fails instead of being overwritten. Downloads check
the remote source before creating a local file. Local uploads require an opened
regular file before creating the remote destination. A transfer that
fails part-way can leave a partial destination. Upload/download are streams,
not snapshots of concurrently modified files. `mv` uses the server's RENAME
semantics, which may replace an existing destination.

The default UID/GID is 65534. AUTH_SYS transmits caller-asserted numeric
credentials and provides neither encryption nor strong user authentication.
Use an appropriately configured trusted network/export. Some servers require
a reserved source port; binding such a port is not currently exposed here.

The following environment variables configure the CLI:

| Variable | Default | Purpose |
| --- | --- | --- |
| `NFS_UID`, `NFS_GID` | 65534 | AUTH_SYS numeric identity |
| `NFS_PORT` | 0 | NFS TCP port; 0 discovers it via portmapper v2 |
| `NFS_MOUNT_PORT` | 0 | MOUNTv3 TCP port; 0 discovers it |
| `NFS_BLOCK_SIZE` | 65536 | Client transfer-buffer budget |
| `NFS_MAX_RECORD` | 1048576 | RPC/XDR record budget |
| `NFS_TIMEOUT_MS` | 10000 | Timeout per RPC |
| `NFS_MAX_ENTRIES` | 100000 | Directory and tree collection budget |
| `NFS_DEST_PORT`, `NFS_DEST_MOUNT_PORT` | Source port settings | Destination connection for cross-client copies |
| `NFS_DEST_UID`, `NFS_DEST_GID` | Source identity | AUTH_SYS identity on the destination connection |

`verify` uses smaller default budgets (4096/8192) to force block boundaries
and directory pagination. It creates, checks and deletes a uniquely named
test directory, and therefore needs a writable disposable export.

## Library API

Import `"cauchyQ/moon-nfs3" @nfs` in `moon.pkg`. Run asynchronous calls inside
the `moonbitlang/async` runtime. For example, the body of an async entry point:

```moonbit
let client = @nfs.connect_export("server.example", "/shared")
defer client.close()
let handle = client.resolve("reports/data.bin")
let attrs = client.getattr(handle)
let first = client.read_at(handle, 0UL, 1024)
println("size=\{attrs.size}, first block=\{first.data.length()}")
```

`connect_export` discovers ports (or accepts explicit ones), obtains the root
file handle through MOUNTv3 and negotiates read/write maxima through FSINFO.
The caller may pass `Options` for UID/GID, groups, timeout and resource limits.
One client accepts one outstanding RPC; use independent clients for parallel
work. File handles are opaque values, not open descriptors requiring a server
close call. `close()` closes TCP; `unmount_export` separately removes mountd
bookkeeping if required.

| Operation | Methods |
| --- | --- |
| Inspect | `stat`, `getattr`, `metadata`, `access`, `readlink`, `space`, `fsinfo`, `pathconf`, `health_check`, `ping` |
| Find | `root_handle`, `lookup`, `resolve`, `canonical_path`, `resolve_following`, `exists` |
| Read | `read_at`, `read_exactly_at`, `read_bytes`, `read_text`, `download_to`, `download`, `download_range`, `open_reader` |
| Write | `write_at`, `write_all`, `commit`, `write_committed`, `write_bytes`, `write_text`, `upload_from`, `upload`, `upload_range`, `open_writer` |
| Manage | `create_file`, `mkdir`, `ensure_directory`, `setattr`, `set_attributes`, `chmod`, `chown`, `truncate`, `touch`, `rename`, `remove`, `symlink`, `hard_link`, `mknod` |
| Directory | `read_directory`, `list_dir`, `scan_directory`, `open_directory`, `walk`, `collect_tree`, `disk_usage` |
| Transfer | `copy_file`, `copy_file_checked`, `copy_range`, `copy_tree`, `upload_tree`, `download_tree`, `resume_upload`, `resume_download` |
| Publication | `upload_atomic`, `download_atomic`, `copy_atomic` |
| Cross-client | `copy_file_to`, `copy_tree_to`, `resume_copy_to` |
| Verify | `compare_files`, `compare_trees`, `verify_local_file`, `verify_local_tree`, `benchmark_read`, `statistics` |
| Raw names | `lookup_bytes`, `create_entry`, `remove_entry`, `rename_entry` |

`read_directory` allows incremental consumption; `list_dir` collects entries
up to `Options.max_entries`. Raw directory names and link targets are `Bytes`;
high-level paths are UTF-8 strings. Parent traversal is rejected and symbolic
links are not implicitly followed. Client path handling is not a replacement
for server-side export permissions.

`stat` and downloads reuse attributes returned by the final LOOKUP, avoiding
an extra GETATTR call when the server supplies them. Missing attributes and
export-root paths fall back to GETATTR. Attributes are not cached across calls.

## Correctness rules

- Short reads are advanced by their actual count, and EOF is taken from the
  server flag. Short writes resend only unacknowledged bytes. Zero progress,
  inconsistent lengths and 64-bit offset overflow are errors.
- `write_at` and `write_all` default to FILE_SYNC and reject a weaker reply.
  `write_committed` retains one bounded data window, submits UNSTABLE writes,
  and verifies COMMIT when data or metadata remains uncommitted. If every
  write is already confirmed FILE_SYNC, the extra COMMIT call is skipped.
  A changed boot verifier for pending data replays that window within a
  finite retry budget. It does not promise protection against concurrent writers.
- Directory cookies are opaque. Stale cookies, changed verifiers and repeated pagination cursors
  are surfaced as errors; traversal is not silently restarted.
- Invalid RPC framing, wrong XIDs and transport failures close the connection.
  A mutation with a lost or undecodable RPC/NFS reply raises `OutcomeUnknown`; it is not
  blindly retried. The operation may already have executed on the server.
- `create_file` is GUARDED by default. An explicit eight-byte verifier selects
  EXCLUSIVE creation and is followed by SETATTR as required by the protocol.

This scope covers NFSv3 procedure numbers 0 through 21 over TCP with AUTH_SYS.
NFSv4, UDP, Kerberos/RPCSEC_GSS, NLM locking and kernel mounts are outside
this version. Server status values are preserved in `NfsError::Status`.
Special node creation and optional filesystem features still depend on server
support and export permissions. See [advanced usage and boundaries](docs/usage.md)
for tree transfers, resume, atomic publication, cross-client copies and I/O adapters.

## Verification

```sh
moon check --deny-warn
moon build --deny-warn
moon test --deny-warn
moon info
moon fmt
git diff --exit-code
python validation/source_lines.py --min-implementation 4000
```

Fault tests use an independent synthetic TCP peer to test short I/O,
64-bit wire offsets, changed write verifiers, XID mismatch, lost replies,
stale directory cookies and pagination loops. The synthetic peer is a test
fixture, not a production NFS server.

The complete integration suite runs against NFS-Ganesha 4.3's VFS backend on
a real local filesystem, using explicit ports and portmapper discovery. It includes
binary and empty-file round trips, SHA-256 comparison, multi-page directories,
attributes, timestamps, links, FIFO creation, COMMIT, rename, truncate, cleanup,
overwrite guards, overlapping range copies, resumed transfers, atomic publication
and tree/cross-client round trips.
See [validation instructions and evidence](validation/README.md). CI repeats
the external-server checks. Physical power-loss durability, large sparse files,
other NAS products and comparative performance have not been validated.

`validation/source_lines.py` reports implementation and tests separately. Its
implementation count excludes blank/comment lines, dependencies, generated
interfaces, test files, inline test blocks and the CLI `verify` self-check.
The source-count check in CI preserves the requested 4,000-line implementation
milestone; line count does not substitute for behavior checks.

## References and provenance

The implementation follows [RFC 1813](https://www.rfc-editor.org/rfc/rfc1813.html)
(NFSv3 and MOUNTv3), [RFC 5531](https://www.rfc-editor.org/rfc/rfc5531.html)
(ONC RPCv2), [RFC 4506](https://www.rfc-editor.org/rfc/rfc4506.html) (XDR),
and [RFC 1833](https://www.rfc-editor.org/rfc/rfc1833.html) (portmapper v2).

Design background: Sandberg et al., *Design and Implementation of the Sun
Network Filesystem* (USENIX 1985); Pawlowski et al., *NFS Version 3: Design
and Implementation* (USENIX 1994). Protocol behavior is determined by the
RFCs, not by historical performance numbers in those papers.

Apache-2.0; see [LICENSE](LICENSE). Developed with AI assistance. MoonXDR
is MIT-licensed; official MoonBit core/async are Apache-2.0. No libnfs,
go-nfs-client or NFS-Ganesha source is bundled. All test payloads are generated
locally; the Ganesha configuration and validation scripts are original.

# File operations beyond single-file transfers

All paths are relative to the selected export. Ordinary resolution never follows
symbolic links. `canonical_path` and `resolve_following` opt into link traversal,
limit the number of links, and reject targets escaping the export root. Absolute
link targets are interpreted from that root, not from a server's operating-system root.

## Inspect and modify metadata

`metadata(handle)` returns nanosecond access, modification and change times,
device numbers and ordinary attributes. `set_attributes` accepts independent
optional mode, UID, GID and size changes, plus `KeepTime`, `ServerTime` or
`ExactTime(Timestamp)` for access and modification times. An optional
`ctime_guard` provides the NFS SETATTR guard; a mismatch is a server status error.

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

`chown` uses `-` to leave one identity unchanged. `touch` requests server time;
the server must implement that request correctly. `mkfifo` creates a named pipe;
the library also provides block, character and socket node variants. Support
and permissions are controlled by the server.

## Bounded traversal and tree transfer

`open_directory` returns a cursor holding at most one decoded directory page.
`walk` returns a depth-first iterator with an explicit directory stack, cycle
detection, a depth budget and a node budget. Links are yielded without being
followed. Both cursors stop on error and can be closed early. UTF-8 is required
for high-level tree paths; handle-relative byte-name methods preserve arbitrary
NFS filename bytes. Traversal is not a directory snapshot.

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

Tree destinations must be fresh. Remote tree copies preserve links and optionally
modes; directories and files receive writable owner permissions while data is
copied, then final modes are restored. Local tree transfers accept regular files
and directories only, and reject links and special nodes during preflight. They
use a portable filename subset, including checks for Windows device aliases.
Failed transfers can leave partial destinations. Concurrent source/destination
changes are not supported as a snapshot or transaction.

`disk_usage` counts each inode's bytes once, avoiding double counting hard links.
`compare_trees` reads equal-size regular files rather than assuming timestamps
or sizes prove equal content. `verify_local_tree` checks a local/remote round trip
in the same way. Recursive removal is explicit through `rm-tree`: it first
collects the bounded traversal, refuses the export root, then checks identities
and deletes children before parents. Concurrent renames can still make it fail.

## Ranges and resume

```sh
moon run cmd/main -- get-range server /shared huge.bin ./slice.bin 4294967296 65536
moon run cmd/main -- copy-range server /shared huge.bin scratch.bin 0 1048576 65536
moon run cmd/main -- resume-get server /shared huge.bin ./partial.bin
moon run cmd/main -- resume-put server /shared ./huge.bin partial.bin
```

Range operations retain 64-bit offsets and bounded transfer buffers. `copy_range`
handles overlapping ranges in one remote inode by copying backwards when needed,
including hard-link aliases. `read_exactly_at` accumulates short replies and
reports early EOF. Resume methods require existing regular destinations, compare
every prefix byte before appending and reject an oversized or mismatched prefix.
They do not silently restart or replace an existing file.
Before the first append they recheck the remote version and local timestamps;
downloads also recheck the source version after transfer. These checks detect
changes visible in the metadata and do not provide locking or a snapshot.
Upload tails use the upload buffer budget independently of the server's READ
maximum. An already complete upload uses one final remote version query.

File comparison and cross-client prefix verification retain unread data from
larger replies when the other input returns short reads. They keep at most one
read block per input and do not refetch the retained bytes.

## Atomic publication

```sh
moon run cmd/main -- atomic-put server /shared ./result.bin result.bin .result-upload.tmp
moon run cmd/main -- atomic-replace server /shared ./result.bin result.bin .result-upload.tmp
moon run cmd/main -- atomic-copy server /shared source.bin copy.bin .copy.tmp
moon run cmd/main -- atomic-get server /shared result.bin ./result.bin ./result-download.tmp
```

Remote staging must be a fresh sibling of the final path. The no-replace path
publishes with LINK, whose EXIST result protects an already-created destination;
the replacement path uses RENAME. These require the corresponding server support.
Local download stages a fresh file, validates the remote version, syncs and closes
the file, then requests a no-replace rename. Put local staging on the destination
filesystem. A server/client crash, failed cleanup or ambiguous mutation can leave
staging files or a published destination. Inspect them before retrying; no blind
rollback or mutation replay is attempted. Directory entries are not explicitly
fsynced, so publication does not promise survival of arbitrary client power loss.

`FileVersion` checks size, inode identity and nanosecond modification/change times.
They detect changes visible in those fields; coarse timestamps or a server that
does not update them can hide changes. They provide optimistic validation, not a lock.

## Different connections and async I/O

```sh
moon run cmd/main -- copy-to source-server /source data.bin target-server /target data.bin
moon run cmd/main -- resume-to source-server /source data.bin target-server /target partial.bin
moon run cmd/main -- tree-to source-server /source reports target-server /target reports
moon run cmd/main -- stream-copy server /shared source.bin dest.bin
```

Cross-client methods accept a destination `Client`; each uses that connection's
own negotiated limits. CLI destination ports and identity may be overridden using
`NFS_DEST_*`. The current interoperability fixture tests distinct connections to
one export; two independent NAS products have not been validated together.

`open_reader` uses async/io's public backpressured `MemoryReader` adapter.
`RemoteWriter` implements async/io `Writer` and handles short FILE_SYNC writes.
Close readers you stop consuming. A reader can run a background RPC, so reserve
its client connection until it is closed. Use another client when a consumer also
needs NFS RPCs. `stream-copy` follows that rule by creating a second connection.

## Diagnostics and benchmarking

```sh
moon run cmd/main -- exports server
moon run cmd/main -- services server
moon run cmd/main -- mounts server
moon run cmd/main -- bench-read server /shared data.bin 3
```

`statistics` counts RPC attempts, complete replies, payload bytes and failures;
byte counts exclude transport framing. `health_check` performs read-only service,
access, capacity and filesystem-capability checks. `benchmark_read` enforces a
total byte budget and checks source versions after each round. Its clock is
wall-clock milliseconds; server/OS caches affect throughput. A local benchmark
result is not evidence of superiority over another client.

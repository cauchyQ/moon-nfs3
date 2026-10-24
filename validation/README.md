# External-server verification

This directory contains original configuration and test scripts. NFS-Ganesha
is installed separately; no server implementation or third-party fixtures
are redistributed here. FSAL MEM is a real external protocol implementation
but keeps data in memory. It cannot verify physical durability across power loss.

On a disposable Ubuntu host:

```sh
sudo apt-get install nfs-ganesha nfs-ganesha-mem rpcbind
sudo systemctl stop nfs-ganesha
sudo systemctl start rpcbind
sudo mkdir -p /run/ganesha
sudo ganesha.nfsd -f "$PWD/validation/ganesha.conf" -L /tmp/moonnfs3-ganesha.log -p /run/ganesha/moonnfs3.pid
python validation/integration.py
python validation/integration.py --discovery
```

Use `--host HOST` to test a separate Linux machine or WSL server. The script
selects UID/GID 0 only for this disposable test export; it creates uniquely
named test directories. A failed test may leave its directory behind. Do not
use the RW/no-root-squash MEM configuration for a public or production server.

The CLI `verify` command intentionally selects an 8 KiB record budget and
4 KiB transfer blocks, then checks a directory too large for one response.
It tests binary I/O, write verifiers, COMMIT, READDIR/PLUS, attributes,
rename, truncate and removal. The Python runner also checks empty and
400,128-byte local files, SHA-256 equality, missing-file errors without creating
local destinations, and rejection
of existing upload/download destinations. Portmapper discovery is tested in
a second run.

Windows/WSL local result (2026-10-24): both explicit-port and discovery runs
passed against NFS-Ganesha 4.3 with its MEM backend. MoonBit compiler:
`v0.10.14+7d59c7ec9`, async `0.22.1`, moonxdr `0.2.0`.
400,128-byte payload SHA-256:
`8e8b15de9040324a494685ad7fa5ef3f5840340e44f00cf308dc8326bfaf6b91`.

64-bit offsets, short writes, stale cookies and changed boot verifiers are
tested using a separate synthetic TCP peer in `fault_wbtest.mbt` and
`recovery_wbtest.mbt`. The latter also checks commitment upgrades, invalid
mutation replies and changed directory views. This is
complementary fault injection, not a substitute for the external server.
Large sparse-file behavior, other NAS implementations, physical durability,
memory profiling and comparative throughput have not yet been validated.

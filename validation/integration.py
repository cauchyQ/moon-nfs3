"""Exercise the real CLI against an external, disposable NFSv3 export.

Requires an existing server; this script does not implement an NFS oracle.
Uses only Python's standard library. All remote names use a unique prefix.
"""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--export", default="/moonnfs3")
    parser.add_argument("--discovery", action="store_true")
    args = parser.parse_args()
    env = os.environ.copy()
    env.update(NFS_UID="0", NFS_GID="0")
    env.update(NFS_MOUNT_PORT="0" if args.discovery else "20491",
               NFS_PORT="0" if args.discovery else "20490")

    def cli(command, *paths, succeeds=True):
        run = subprocess.run(
            ["moon", "run", "cmd/main", "--target", "wasm", "--",
             command, args.host, args.export, *map(str, paths)],
            env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60,
        )
        if (run.returncode == 0) != succeeds:
            raise AssertionError(f"{command} returned {run.returncode}\n{run.stdout}\n{run.stderr}")
        return run.stdout.strip()

    print(cli("verify"))
    prefix = "integration-" + uuid.uuid4().hex
    cli("mkdir", prefix)
    with tempfile.TemporaryDirectory(prefix="moonnfs3-") as folder:
        local = Path(folder)
        absent_destination = local / "missing.out"
        cli("get", prefix + "/missing", absent_destination, succeeds=False)
        assert not absent_destination.exists(), "missing remote source created a local file"
        for name, payload in [("empty", b""), ("binary", bytes(range(256)) * 1563)]:
            source, dest = local / name, local / (name + ".out")
            source.write_bytes(payload)
            remote = prefix + "/" + name
            cli("put", source, remote)
            cli("get", remote, dest)
            digest = hashlib.sha256(payload).hexdigest()
            assert hashlib.sha256(dest.read_bytes()).hexdigest() == digest
            cli("get", remote, dest, succeeds=False)
            assert dest.read_bytes() == payload, "existing local destination changed"
            cli("put", source, remote, succeeds=False)
            assert f"size={len(payload)} " in cli("stat", remote)
            print(f"PASS: {name}, {len(payload)} bytes, SHA256={digest}, overwrite guards")
            cli("rm", remote)
        cli("stat", prefix + "/missing", succeeds=False)
    cli("rmdir", prefix)
    print("PASS: external-server CLI integration; test directory removed")


if __name__ == "__main__":
    main()

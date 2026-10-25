"""Behavior checks against the external NFS server, using real CLI operations."""
import hashlib
import json


def extended_checks(cli, folder, prefix, host, export):
    health = json.loads(cli("doctor"))
    assert int(health["calls"]) == int(health["replies"])
    assert health["read_max"] > 0 and health["write_max"] > 0
    assert export in cli("exports")
    cli("mounts")
    assert "program=100003 version=3" in cli("services")

    payload = bytes((i * 17 + i // 251) % 256 for i in range(160007))
    source = folder / "source.bin"
    source.write_bytes(payload)
    remote = prefix + "/source"
    cli("put", source, remote)
    cli("verify-file", source, remote)
    cli("inspect", remote)
    cli("access", remote, 63)
    cli("chown", remote, "-", "-")
    cli("settime", remote, 1700000000, 123456789)
    metadata = json.loads(cli("inspect", remote))
    assert metadata["mtime_seconds"] == 1700000000
    assert metadata["mtime_nanoseconds"] == 123456789
    cli("chmod", remote, "444")
    for command in ("cp", "cp-checked", "stream-copy"):
        destination = prefix + "/" + command
        cli(command, remote, destination)
        cli("cmp", remote, destination)
        cli(command, remote, destination, succeeds=False)
    cli("chmod", remote, "644")
    assert "bytes=320014" in cli("bench-read", remote, 2)
    cli("touch", remote)

    ranged = folder / "range.bin"
    cli("get-range", remote, ranged, 17003, 70001)
    assert ranged.read_bytes() == payload[17003:87004]

    linked = prefix + "/hardlink"
    cli("link", remote, linked)
    first = json.loads(cli("inspect", remote))
    second = json.loads(cli("inspect", linked))
    assert (first["fsid"], first["fileid"]) == (second["fsid"], second["fileid"])
    symbolic = prefix + "/symbolic"
    cli("symlink", symbolic, "source")
    assert cli("readlink", symbolic) == "source"
    assert cli("realpath", symbolic) == remote
    fifo = prefix + "/fifo"
    cli("mkfifo", fifo)
    assert "kind=7 " in cli("stat", fifo)
    cli("rm", fifo)
    loop = prefix + "/loop"
    cli("symlink", loop, "loop")
    cli("realpath", loop, succeeds=False)
    escape = prefix + "/escape"
    cli("symlink", escape, "../../outside")
    cli("realpath", escape, succeeds=False)

    resume_local = folder / "resume.bin"
    resume_local.write_bytes(payload[:70003])
    cli("resume-get", remote, resume_local)
    assert resume_local.read_bytes() == payload
    cli("resume-get", remote, resume_local)
    wrong_prefix = folder / "wrong-prefix.bin"
    wrong_prefix.write_bytes(b"incorrect")
    assert "compared=1" in cli("verify-file", wrong_prefix, remote, succeeds=False)
    cli("resume-get", remote, wrong_prefix, succeeds=False)
    assert wrong_prefix.read_bytes() == b"incorrect"
    partial = folder / "partial.bin"
    partial.write_bytes(payload[:70003])
    resume_remote = prefix + "/resume"
    cli("put", partial, resume_remote)
    cli("resume-put", source, resume_remote)
    cli("cmp", remote, resume_remote)
    cli("resume-put", wrong_prefix, resume_remote, succeeds=False)

    cross = prefix + "/cross"
    cli("copy-to", remote, host, export, cross)
    cli("cmp", remote, cross)
    cross_partial = prefix + "/cross-partial"
    cli("put", partial, cross_partial)
    cli("resume-to", remote, host, export, cross_partial)
    cli("cmp", remote, cross_partial)

    published = prefix + "/published"
    stage = prefix + "/upload-stage"
    cli("atomic-put", source, published, stage)
    cli("stat", stage, succeeds=False)
    cli("cmp", remote, published)
    cli("atomic-put", partial, published, stage, succeeds=False)
    cli("cmp", remote, published)
    cli("rm", stage)
    cli("atomic-replace", partial, published, stage)
    cli("verify-file", partial, published)
    atomic_copy = prefix + "/atomic-copy"
    cli("atomic-copy", remote, atomic_copy, prefix + "/copy-stage")
    cli("cmp", remote, atomic_copy)
    atomic_local = folder / "atomic.bin"
    atomic_stage = folder / "atomic.stage"
    cli("atomic-get", remote, atomic_local, atomic_stage)
    assert atomic_local.read_bytes() == payload and not atomic_stage.exists()
    cli("atomic-get", remote, atomic_local, atomic_stage, succeeds=False)
    assert atomic_local.read_bytes() == payload and not atomic_stage.exists()

    # A hard-link alias must take the same overlap-safe path as an identical handle.
    cli("copy-range", remote, linked, 0, 17007, 140000)
    expected = bytearray(payload)
    expected[17007:157007] = payload[:140000]
    overlap = folder / "overlap.bin"
    cli("get", remote, overlap)
    assert overlap.read_bytes() == expected
    cli("copy-range", linked, remote, 17007, 0, 140000)
    expected[:140000] = expected[17007:157007]
    overlap.unlink()
    cli("get", remote, overlap)
    assert overlap.read_bytes() == expected

    local_tree = folder / "input-tree"
    (local_tree / "nested" / "empty-dir").mkdir(parents=True)
    (local_tree / "empty").write_bytes(b"")
    (local_tree / ".hidden").write_bytes(b"hidden")
    (local_tree / "nested" / "数据 file.bin").write_bytes(payload)
    tree = prefix + "/tree"
    cli("put-tree", local_tree, tree)
    cli("verify-tree", local_tree, tree)
    output_tree = folder / "output-tree"
    cli("get-tree", tree, output_tree)
    for name in ("empty", ".hidden", "nested/数据 file.bin"):
        assert (local_tree / name).read_bytes() == (output_tree / name).read_bytes()
    assert (output_tree / "nested" / "empty-dir").is_dir()
    cli("get-tree", tree, output_tree, succeeds=False)
    cli("put-tree", local_tree, tree, succeeds=False)
    copy_tree = prefix + "/tree-copy"
    cli("cp-tree", tree, copy_tree)
    cli("diff-tree", tree, copy_tree)
    cross_tree = prefix + "/tree-cross"
    cli("tree-to", tree, host, export, cross_tree)
    cli("diff-tree", tree, cross_tree)
    assert "files=3 directories=3" in cli("du", tree)
    assert "数据 file.bin" in cli("tree", tree)
    cli("mkdirs", prefix + "/created/deep/path")
    cli("mkdirs", prefix + "/created/deep/path")
    cli("cp-tree", tree, tree + "/inside", succeeds=False)
    cli("symlink", tree + "/link", "empty")
    rejected_tree = folder / "rejected-tree"
    cli("get-tree", tree, rejected_tree, succeeds=False)
    assert not rejected_tree.exists()
    cli("rm", tree + "/link")
    cli("rm-tree", copy_tree)
    cli("rm-tree", cross_tree)
    print("PASS: metadata, links, ranges, prefix-checked resume, staging publication, tree/cross-client copy")
    print("PASS: extended payload SHA256=" + hashlib.sha256(payload).hexdigest())

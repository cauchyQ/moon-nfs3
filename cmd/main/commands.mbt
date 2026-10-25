///|
priv struct Request {
  command : String
  host : String
  export_path : String
  operands : Array[String]
}

///|
fn command_arity(command : String) -> (Int, Int) raise {
  match command {
    "exports"
    | "mounts"
    | "services"
    | "verify"
    | "ping"
    | "fsinfo"
    | "space" => (0, 0)
    "ls" | "stat" | "inspect" | "tree" | "du" | "pathconf" | "doctor" => (0, 1)
    "mkdir"
    | "mkdirs"
    | "rm"
    | "rmdir"
    | "rm-tree"
    | "cat"
    | "readlink"
    | "realpath"
    | "touch"
    | "exists"
    | "mkfifo" => (1, 1)
    "get"
    | "put"
    | "mv"
    | "cp"
    | "cp-checked"
    | "link"
    | "symlink"
    | "get-tree"
    | "put-tree"
    | "cp-tree"
    | "cmp"
    | "diff-tree"
    | "resume-get"
    | "resume-put"
    | "stream-copy"
    | "chmod"
    | "truncate"
    | "access"
    | "verify-file"
    | "verify-tree"
    | "bench-read" => (2, 2)
    "chown"
    | "settime"
    | "atomic-get"
    | "atomic-put"
    | "atomic-replace"
    | "atomic-copy" => (3, 3)
    "get-range" | "copy-to" | "resume-to" | "tree-to" => (4, 4)
    "copy-range" => (5, 5)
    _ => fail("unknown command '\{command}'; see --help")
  }
}

///|
fn service_command(command : String) -> Bool {
  command == "exports" || command == "mounts" || command == "services"
}

///|
fn parse_request(args : Array[String]) -> Request raise {
  if args.length() < 3 {
    fail("expected COMMAND HOST; see --help")
  }
  let command = args[1]
  let (minimum, maximum) = command_arity(command)
  let prefix = if service_command(command) { 3 } else { 4 }
  if args.length() < prefix ||
    args.length() - prefix < minimum ||
    args.length() - prefix > maximum {
    fail("wrong argument count for '\{command}'; see --help")
  }
  let operands = Array::makei(args.length() - prefix, i => args[prefix + i])
  // Reject numeric syntax errors before opening a remote connection.
  match command {
    "chmod" => ignore(@string.parse_uint(operands[1], base=8))
    "truncate" => ignore(@string.parse_uint64(operands[1]))
    "access" | "bench-read" => ignore(@string.parse_int(operands[1]))
    "get-range" => {
      ignore(@string.parse_uint64(operands[2]))
      ignore(@string.parse_uint64(operands[3]))
    }
    "copy-range" =>
      for i in 2..<5 {
        ignore(@string.parse_uint64(operands[i]))
      }
    "settime" => {
      ignore(@string.parse_uint(operands[1]))
      ignore(@string.parse_uint(operands[2]))
    }
    "chown" =>
      for i in 1..<3 {
        if operands[i] != "-" {
          ignore(@string.parse_uint(operands[i]))
        }
      }
    _ => ()
  }
  {
    command,
    host: args[2],
    export_path: if prefix == 4 {
      args[3]
    } else {
      ""
    },
    operands,
  }
}

///|
fn print_help() -> Unit {
  println("MoonNFS3: COMMAND HOST EXPORT [arguments]")
  for
    line in [
      "ls|stat|inspect|tree|du|pathconf [PATH]", "get REMOTE LOCAL; put LOCAL REMOTE; mv SOURCE DEST",
      "cp|cp-checked|stream-copy SOURCE DEST; cmp LEFT RIGHT", "mkdir|mkdirs PATH; rm|rmdir|rm-tree PATH",
      "get-tree REMOTE LOCAL; put-tree LOCAL REMOTE; cp-tree SOURCE DEST", "diff-tree LEFT RIGHT; verify-file LOCAL REMOTE",
      "resume-get REMOTE LOCAL; resume-put LOCAL REMOTE (existing destinations only)",
      "atomic-get REMOTE LOCAL LOCAL_STAGING", "atomic-put|atomic-replace LOCAL REMOTE REMOTE_STAGING",
      "get-range REMOTE LOCAL OFFSET LENGTH", "symlink PATH TARGET; link SOURCE DEST; readlink|realpath PATH",
      "chmod PATH OCTAL_MODE; chown PATH UID|- GID|-; truncate PATH SIZE", "touch PATH; settime PATH SECONDS NANOSECONDS; access PATH MASK",
      "cat PATH (UTF-8, bounded); exists PATH; mkfifo PATH", "space|fsinfo|ping|verify; bench-read PATH ROUNDS",
      "exports|mounts|services HOST (no EXPORT argument)", "doctor [PATH]; verify-tree LOCAL REMOTE",
      "copy-to|resume-to|tree-to SOURCE DEST_HOST DEST_EXPORT DEST_PATH", "copy-range SOURCE DEST SOURCE_OFFSET DEST_OFFSET LENGTH",
      "atomic-copy SOURCE DEST REMOTE_STAGING",
    ] {
    println(line)
  }
  println(
    "get/put/cp create fresh destinations. rm-tree recursively deletes a subtree.",
  )
  println(
    "Atomic no-replace upload requires hard links; failed operations can leave staging files.",
  )
  println(
    "NFS_PORT / NFS_MOUNT_PORT: 0 = discovery; NFS_UID / NFS_GID default 65534",
  )
  println(
    "NFS_BLOCK_SIZE / NFS_MAX_RECORD / NFS_TIMEOUT_MS / NFS_MAX_ENTRIES set budgets",
  )
}

///|
fn env_uid(name : String, fallback : UInt) -> UInt raise {
  match @env.get_env_var(name) {
    Some(value) => @string.parse_uint(value)
    None => fallback
  }
}

///|
fn transfer_summary(value : @nfs.TreeTransfer) -> Unit {
  println(
    "files=\{value.files} directories=\{value.directories} symlinks=\{value.symlinks} bytes=\{value.bytes}",
  )
}

///|
fn metadata_json(value : @nfs.Metadata) -> Json {
  let a = value.attributes
  Json::object(
    Map([
      ("kind", @nfs.file_kind_name(a.kind).to_json()),
      ("mode", a.mode.to_json()),
      ("permissions", @nfs.permission_string(a.kind, a.mode).to_json()),
      ("size", a.size.to_string().to_json()),
      ("allocated", a.used.to_string().to_json()),
      ("fsid", a.fsid.to_string().to_json()),
      ("fileid", a.fileid.to_string().to_json()),
      ("uid", a.uid.to_json()),
      ("gid", a.gid.to_json()),
      ("links", a.links.to_json()),
      ("mtime_seconds", value.modified.seconds.to_json()),
      ("mtime_nanoseconds", value.modified.nanoseconds.to_json()),
      ("ctime_seconds", value.changed.seconds.to_json()),
      ("ctime_nanoseconds", value.changed.nanoseconds.to_json()),
      ("atime_seconds", value.accessed.seconds.to_json()),
      ("atime_nanoseconds", value.accessed.nanoseconds.to_json()),
      ("device_major", value.device_major.to_json()),
      ("device_minor", value.device_minor.to_json()),
    ]),
  )
}

///|
async fn run_services(
  request : Request,
  options : @nfs.Options,
  mount_port : Int,
) -> Unit {
  match request.command {
    "exports" =>
      for entry in @nfs.list_exports(request.host, mount_port~, options~) {
        let path = @utf8.decode(entry.directory)
        let groups = entry.groups.map(group => @utf8.decode_lossy(group))
        println(
          Json::object(
            Map([("directory", path.to_json()), ("groups", groups.to_json())]),
          ).stringify(),
        )
      }
    "mounts" =>
      for entry in @nfs.list_mounts(request.host, mount_port~, options~) {
        println(
          Json::object(
            Map([
              ("host", @utf8.decode_lossy(entry.host).to_json()),
              ("directory", @utf8.decode_lossy(entry.directory).to_json()),
            ]),
          ).stringify(),
        )
      }
    "services" =>
      for entry in @nfs.list_services(request.host, options~) {
        println(
          "program=\{entry.program} version=\{entry.version} protocol=\{entry.protocol} port=\{entry.port}",
        )
      }
    _ => fail("expected service query")
  }
}

///|
async fn run_command(client : @nfs.Client, request : Request) -> Unit {
  let values = request.operands
  let path = if values.length() > 0 { values[0] } else { "/" }
  match request.command {
    "ls" => {
      let cursor = client.open_directory(path)
      defer cursor.close()
      while cursor.next() is Some(entry) {
        println(@utf8.decode_lossy(entry.name))
      }
    }
    "stat" => {
      let a = client.stat(path)
      println(
        "kind=\{a.kind} size=\{a.size} mode=\{a.mode} uid=\{a.uid} gid=\{a.gid}",
      )
    }
    "inspect" =>
      println(
        metadata_json(client.metadata(client.resolve(path))).stringify(indent=2),
      )
    "doctor" =>
      println(client.health_check(path~).to_json().stringify(indent=2))
    "tree" => {
      let walker = client.walk(path)
      defer walker.close()
      while walker.next() is Some(entry) {
        println(
          "\{@nfs.permission_string(entry.attributes.kind, entry.attributes.mode)} \{entry.attributes.size} \{entry.path.to_json().stringify()}",
        )
      }
    }
    "du" => {
      let usage = client.disk_usage(path)
      println(
        "files=\{usage.files} directories=\{usage.directories} symlinks=\{usage.symlinks} special=\{usage.special} logical=\{usage.logical_bytes} allocated=\{usage.allocated_bytes}",
      )
    }
    "space" => {
      let space = client.space()
      println(
        "total=\{space.total_bytes} free=\{space.free_bytes} available=\{space.available_bytes}",
      )
    }
    "fsinfo" => {
      let info = client.fsinfo()
      println(
        "read_max=\{info.read_max} read_preferred=\{info.read_preferred} write_max=\{info.write_max} write_preferred=\{info.write_preferred} max_file_size=\{info.max_file_size} properties=\{info.properties}",
      )
    }
    "pathconf" => {
      let config = client.pathconf(handle=Some(client.resolve(path)))
      println(
        "link_max=\{config.link_max} name_max=\{config.name_max} no_truncation=\{config.no_truncation} case_insensitive=\{config.case_insensitive} case_preserving=\{config.case_preserving}",
      )
    }
    "mkdir" => {
      ignore(client.mkdir(path))
      println("created")
    }
    "mkdirs" => {
      ignore(client.ensure_directory(path))
      println("created")
    }
    "rm" => client.remove(path)
    "rmdir" => client.remove(path, directory=true)
    "rm-tree" => println("removed=\{client.remove_tree(path)}")
    "get" => println("downloaded \{client.download(path, values[1])} bytes")
    "atomic-copy" =>
      println("copied \{client.copy_atomic(path, values[1], values[2])} bytes")
    "copy-range" => {
      let source = client.resolve(path)
      let destination = client.resolve(values[1])
      let bytes = client.copy_range(
        source,
        destination,
        @string.parse_uint64(values[2]),
        @string.parse_uint64(values[3]),
        @string.parse_uint64(values[4]),
      )
      println("copied \{bytes} bytes")
    }
    "put" => println("uploaded \{client.upload(path, values[1])} bytes")
    "resume-get" =>
      println("resumed \{client.resume_download(path, values[1])} bytes")
    "resume-put" =>
      println("resumed \{client.resume_upload(path, values[1])} bytes")
    "atomic-get" =>
      println(
        "downloaded \{client.download_atomic(path, values[1], values[2])} bytes",
      )
    "atomic-put" | "atomic-replace" => {
      let bytes = client.upload_atomic(
        path,
        values[1],
        values[2],
        replace=request.command == "atomic-replace",
      )
      println("uploaded \{bytes} bytes")
    }
    "get-tree" => transfer_summary(client.download_tree(path, values[1]))
    "put-tree" => transfer_summary(client.upload_tree(path, values[1]))
    "cp-tree" => transfer_summary(client.copy_tree(path, values[1]))
    "cp" => println("copied \{client.copy_file(path, values[1])} bytes")
    "cp-checked" =>
      println("copied \{client.copy_file_checked(path, values[1])} bytes")
    "mv" => client.rename(path, values[1])
    "link" => client.hard_link(path, values[1])
    "symlink" => ignore(client.symlink(path, @utf8.encode(values[1])))
    "readlink" => println(@utf8.decode(client.readlink(client.resolve(path))))
    "realpath" => println(client.canonical_path(path))
    "cat" => println(client.read_text(path))
    "touch" => client.touch(path)
    "exists" => println(client.exists(path))
    "mkfifo" => ignore(client.mknod(path, @nfs.NamedPipe))
    "chmod" => client.chmod(path, @string.parse_uint(values[1], base=8))
    "chown" =>
      client.chown(
        path,
        if values[1] == "-" {
          None
        } else {
          Some(@string.parse_uint(values[1]))
        },
        if values[2] == "-" {
          None
        } else {
          Some(@string.parse_uint(values[2]))
        },
      )
    "truncate" => client.truncate(path, @string.parse_uint64(values[1]))
    "settime" =>
      client.set_attributes(client.resolve(path), {
        ..@nfs.AttributeUpdate::default(),
        modified: @nfs.ExactTime({
          seconds: @string.parse_uint(values[1]),
          nanoseconds: @string.parse_uint(values[2]),
        }),
      })
    "access" =>
      println(
        "granted=\{client.access(client.resolve(path), @string.parse_uint(values[1]))}",
      )
    "cmp" => {
      let comparison = client.compare_files(path, values[1])
      println("equal=\{comparison.equal} compared=\{comparison.compared_bytes}")
      if !comparison.equal {
        match comparison.first_difference {
          Some(offset) => fail("files differ at byte \{offset}")
          None => fail("files differ")
        }
      }
    }
    "verify-file" => {
      let comparison = client.verify_local_file(path, values[1])
      println("equal=\{comparison.equal} compared=\{comparison.compared_bytes}")
      if !comparison.equal {
        fail("local and remote files differ")
      }
    }
    "diff-tree" => {
      let differences = client.compare_trees(path, values[1], compare_mode=true)
      for difference in differences {
        println(
          "\{difference.kind.name()} \{difference.relative.to_json().stringify()}",
        )
      }
      if differences.length() != 0 {
        fail("trees differ")
      }
      println("equal=true")
    }
    "stream-copy" => {
      let destination = connect_destination(request.host, request.export_path)
      defer destination.close()
      let reader = client.open_reader(path)
      defer reader.close()
      let writer = destination.open_writer(values[1])
      defer writer.close()
      writer.write_reader(reader)
      println("copied \{writer.position()} bytes")
    }
    "copy-to" | "resume-to" | "tree-to" => {
      let destination = connect_destination(values[1], values[2])
      defer destination.close()
      match request.command {
        "copy-to" =>
          println(
            "copied \{client.copy_file_to(destination, path, values[3])} bytes",
          )
        "resume-to" =>
          println(
            "resumed \{client.resume_copy_to(destination, path, values[3])} bytes",
          )
        _ => transfer_summary(client.copy_tree_to(destination, path, values[3]))
      }
    }
    "verify-tree" => {
      let result = client.verify_local_tree(path, values[1])
      for difference in result.differences {
        println(
          "\{difference.kind.name()} \{difference.relative.to_json().stringify()}",
        )
      }
      if result.differences.length() != 0 {
        fail("local and remote trees differ")
      }
      println("equal=true compared=\{result.compared_bytes}")
    }
    "get-range" => {
      let handle = client.resolve(path)
      if client.getattr(handle).kind != 1U {
        fail("expected regular source")
      }
      let offset = @string.parse_uint64(values[2])
      let length = @string.parse_uint64(values[3])
      if offset > 18446744073709551615UL - length {
        fail("requested range overflows 64-bit offsets")
      }
      let file = @fs.open(values[1], mode=WriteOnly, create_mode=CreateNew)
      defer file.close()
      let bytes = client.download_range(handle, file, offset, length)
      file.sync()
      println("downloaded \{bytes} bytes")
    }
    "bench-read" => {
      let result = client.benchmark_read(
        path,
        rounds=@string.parse_int(values[1]),
      )
      println(
        "bytes=\{result.bytes} elapsed_ms=\{result.elapsed_ms} MiB_per_second=\{result.mebibytes_per_second()} calls=\{result.rpc.calls} replies=\{result.rpc.replies}",
      )
    }
    "ping" => {
      client.ping()
      println("ok")
    }
    "verify" => verify(client)
    _ => fail("command is not an NFS file operation")
  }
}

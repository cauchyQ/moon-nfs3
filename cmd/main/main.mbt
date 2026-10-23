///|
fn env_number(name : String, fallback : Int) -> Int raise {
  match @env.get_env_var(name) {
    Some(value) => {
      let number = @string.parse_int(value)
      if number < 0 {
        fail("\{name} must be nonnegative")
      }
      number
    }
    None => fallback
  }
}

///|
async fn verify(client : @nfs.Client) -> Unit {
  let dir = "moonnfs3-\{@env.now()}"
  ignore(client.mkdir(dir))
  let path = dir + "/binary"
  let h = client.create_file(path)
  let payload = Bytes::makei(150007, i => (i % 251).to_byte())
  client.write_all(h, 0UL, payload)
  assert_eq(client.getattr(h).size, 150007UL)
  let mut position = 0
  while position < payload.length() {
    let count = if payload.length() - position < 4096 {
      payload.length() - position
    } else {
      4096
    }
    let part = client.read_at(h, position.to_uint64(), count)
    let end = position + part.data.length()
    assert_eq(part.data, payload[position:end].to_owned())
    position = end
  }
  client.write_committed(h, 2UL, b"\x00committed")
  assert_eq(client.read_at(h, 2UL, 10).data, b"\x00committed")
  assert_true(client.list_dir(dir).length() >= 1)
  assert_true(client.list_dir(dir, plus=false).length() >= 1)
  let names = Array::makei(40, i => {
    "f-\{i}-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz-abcdefghijklmnopqrstuvwxyz"
  })
  for name in names {
    ignore(client.create_file(dir + "/" + name))
  }
  assert_false(client.read_directory(client.resolve(dir)).eof)
  let entries = client.list_dir(dir)
  for name in names {
    assert_true(entries.any(entry => entry.name == @utf8.encode(name)))
  }
  for name in names {
    client.remove(dir + "/" + name)
  }
  client.rename(path, dir + "/renamed")
  let moved = client.resolve(dir + "/renamed")
  client.setattr(moved, size=Some(4UL))
  assert_eq(client.getattr(moved).size, 4UL)
  assert_eq(client.access(moved, 1U), 1U)
  ignore(client.space())
  ignore(client.pathconf())
  client.remove(dir + "/renamed")
  client.remove(dir, directory=true)
  println(
    "PASS: binary transfer, COMMIT, READDIR/PLUS, attributes, rename and cleanup",
  )
}

///|
fn main {
  let args = @env.args()
  if args.length() < 2 || args[1] == "--help" {
    println(
      "MoonNFS3: <ls|stat|get|put|mkdir|mv|rm|rmdir|space|verify> HOST EXPORT [PATH] [DEST]",
    )
    println(
      "Ports: NFS_MOUNT_PORT / NFS_PORT (0 = discovery); NFS_UID / NFS_GID default to 65534",
    )
    println(
      "get: PATH remote, DEST local; put: PATH local, DEST remote; no overwrite",
    )
    println("verify creates and removes a unique test directory in the export")
  } else {
    @async.run_async_main(() => {
      if args.length() < 4 {
        fail("expected command HOST EXPORT; see --help")
      }
      let command = args[1]
      let path = if args.length() > 4 { args[4] } else { "/" }
      let options = @nfs.Options::{
        ..@nfs.Options::default(),
        uid: env_number("NFS_UID", 65534).reinterpret_as_uint(),
        gid: env_number("NFS_GID", 65534).reinterpret_as_uint(),
        block_size: env_number(
          "NFS_BLOCK_SIZE",
          if command == "verify" {
            4096
          } else {
            65536
          },
        ),
        max_record: env_number(
          "NFS_MAX_RECORD",
          if command == "verify" {
            8192
          } else {
            1048576
          },
        ),
      }
      let client = @nfs.connect_export(
        args[2],
        args[3],
        mount_port=env_number("NFS_MOUNT_PORT", 0),
        nfs_port=env_number("NFS_PORT", 0),
        options~,
      )
      defer client.close()
      match command {
        "ls" =>
          for entry in client.list_dir(path) {
            println(@utf8.decode_lossy(entry.name))
          }
        "stat" => {
          let attrs = client.stat(path)
          println(
            "kind=\{attrs.kind} size=\{attrs.size} mode=\{attrs.mode} uid=\{attrs.uid} gid=\{attrs.gid}",
          )
        }
        "space" => {
          let value = client.space()
          println(
            "total=\{value.total_bytes} free=\{value.free_bytes} available=\{value.available_bytes}",
          )
        }
        "mkdir" => {
          ignore(client.mkdir(path))
          println("created")
        }
        "rm" => client.remove(path)
        "rmdir" => client.remove(path, directory=true)
        "verify" => verify(client)
        "get" | "put" | "mv" => {
          if args.length() != 6 {
            fail("expected PATH DEST")
          }
          match command {
            "get" =>
              println("downloaded \{client.download(path, args[5])} bytes")
            "put" => println("uploaded \{client.upload(path, args[5])} bytes")
            _ => client.rename(path, args[5])
          }
        }
        _ => fail("unknown command; see --help")
      }
    })
  }
}

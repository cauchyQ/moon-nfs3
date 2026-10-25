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
  assert_eq(client.commit(h, 2UL, 10U).length(), 8)
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
    print_help()
  } else {
    @async.run_async_main(() => {
      let request = parse_request(args)
      let small = request.command == "verify"
      let options = cli_options(small)
      let mount_port = env_number("NFS_MOUNT_PORT", 0)
      if service_command(request.command) {
        run_services(request, options, mount_port)
        return
      }
      let client = @nfs.connect_export(
        request.host,
        request.export_path,
        mount_port~,
        nfs_port=env_number("NFS_PORT", 0),
        options~,
      )
      defer client.close()
      run_command(client, request)
    })
  }
}

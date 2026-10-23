///|
/// Resolve an IPv4 TCP service through portmapper v2. Port zero is unavailable.
pub async fn service_port(
  host : String,
  program : UInt,
  version : UInt,
  options? : Options = Options::default(),
) -> Int {
  let rpc = Rpc::connect(host, 111, options~)
  defer rpc.close()
  let w = @xdr.Writer::new()
  w.write_uint(program)
  w.write_uint(version)
  w.write_uint(6U)
  w.write_uint(0U)
  let r = rpc.call(100000U, 2U, 3U, w.bytes())
  let port = r.read_uint()
  r.finish()
  if port == 0U || port > 65535U {
    raise RpcFailure("service is unavailable over TCP")
  }
  port.reinterpret_as_int()
}

///|
pub struct Client {
  priv rpc : Rpc
  priv options : Options
  priv root : Handle
  priv mut read_size : Int
  priv mut write_size : Int
}

///|
/// Explicit ports avoid portmapper when desired. No system mount is performed.
pub async fn connect_export(
  host : String,
  export_path : String,
  mount_port? : Int = 0,
  nfs_port? : Int = 0,
  options? : Options = Options::default(),
) -> Client {
  options.validate()
  let path = @utf8.encode(export_path)
  if path.length() == 0 ||
    path.length() > 1024 ||
    export_path.contains("\u{0000}") {
    raise InvalidArgument("invalid export path")
  }
  let mp = if mount_port == 0 {
    service_port(host, 100005U, 3U, options~)
  } else {
    mount_port
  }
  let np = if nfs_port == 0 {
    service_port(host, 100003U, 3U, options~)
  } else {
    nfs_port
  }
  let mount = Rpc::connect(host, mp, options~)
  defer mount.close()
  let w = @xdr.Writer::new()
  w.write_opaque(path.to_array(), bound=1024U)
  let r = mount.call(100005U, 3U, 1U, w.bytes())
  require_success(r)
  let root = get_handle(r)
  let count = r.read_length(64U)
  let mut auth_sys = false
  for _ in 0..<count {
    if r.read_uint() == 1U {
      auth_sys = true
    }
  }
  r.finish()
  if !auth_sys {
    raise RpcFailure("export does not advertise AUTH_SYS")
  }
  let rpc = Rpc::connect(host, np, options~)
  let client : Client = {
    rpc,
    root,
    options,
    read_size: options.block_size,
    write_size: options.block_size,
  }
  errdefer client.close()
  client.negotiate()
  client
}

///|
/// Closes the transport. Use unmount_export separately to remove mountd bookkeeping.
pub fn Client::close(self : Client) -> Unit {
  self.rpc.close()
}

///|
pub fn Client::root_handle(self : Client) -> Handle {
  { bytes: Bytes::from_array(self.root.bytes.to_array()), }
}

///|
pub async fn unmount_export(
  host : String,
  export_path : String,
  mount_port? : Int = 0,
  options? : Options = Options::default(),
) -> Unit {
  let mp = if mount_port == 0 {
    service_port(host, 100005U, 3U, options~)
  } else {
    mount_port
  }
  let rpc = Rpc::connect(host, mp, options~)
  defer rpc.close()
  let w = @xdr.Writer::new()
  if export_path.contains("\u{0000}") {
    raise InvalidArgument("invalid export path")
  }
  w.write_opaque(@utf8.encode(export_path).to_array(), bound=1024U)
  let r = rpc.call(100005U, 3U, 3U, w.bytes())
  r.finish()
}

///|
async fn Client::invoke(
  self : Client,
  procedure : UInt,
  w : @xdr.Writer,
  modifying? : Bool = false,
) -> @xdr.Reader {
  let r = self.rpc.call(100003U, 3U, procedure, w.bytes(), modifying~)
  require_success(r)
  r
}

///|
pub(all) struct Export {
  directory : Bytes
  groups : Array[Bytes]
}

///|
pub(all) struct MountEntry {
  host : Bytes
  directory : Bytes
}

///|
pub(all) struct ServiceMapping {
  program : UInt
  version : UInt
  protocol : UInt
  port : UInt
}

///|
pub async fn list_exports(
  host : String,
  mount_port? : Int = 0,
  options? : Options = Options::default(),
) -> Array[Export] {
  let port = if mount_port == 0 {
    service_port(host, 100005U, 3U, options~)
  } else {
    mount_port
  }
  let rpc = Rpc::connect(host, port, options~)
  defer rpc.close()
  let r = rpc.call(100005U, 3U, 5U, [])
  let result : Array[Export] = []
  let mut items = 0
  while r.read_bool() {
    if items >= options.max_entries {
      raise ProtocolError("export list exceeds entry budget")
    }
    items += 1
    let directory = Bytes::from_array(r.read_opaque(bound=1024U))
    let groups : Array[Bytes] = []
    while r.read_bool() {
      if items >= options.max_entries {
        raise ProtocolError("export groups exceed entry budget")
      }
      items += 1
      groups.push(Bytes::from_array(r.read_opaque(bound=255U)))
    }
    result.push({ directory, groups, })
  }
  r.finish()
  result
}

///|
pub async fn list_mounts(
  host : String,
  mount_port? : Int = 0,
  options? : Options = Options::default(),
) -> Array[MountEntry] {
  let port = if mount_port == 0 {
    service_port(host, 100005U, 3U, options~)
  } else {
    mount_port
  }
  let rpc = Rpc::connect(host, port, options~)
  defer rpc.close()
  let r = rpc.call(100005U, 3U, 2U, [])
  let result : Array[MountEntry] = []
  while r.read_bool() {
    if result.length() >= options.max_entries {
      raise ProtocolError("mount list exceeds entry budget")
    }
    let host = Bytes::from_array(r.read_opaque(bound=255U))
    let directory = Bytes::from_array(r.read_opaque(bound=1024U))
    result.push({ host, directory, })
  }
  r.finish()
  result
}

///|
pub async fn list_services(
  host : String,
  options? : Options = Options::default(),
) -> Array[ServiceMapping] {
  let rpc = Rpc::connect(host, 111, options~)
  defer rpc.close()
  let r = rpc.call(100000U, 2U, 4U, [])
  let result : Array[ServiceMapping] = []
  while r.read_bool() {
    if result.length() >= options.max_entries {
      raise ProtocolError("service list exceeds entry budget")
    }
    let program = r.read_uint()
    let version = r.read_uint()
    let protocol = r.read_uint()
    let port = r.read_uint()
    if port > 65535U {
      raise ProtocolError("invalid advertised service port")
    }
    result.push({ program, version, protocol, port, })
  }
  r.finish()
  result
}

///|
pub(all) struct FileSystemInfo {
  read_max : UInt
  read_preferred : UInt
  read_multiple : UInt
  write_max : UInt
  write_preferred : UInt
  write_multiple : UInt
  directory_preferred : UInt
  max_file_size : UInt64
  time_delta : Timestamp
  properties : UInt
}

///|
pub async fn Client::fsinfo(
  self : Client,
  handle? : Handle? = None,
) -> FileSystemInfo {
  let w = @xdr.Writer::new()
  put_handle(
    w,
    match handle {
      Some(value) => value
      None => self.root
    },
  )
  let r = self.invoke(19U, w)
  ignore(post_attributes(r))
  let result : FileSystemInfo = {
    read_max: r.read_uint(),
    read_preferred: r.read_uint(),
    read_multiple: r.read_uint(),
    write_max: r.read_uint(),
    write_preferred: r.read_uint(),
    write_multiple: r.read_uint(),
    directory_preferred: r.read_uint(),
    max_file_size: r.read_uhyper(),
    time_delta: read_timestamp(r),
    properties: r.read_uint(),
  }
  r.finish()
  if result.read_max == 0U || result.write_max == 0U {
    raise ProtocolError("zero FSINFO transfer maximum")
  }
  result
}

///|
pub fn FileSystemInfo::supports_links(self : FileSystemInfo) -> Bool {
  (self.properties & 1U) != 0U
}

///|
pub fn FileSystemInfo::supports_symlinks(self : FileSystemInfo) -> Bool {
  (self.properties & 2U) != 0U
}

///|
pub fn FileSystemInfo::can_set_time(self : FileSystemInfo) -> Bool {
  (self.properties & 16U) != 0U
}

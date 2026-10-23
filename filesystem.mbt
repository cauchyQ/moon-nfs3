///|
pub(all) struct Space {
  total_bytes : UInt64
  free_bytes : UInt64
  available_bytes : UInt64
  total_files : UInt64
  free_files : UInt64
  available_files : UInt64
  invariant_seconds : UInt
}

///|
pub async fn Client::space(self : Client, handle? : Handle? = None) -> Space {
  let w = @xdr.Writer::new()
  put_handle(
    w,
    match handle {
      Some(h) => h
      None => self.root
    },
  )
  let r = self.invoke(18U, w)
  ignore(post_attributes(r))
  let result : Space = {
    total_bytes: r.read_uhyper(),
    free_bytes: r.read_uhyper(),
    available_bytes: r.read_uhyper(),
    total_files: r.read_uhyper(),
    free_files: r.read_uhyper(),
    available_files: r.read_uhyper(),
    invariant_seconds: r.read_uint(),
  }
  r.finish()
  result
}

///|
pub(all) struct PathConfig {
  link_max : UInt
  name_max : UInt
  no_truncation : Bool
  chown_restricted : Bool
  case_insensitive : Bool
  case_preserving : Bool
}

///|
pub async fn Client::pathconf(
  self : Client,
  handle? : Handle? = None,
) -> PathConfig {
  let w = @xdr.Writer::new()
  put_handle(
    w,
    match handle {
      Some(h) => h
      None => self.root
    },
  )
  let r = self.invoke(20U, w)
  ignore(post_attributes(r))
  let result : PathConfig = {
    link_max: r.read_uint(),
    name_max: r.read_uint(),
    no_truncation: r.read_bool(),
    chown_restricted: r.read_bool(),
    case_insensitive: r.read_bool(),
    case_preserving: r.read_bool(),
  }
  r.finish()
  result
}

///|
pub async fn Client::ping(self : Client) -> Unit {
  let r = self.rpc.call(100003U, 3U, 0U, [])
  r.finish()
}

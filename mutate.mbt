///|
fn put_sattr(w : @xdr.Writer, mode : UInt?, size : UInt64?) -> Unit raise {
  w.write_bool(mode is Some(_))
  if mode is Some(value) {
    if value > 4095U {
      raise InvalidArgument("invalid Unix mode")
    }
    w.write_uint(value)
  }
  w.write_bool(false) // uid unchanged
  w.write_bool(false) // gid unchanged
  w.write_bool(size is Some(_))
  if size is Some(value) {
    w.write_uhyper(value)
  }
  w.write_uint(0U) // atime unchanged
  w.write_uint(0U) // mtime unchanged
}

///|
async fn Client::parent(self : Client, path : String) -> (Handle, String) {
  let parts = path_components(path)
  if parts.length() == 0 {
    raise InvalidArgument("cannot mutate export root")
  }
  let mut handle = self.root_handle()
  for i in 0..<(parts.length() - 1) {
    handle = self.lookup(handle, parts[i])
  }
  (handle, parts[parts.length() - 1])
}

///|
pub async fn Client::setattr(
  self : Client,
  handle : Handle,
  mode? : UInt? = None,
  size? : UInt64? = None,
) -> Unit {
  let w = @xdr.Writer::new()
  put_handle(w, handle)
  put_sattr(w, mode, size)
  w.write_bool(false) // no ctime guard
  let r = self.invoke(2U, w, modifying=true)
  read_wcc(r)
  r.finish()
}

///|
/// GUARDED create by default: existing files are not overwritten.
/// An eight-byte verifier selects EXCLUSIVE create for caller-managed replay.
pub async fn Client::create_file(
  self : Client,
  path : String,
  mode? : UInt = 420U,
  verifier? : Bytes? = None,
) -> Handle {
  if mode > 4095U {
    raise InvalidArgument("invalid Unix mode")
  }
  let (parent, name) = self.parent(path)
  let w = @xdr.Writer::new()
  put_handle(w, parent)
  put_name(w, name)
  match verifier {
    Some(bytes) => {
      if bytes.length() != 8 {
        raise InvalidArgument("create verifier length")
      }
      w.write_uint(2U)
      w.write_fixed(bytes.to_array())
    }
    None => {
      w.write_uint(1U)
      put_sattr(w, Some(mode), None)
    }
  }
  let r = self.invoke(8U, w, modifying=true)
  let handle = if r.read_bool() { Some(get_handle(r)) } else { None }
  ignore(post_attributes(r))
  read_wcc(r)
  r.finish()
  let handle = match handle {
    Some(h) => h
    None => self.lookup(parent, name)
  }
  if verifier is Some(_) {
    self.setattr(handle, mode=Some(mode))
  }
  handle
}

///|
pub async fn Client::mkdir(
  self : Client,
  path : String,
  mode? : UInt = 493U,
) -> Handle {
  let (parent, name) = self.parent(path)
  let w = @xdr.Writer::new()
  put_handle(w, parent)
  put_name(w, name)
  put_sattr(w, Some(mode), None)
  let r = self.invoke(9U, w, modifying=true)
  let handle = if r.read_bool() { Some(get_handle(r)) } else { None }
  ignore(post_attributes(r))
  read_wcc(r)
  r.finish()
  match handle {
    Some(h) => h
    None => self.lookup(parent, name)
  }
}

///|
pub async fn Client::remove(
  self : Client,
  path : String,
  directory? : Bool = false,
) -> Unit {
  let (parent, name) = self.parent(path)
  let w = @xdr.Writer::new()
  put_handle(w, parent)
  put_name(w, name)
  let r = self.invoke(if directory { 13U } else { 12U }, w, modifying=true)
  read_wcc(r)
  r.finish()
}

///|
pub async fn Client::rename(
  self : Client,
  source : String,
  destination : String,
) -> Unit {
  let (source_parent, source_name) = self.parent(source)
  let (dest_parent, dest_name) = self.parent(destination)
  let w = @xdr.Writer::new()
  put_handle(w, source_parent)
  put_name(w, source_name)
  put_handle(w, dest_parent)
  put_name(w, dest_name)
  let r = self.invoke(14U, w, modifying=true)
  read_wcc(r)
  read_wcc(r)
  r.finish()
}

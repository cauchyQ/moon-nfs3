///|
fn put_sattr(w : @xdr.Writer, mode : UInt?, size : UInt64?) -> Unit raise {
  put_attribute_update(w, { ..AttributeUpdate::default(), mode, size, })
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
  self.set_attributes(handle, { ..AttributeUpdate::default(), mode, size, })
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
  let handle = self.created_handle(parent, @utf8.encode(name), 8U, w)
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
  self.created_handle(parent, @utf8.encode(name), 9U, w)
}

///|
pub async fn Client::remove(
  self : Client,
  path : String,
  directory? : Bool = false,
) -> Unit {
  let (parent, name) = self.parent(path)
  self.remove_entry(parent, @utf8.encode(name), directory~)
}

///|
pub async fn Client::rename(
  self : Client,
  source : String,
  destination : String,
) -> Unit {
  let (source_parent, source_name) = self.parent(source)
  let (destination_parent, destination_name) = self.parent(destination)
  self.rename_entry(
    source_parent,
    @utf8.encode(source_name),
    destination_parent,
    @utf8.encode(destination_name),
  )
}

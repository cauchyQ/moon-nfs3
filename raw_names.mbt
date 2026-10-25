///|
fn put_raw_name(w : @xdr.Writer, name : Bytes) -> Unit raise {
  if name.length() == 0 ||
    name.length() > 255 ||
    name == b"." ||
    name == b".." ||
    name.to_array().contains(0) ||
    name.to_array().contains(47) {
    raise InvalidArgument("invalid raw filename")
  }
  w.write_opaque(name.to_array(), bound=255U)
}

///|
/// Handle-relative operations preserve non-UTF-8 filenames without lossy decoding.
pub async fn Client::lookup_bytes(
  self : Client,
  parent : Handle,
  name : Bytes,
) -> Handle {
  let w = @xdr.Writer::new()
  put_handle(w, parent)
  put_raw_name(w, name)
  let r = self.invoke(3U, w)
  let result = get_handle(r)
  ignore(post_attributes(r))
  ignore(post_attributes(r))
  r.finish()
  result
}

///|
pub async fn Client::remove_entry(
  self : Client,
  parent : Handle,
  name : Bytes,
  directory? : Bool = false,
) -> Unit {
  let w = @xdr.Writer::new()
  put_handle(w, parent)
  put_raw_name(w, name)
  let r = self.invoke(if directory { 13U } else { 12U }, w, modifying=true)
  self.decode_mutation(r, reader => {
    read_wcc(reader)
    reader.finish()
  })
}

///|
pub async fn Client::rename_entry(
  self : Client,
  source_parent : Handle,
  source_name : Bytes,
  destination_parent : Handle,
  destination_name : Bytes,
) -> Unit {
  let w = @xdr.Writer::new()
  put_handle(w, source_parent)
  put_raw_name(w, source_name)
  put_handle(w, destination_parent)
  put_raw_name(w, destination_name)
  let r = self.invoke(14U, w, modifying=true)
  self.decode_mutation(r, reader => {
    read_wcc(reader)
    read_wcc(reader)
    reader.finish()
  })
}

///|
pub async fn Client::create_entry(
  self : Client,
  parent : Handle,
  name : Bytes,
  mode? : UInt = 420U,
  directory? : Bool = false,
) -> Handle {
  let w = @xdr.Writer::new()
  put_handle(w, parent)
  put_raw_name(w, name)
  if !directory {
    w.write_uint(1U)
  }
  put_attribute_update(w, { ..AttributeUpdate::default(), mode: Some(mode), })
  self.created_handle(parent, name, if directory { 9U } else { 8U }, w)
}

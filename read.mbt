///|
pub async fn Client::getattr(self : Client, handle : Handle) -> Attributes {
  let w = @xdr.Writer::new()
  put_handle(w, handle)
  let r = self.invoke(1U, w)
  let attrs = read_attributes(r)
  r.finish()
  attrs
}

///|
pub async fn Client::lookup(
  self : Client,
  directory : Handle,
  name : String,
) -> Handle {
  let w = @xdr.Writer::new()
  put_handle(w, directory)
  put_name(w, name)
  let r = self.invoke(3U, w)
  let handle = get_handle(r)
  ignore(post_attributes(r))
  ignore(post_attributes(r))
  r.finish()
  handle
}

///|
/// Rejects parent traversal. Intermediate symbolic links are not followed.
pub fn path_components(path : String) -> Array[String] raise NfsError {
  let result : Array[String] = []
  for part in path.split("/") {
    let name = part.to_string()
    if name == ".." || name.contains("\u{0000}") {
      raise InvalidArgument("parent traversal or NUL in path")
    }
    if name != "" && name != "." {
      result.push(name)
    }
  }
  result
}

///|
pub async fn Client::resolve(self : Client, path : String) -> Handle {
  let mut handle = self.root_handle()
  for name in path_components(path) {
    handle = self.lookup(handle, name)
  }
  handle
}

///|
pub async fn Client::stat(self : Client, path : String) -> Attributes {
  self.getattr(self.resolve(path))
}

///|
/// Sets transfer block sizes using FSINFO; no file data is cached.
pub async fn Client::negotiate(self : Client) -> Unit {
  let w = @xdr.Writer::new()
  put_handle(w, self.root)
  let r = self.invoke(19U, w)
  ignore(post_attributes(r))
  let rtmax = r.read_uint()
  ignore(r.read_uint()) // rtpref
  ignore(r.read_uint()) // rtmult is a performance hint, not an alignment constraint
  let wtmax = r.read_uint()
  ignore(r.read_uint())
  ignore(r.read_uint())
  ignore(r.read_uint()) // dtpref
  ignore(r.read_uhyper()) // maxfilesize
  ignore(read_time(r))
  ignore(r.read_uint()) // properties
  r.finish()
  if rtmax == 0U || wtmax == 0U {
    raise ProtocolError("zero FSINFO transfer maximum")
  }
  self.read_size = if rtmax < self.options.block_size.to_uint() {
    rtmax.reinterpret_as_int()
  } else {
    self.options.block_size
  }
  self.write_size = if wtmax < self.options.block_size.to_uint() {
    wtmax.reinterpret_as_int()
  } else {
    self.options.block_size
  }
}

///|
pub(all) struct ReadResult {
  data : Bytes
  eof : Bool
}

///|
pub async fn Client::read_at(
  self : Client,
  handle : Handle,
  offset : UInt64,
  count : Int,
) -> ReadResult {
  if count < 0 || count > self.read_size {
    raise InvalidArgument("read exceeds negotiated block size")
  }
  ignore(checked_offset(offset, count))
  let w = @xdr.Writer::new()
  put_handle(w, handle)
  w.write_uhyper(offset)
  w.write_uint(count.to_uint())
  let r = self.invoke(6U, w)
  ignore(post_attributes(r))
  let reported = r.read_uint()
  let eof = r.read_bool()
  let data = Bytes::from_array(r.read_opaque(bound=count.to_uint()))
  r.finish()
  if reported != data.length().to_uint() ||
    (count > 0 && data.length() == 0 && !eof) {
    raise ProtocolError("invalid READ length or zero progress")
  }
  { data, eof, }
}

///|
pub async fn Client::readlink(self : Client, handle : Handle) -> Bytes {
  let w = @xdr.Writer::new()
  put_handle(w, handle)
  let r = self.invoke(5U, w)
  ignore(post_attributes(r))
  let target = Bytes::from_array(r.read_opaque(bound=4096U))
  r.finish()
  target
}

///|
pub async fn Client::access(
  self : Client,
  handle : Handle,
  requested : UInt,
) -> UInt {
  if requested > 63U {
    raise InvalidArgument("invalid access mask")
  }
  let w = @xdr.Writer::new()
  put_handle(w, handle)
  w.write_uint(requested)
  let r = self.invoke(4U, w)
  ignore(post_attributes(r))
  let granted = r.read_uint()
  r.finish()
  if (granted & requested) != granted {
    raise ProtocolError("unexpected access bits")
  }
  granted
}

///|
test "export-relative paths normalize without traversing parents" {
  assert_eq(path_components("//a/./b/").join("/"), "a/b")
  assert_eq(path_components("/").length(), 0)
  try {
    ignore(path_components("a/../b"))
    fail("expected rejection")
  } catch {
    InvalidArgument(_) => ()
    other => raise other
  }
}

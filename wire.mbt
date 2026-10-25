///|
pub(all) struct Attributes {
  kind : UInt
  mode : UInt
  links : UInt
  uid : UInt
  gid : UInt
  size : UInt64
  used : UInt64
  fsid : UInt64
  fileid : UInt64
  modified_seconds : UInt
}

///|
fn read_attributes(r : @xdr.Reader) -> Attributes raise {
  read_metadata(r).attributes
}

///|
fn read_metadata(r : @xdr.Reader) -> Metadata raise {
  let kind = r.read_uint()
  if kind < 1U || kind > 7U {
    raise ProtocolError("invalid file type")
  }
  let mode = r.read_uint()
  let links = r.read_uint()
  let uid = r.read_uint()
  let gid = r.read_uint()
  let size = r.read_uhyper()
  let used = r.read_uhyper()
  let device_major = r.read_uint()
  let device_minor = r.read_uint()
  let fsid = r.read_uhyper()
  let fileid = r.read_uhyper()
  let accessed = read_timestamp(r)
  let modified = read_timestamp(r)
  let changed = read_timestamp(r)
  {
    attributes: {
      kind,
      mode,
      links,
      uid,
      gid,
      size,
      used,
      fsid,
      fileid,
      modified_seconds: modified.seconds,
    },
    device_major,
    device_minor,
    accessed,
    modified,
    changed,
  }
}

///|
fn read_time(r : @xdr.Reader) -> UInt raise {
  let seconds = r.read_uint()
  if r.read_uint() >= 1000000000U {
    raise ProtocolError("invalid nanoseconds")
  }
  seconds
}

///|
fn post_attributes(r : @xdr.Reader) -> Attributes? raise {
  if r.read_bool() {
    Some(read_attributes(r))
  } else {
    None
  }
}

///|
fn read_wcc(r : @xdr.Reader) -> Unit raise {
  if r.read_bool() {
    ignore(r.read_uhyper())
    ignore(read_time(r))
    ignore(read_time(r))
  }
  ignore(post_attributes(r))
}

///|
fn require_success(r : @xdr.Reader) -> Unit raise {
  let code = r.read_uint()
  if code != 0U {
    raise Status(code)
  }
}

///|
/// Owned opaque file handle. Instances are validated before each wire use.
pub(all) struct Handle {
  bytes : Bytes
}

///|
fn put_handle(w : @xdr.Writer, h : Handle) -> Unit raise {
  if h.bytes.length() == 0 || h.bytes.length() > 64 {
    raise InvalidArgument("file handle length")
  }
  w.write_opaque(h.bytes.to_array(), bound=64U)
}

///|
fn get_handle(r : @xdr.Reader) -> Handle raise {
  let bytes = Bytes::from_array(r.read_opaque(bound=64U))
  if bytes.length() == 0 {
    raise ProtocolError("empty file handle")
  }
  { bytes, }
}

///|
fn put_name(w : @xdr.Writer, name : String) -> Unit raise {
  put_raw_name(w, @utf8.encode(name))
}

///|
fn limits(options : Options) -> @xdr.Limits {
  {
    max_bytes: options.max_record,
    max_items: 1048576,
    max_depth: 64,
    max_schema_tokens: 65536,
  }
}

///|
test "opaque handles use RFC length and padding" {
  let w = @xdr.Writer::new()
  put_handle(w, { bytes: b"abc", })
  assert_eq(Bytes::from_array(w.bytes()), b"\x00\x00\x00\x03abc\x00")
  let r = @xdr.Reader::new(w.bytes())
  assert_eq(get_handle(r).bytes, b"abc")
  r.finish()
  try {
    put_name(w, "../bad")
    fail("accepted slash")
  } catch {
    InvalidArgument(_) => ()
    other => raise other
  }
}

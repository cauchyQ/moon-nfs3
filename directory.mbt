///|
pub(all) struct DirectoryEntry {
  fileid : UInt64
  name : Bytes
  cookie : UInt64
  attributes : Attributes?
  handle : Handle?
}

///|
pub(all) struct DirectoryPage {
  entries : Array[DirectoryEntry]
  verifier : Bytes
  eof : Bool
}

///|
pub async fn Client::read_directory(
  self : Client,
  directory : Handle,
  cookie? : UInt64 = 0UL,
  verifier? : Bytes = b"\x00\x00\x00\x00\x00\x00\x00\x00",
  plus? : Bool = true,
) -> DirectoryPage {
  if verifier.length() != 8 {
    raise InvalidArgument("directory verifier must have eight bytes")
  }
  let w = @xdr.Writer::new()
  put_handle(w, directory)
  w.write_uhyper(cookie)
  w.write_fixed(verifier.to_array())
  let budget = (self.options.max_record - 4096).to_uint()
  w.write_uint(if plus { budget / 2U } else { budget })
  if plus {
    w.write_uint(budget)
  }
  let r = self.invoke(if plus { 17U } else { 16U }, w)
  ignore(post_attributes(r))
  let verifier = Bytes::from_array(r.read_fixed(8))
  let entries : Array[DirectoryEntry] = []
  while r.read_bool() {
    if entries.length() >= self.options.max_entries {
      raise ProtocolError("directory page exceeds entry budget")
    }
    let fileid = r.read_uhyper()
    let name = Bytes::from_array(r.read_opaque(bound=255U))
    if name.length() == 0 {
      raise ProtocolError("empty directory entry name")
    }
    let cookie = r.read_uhyper()
    let attributes = if plus { post_attributes(r) } else { None }
    let handle = if plus && r.read_bool() { Some(get_handle(r)) } else { None }
    entries.push({ fileid, name, cookie, attributes, handle, })
  }
  let eof = r.read_bool()
  r.finish()
  { entries, verifier, eof, }
}

///|
/// A bounded collection for a static directory, not a concurrent directory snapshot.
/// BAD_COOKIE is surfaced to the caller rather than silently restarting traversal.
pub async fn Client::list_dir(
  self : Client,
  path : String,
  plus? : Bool = true,
) -> Array[DirectoryEntry] {
  let handle = self.resolve(path)
  let result : Array[DirectoryEntry] = []
  let seen : Map[UInt64, Bool] = {}
  let mut cookie = 0UL
  let mut verifier = b"\x00\x00\x00\x00\x00\x00\x00\x00"
  while true {
    let page = self.read_directory(handle, cookie~, verifier~, plus~)
    if page.entries.length() > self.options.max_entries - result.length() {
      raise ProtocolError("directory traversal exceeds entry budget")
    }
    for entry in page.entries {
      result.push(entry)
    }
    if page.eof {
      return result
    }
    if page.entries.length() == 0 {
      raise ProtocolError("directory pagination made no progress")
    }
    let next = page.entries[page.entries.length() - 1].cookie
    if next == cookie || seen.contains(next) {
      raise ProtocolError("directory cookie loop")
    }
    seen[next] = true
    cookie = next
    verifier = page.verifier
  } nobreak {
    raise ProtocolError("incomplete directory")
  }
}

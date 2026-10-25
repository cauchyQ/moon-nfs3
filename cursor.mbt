///|
pub struct DirectoryCursor {
  priv client : Client
  priv handle : Handle
  priv plus : Bool
  priv mut cookie : UInt64
  priv mut verifier : Bytes
  priv seen : Map[UInt64, Bool]
  priv mut batch : Array[DirectoryEntry]
  priv mut index : Int
  priv mut eof : Bool
  priv mut count : Int
  priv mut busy : Bool
  priv mut closed : Bool
}

///|
pub fn Client::scan_directory(
  self : Client,
  handle : Handle,
  plus? : Bool = true,
) -> DirectoryCursor {
  {
    client: self,
    handle,
    plus,
    cookie: 0UL,
    verifier: b"\x00\x00\x00\x00\x00\x00\x00\x00",
    seen: Map([]),
    batch: [],
    index: 0,
    eof: false,
    count: 0,
    busy: false,
    closed: false,
  }
}

///|
pub async fn Client::open_directory(
  self : Client,
  path : String,
  plus? : Bool = true,
) -> DirectoryCursor {
  self.scan_directory(self.resolve(path), plus~)
}

///|
pub fn DirectoryCursor::close(self : DirectoryCursor) -> Unit {
  self.closed = true
  self.batch.clear()
}

///|
pub async fn DirectoryCursor::next(self : DirectoryCursor) -> DirectoryEntry? {
  if self.closed {
    return None
  }
  if self.busy {
    raise InvalidArgument("concurrent directory cursor use")
  }
  self.busy = true
  defer {
    self.busy = false
  }
  errdefer self.close()
  if self.index >= self.batch.length() {
    if self.eof {
      self.close()
      return None
    }
    let page = self.client.read_directory(
      self.handle,
      cookie=self.cookie,
      verifier=self.verifier,
      plus=self.plus,
    )
    if self.cookie != 0UL && page.verifier != self.verifier {
      raise ProtocolError("directory verifier changed during traversal")
    }
    if page.entries.length() > self.client.options.max_entries - self.count {
      raise ProtocolError("directory traversal exceeds entry budget")
    }
    if !page.eof {
      if page.entries.length() == 0 {
        raise ProtocolError("directory pagination made no progress")
      }
      let cookie = page.entries[page.entries.length() - 1].cookie
      if cookie == 0UL || cookie == self.cookie || self.seen.contains(cookie) {
        raise ProtocolError("directory cookie loop")
      }
      self.seen[cookie] = true
      self.cookie = cookie
    }
    self.verifier = page.verifier
    self.batch = page.entries
    self.count += page.entries.length()
    self.index = 0
    self.eof = page.eof
  }
  if self.index == self.batch.length() {
    self.close()
    return None
  }
  let entry = self.batch[self.index]
  self.index += 1
  Some(entry)
}

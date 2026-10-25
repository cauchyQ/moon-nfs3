///|
pub(all) struct TreeEntry {
  path : String
  relative : String
  depth : Int
  handle : Handle
  attributes : Attributes
}

///|
priv struct WalkFrame {
  directory : TreeEntry
  cursor : DirectoryCursor
}

///|
pub struct TreeWalker {
  priv client : Client
  priv max_depth : Int
  priv max_nodes : Int
  priv stack : Array[WalkFrame]
  priv visited : Map[String, Bool]
  priv mut first : TreeEntry?
  priv mut pending : TreeEntry?
  priv mut count : Int
  priv mut busy : Bool
  priv mut closed : Bool
}

///|
pub async fn Client::walk(
  self : Client,
  path : String,
  max_depth? : Int = 128,
  max_nodes? : Int = 100000,
) -> TreeWalker {
  if max_depth < 1 || max_depth > 1024 || max_nodes < 1 {
    raise InvalidArgument("invalid tree traversal budget")
  }
  let (handle, attributes) = self.resolve_attributes(path)
  let root : TreeEntry = {
    path: normalize_path(path),
    relative: "",
    depth: 0,
    handle,
    attributes,
  }
  {
    client: self,
    max_depth,
    max_nodes,
    stack: [],
    visited: Map([]),
    first: Some(root),
    pending: None,
    count: 0,
    busy: false,
    closed: false,
  }
}

///|
pub fn TreeWalker::close(self : TreeWalker) -> Unit {
  self.closed = true
  for frame in self.stack {
    frame.cursor.close()
  }
  self.stack.clear()
  self.first = None
  self.pending = None
}

///|
fn TreeWalker::yield_entry(
  self : TreeWalker,
  entry : TreeEntry,
) -> TreeEntry? raise {
  if self.count >= self.max_nodes {
    raise ProtocolError("tree traversal exceeds node budget")
  }
  self.count += 1
  if entry.attributes.kind == 2U {
    let key = "\{entry.attributes.fsid}:\{entry.attributes.fileid}"
    if self.visited.contains(key) {
      raise ProtocolError("directory identity repeated during tree traversal")
    }
    self.visited[key] = true
    self.pending = Some(entry)
  }
  Some(entry)
}

///|
pub async fn TreeWalker::next(self : TreeWalker) -> TreeEntry? {
  if self.closed {
    return None
  }
  if self.busy {
    raise InvalidArgument("concurrent tree walker use")
  }
  self.busy = true
  defer {
    self.busy = false
  }
  errdefer self.close()
  if self.first is Some(root) {
    self.first = None
    return self.yield_entry(root)
  }
  if self.pending is Some(directory) {
    self.pending = None
    self.stack.push({
      directory,
      cursor: self.client.scan_directory(directory.handle),
    })
  }
  while self.stack.length() > 0 {
    let frame = self.stack[self.stack.length() - 1]
    match frame.cursor.next() {
      None => {
        ignore(self.stack.pop())
        continue
      }
      Some(entry) => {
        if entry.name == b"." || entry.name == b".." {
          continue
        }
        let depth = frame.directory.depth + 1
        if depth > self.max_depth {
          raise ProtocolError("tree traversal exceeds depth budget")
        }
        let name = decoded_name(entry.name)
        let (handle, optional) = match entry.handle {
          Some(handle) => (handle, entry.attributes)
          None => self.client.lookup_attributes(frame.directory.handle, name)
        }
        let attributes = match optional {
          Some(value) => value
          None => self.client.getattr(handle)
        }
        let relative = if frame.directory.relative == "" {
          name
        } else {
          frame.directory.relative + "/" + name
        }
        return self.yield_entry({
          path: join_path(frame.directory.path, name),
          relative,
          depth,
          handle,
          attributes,
        })
      }
    }
  }
  self.close()
  None
}

///|
pub async fn Client::collect_tree(
  self : Client,
  path : String,
  max_depth? : Int = 128,
  max_nodes? : Int = 100000,
) -> Array[TreeEntry] {
  let walker = self.walk(path, max_depth~, max_nodes~)
  defer walker.close()
  let result : Array[TreeEntry] = []
  while walker.next() is Some(entry) {
    result.push(entry)
  }
  result
}

///|
pub(all) struct DiskUsage {
  files : UInt64
  directories : UInt64
  symlinks : UInt64
  special : UInt64
  logical_bytes : UInt64
  allocated_bytes : UInt64
}

///|
fn checked_sum(left : UInt64, right : UInt64) -> UInt64 raise NfsError {
  if left > 18446744073709551615UL - right {
    raise InvalidArgument("64-bit total overflow")
  }
  left + right
}

///|
pub async fn Client::disk_usage(self : Client, path : String) -> DiskUsage {
  let walker = self.walk(path)
  defer walker.close()
  let seen : Map[String, Bool] = Map([])
  let mut files = 0UL
  let mut directories = 0UL
  let mut symlinks = 0UL
  let mut special = 0UL
  let mut logical_bytes = 0UL
  let mut allocated_bytes = 0UL
  while walker.next() is Some(entry) {
    let attributes = entry.attributes
    match attributes.kind {
      1U => files += 1UL
      2U => directories += 1UL
      5U => symlinks += 1UL
      _ => special += 1UL
    }
    let key = "\{attributes.fsid}:\{attributes.fileid}"
    if !seen.contains(key) {
      seen[key] = true
      logical_bytes = checked_sum(logical_bytes, attributes.size)
      allocated_bytes = checked_sum(allocated_bytes, attributes.used)
    }
  }
  { files, directories, symlinks, special, logical_bytes, allocated_bytes, }
}

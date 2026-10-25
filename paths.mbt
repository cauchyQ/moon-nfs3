///|
pub fn normalize_path(path : String) -> String raise NfsError {
  let parts = path_components(path)
  if parts.length() == 0 {
    "/"
  } else {
    parts.join("/")
  }
}

///|
pub fn join_path(parent : String, child : String) -> String raise NfsError {
  let parts = path_components(parent)
  for part in path_components(child) {
    parts.push(part)
  }
  if parts.length() == 0 {
    "/"
  } else {
    parts.join("/")
  }
}

///|
pub fn relative_path(base : String, path : String) -> String raise NfsError {
  let parent = path_components(base)
  let child = path_components(path)
  if child.length() < parent.length() {
    raise InvalidArgument("path is outside the requested subtree")
  }
  for i in 0..<parent.length() {
    if parent[i] != child[i] {
      raise InvalidArgument("path is outside the requested subtree")
    }
  }
  child[parent.length():].to_owned().join("/")
}

///|
fn decoded_name(bytes : Bytes) -> String raise {
  if bytes.length() == 0 ||
    bytes.length() > 255 ||
    bytes.to_array().contains(0) ||
    bytes.to_array().contains(47) {
    raise ProtocolError("invalid directory entry name")
  }
  @utf8.decode(bytes) catch {
    _ => raise ProtocolError("path operations require UTF-8 filenames")
  }
}

///|
pub async fn Client::exists(self : Client, path : String) -> Bool {
  try self.resolve(path) catch {
    Status(2U) => false
    error => raise error
  } noraise {
    _ => true
  }
}

///|
pub async fn Client::ensure_directory(
  self : Client,
  path : String,
  mode? : UInt = 493U,
) -> Handle {
  if mode > 4095U {
    raise InvalidArgument("invalid Unix mode")
  }
  let parts = path_components(path)
  let mut handle = self.root_handle()
  let mut prefix = ""
  for name in parts {
    prefix = if prefix == "" { name } else { prefix + "/" + name }
    let next = self.lookup(handle, name) catch {
      Status(2U) =>
        // Another creator can win the race; only EXIST may use LOOKUP fallback.
        self.mkdir(prefix, mode~) catch {
          Status(17U) => self.lookup(handle, name)
          error => raise error
        }
      error => raise error
    }
    if self.getattr(next).kind != 2U {
      raise InvalidArgument("directory path contains a non-directory")
    }
    handle = next
  }
  handle
}

///|
/// Explicit link following; absolute targets are relative to the export root.
/// Targets escaping that root are rejected. resolve() itself never follows links.
pub async fn Client::canonical_path(
  self : Client,
  path : String,
  max_links? : Int = 40,
) -> String {
  if max_links < 0 || max_links > 1024 {
    raise InvalidArgument("invalid symbolic link limit")
  }
  let mut pending = path_components(path)
  let completed : Array[String] = []
  let mut handle = self.root_handle()
  let mut index = 0
  let mut links = 0
  while index < pending.length() {
    let name = pending[index]
    index += 1
    let (next, optional) = self.lookup_attributes(handle, name)
    let attributes = match optional {
      Some(value) => value
      None => self.getattr(next)
    }
    if attributes.kind == 5U {
      if links >= max_links {
        raise ProtocolError("symbolic link limit exceeded")
      }
      links += 1
      let target = @utf8.decode(self.readlink(next))
      if target.contains("\u{0000}") || target == "" {
        raise ProtocolError("invalid symbolic link target")
      }
      let replacement = if target.has_prefix("/") {
        []
      } else {
        completed.copy()
      }
      for part in target.split("/") {
        let part = part.to_owned()
        if part == ".." {
          if replacement.pop() is None {
            raise InvalidArgument("symbolic link escapes export root")
          }
        } else if part != "" && part != "." {
          replacement.push(part)
        }
      }
      for i in index..<pending.length() {
        replacement.push(pending[i])
      }
      pending = replacement
      index = 0
      completed.clear()
      handle = self.root_handle()
    } else {
      if index < pending.length() && attributes.kind != 2U {
        raise InvalidArgument("intermediate path is not a directory")
      }
      completed.push(name)
      handle = next
    }
  }
  if completed.length() == 0 {
    "/"
  } else {
    completed.join("/")
  }
}

///|
pub async fn Client::resolve_following(
  self : Client,
  path : String,
  max_links? : Int = 40,
) -> Handle {
  self.resolve(self.canonical_path(path, max_links~))
}

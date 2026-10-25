///|
priv struct LocalEntry {
  path : String
  relative : String
  directory : Bool
}

///|
fn local_component(name : String) -> Unit raise NfsError {
  // Use a portable filename subset to keep remote names from becoming local paths.
  if name == "" ||
    name == "." ||
    name == ".." ||
    name.contains("/") ||
    name.contains("\\") ||
    name.contains(":") ||
    name.contains("\u{0000}") ||
    name.has_suffix(".") ||
    name.has_suffix(" ") {
    raise InvalidArgument("filename cannot be safely mapped to a local path")
  }
  for character in name {
    if character < ' ' ||
      character == '<' ||
      character == '>' ||
      character == '"' ||
      character == '|' ||
      character == '?' ||
      character == '*' {
      raise InvalidArgument("filename contains a reserved local character")
    }
  }
  let stem = match name.split_once(".") {
    Some((stem, _)) => stem.to_owned().to_upper()
    None => name.to_upper()
  }
  if [
      "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6",
      "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7",
      "LPT8", "LPT9",
    ].contains(stem) {
    raise InvalidArgument("filename is a reserved local device name")
  }
}

///|
fn local_child(parent : String, relative : String) -> String raise {
  if relative == "" {
    return parent
  }
  for component in relative.split("/") {
    local_component(component.to_owned())
  }
  parent + "/" + relative
}

///|
async fn collect_local_tree(
  path : String,
  max_nodes : Int,
  max_depth : Int,
) -> Array[LocalEntry] {
  let result : Array[LocalEntry] = []
  let pending : Array[(String, String, Int)] = [(path, "", 0)]
  while pending.pop() is Some((path, relative, depth)) {
    if result.length() >= max_nodes || depth > max_depth {
      raise InvalidArgument("local tree exceeds traversal budget")
    }
    let kind = @fs.kind(path, follow_symlink=false)
    let directory = kind == @fs.Directory
    if !directory && kind != @fs.Regular {
      raise InvalidArgument(
        "local tree upload accepts only regular files and directories",
      )
    }
    result.push({ path, relative, directory, })
    if directory {
      let names = @fs.readdir(path, include_hidden=true, sort=true)
      if names.length() > max_nodes - result.length() - pending.length() {
        raise InvalidArgument("local tree exceeds node budget")
      }
      for i = names.length() - 1; i >= 0; i = i - 1 {
        let name = names[i]
        local_component(name)
        let child = if relative == "" { name } else { relative + "/" + name }
        pending.push((local_child(path, name), child, depth + 1))
      }
    }
  }
  result
}

///|
/// Creates a fresh remote tree. Special nodes and local symlinks are rejected.
pub async fn Client::upload_tree(
  self : Client,
  local_path : String,
  remote_path : String,
) -> TreeTransfer {
  let entries = collect_local_tree(local_path, self.options.max_entries, 128)
  let mut files = 0
  let mut directories = 0
  let mut bytes = 0UL
  for entry in entries {
    let destination = join_path(remote_path, entry.relative)
    if entry.directory {
      ignore(self.mkdir(destination))
      directories += 1
    } else {
      let copied = self.upload(entry.path, destination)
      bytes = checked_sum(bytes, copied)
      files += 1
    }
  }
  { files, directories, symlinks: 0, bytes, }
}

///|
/// Creates a fresh local tree. Rejects links and special nodes before writing files.
pub async fn Client::download_tree(
  self : Client,
  remote_path : String,
  local_path : String,
) -> TreeTransfer {
  let entries = self.collect_tree(
    remote_path,
    max_nodes=self.options.max_entries,
  )
  for entry in entries {
    if entry.attributes.kind != 1U && entry.attributes.kind != 2U {
      raise InvalidArgument(
        "local tree download accepts only regular files and directories",
      )
    }
    ignore(local_child(local_path, entry.relative))
  }
  if @fs.exists(local_path) {
    raise InvalidArgument("local tree destination already exists")
  }
  let mut files = 0
  let mut directories = 0
  let mut bytes = 0UL
  for entry in entries {
    let destination = local_child(local_path, entry.relative)
    if entry.attributes.kind == 2U {
      @fs.mkdir(destination)
      directories += 1
    } else {
      let file = @fs.open(destination, mode=WriteOnly, create_mode=CreateNew)
      defer file.close()
      let copied = self.download_handle(entry.handle, file)
      file.sync()
      bytes = checked_sum(bytes, copied)
      files += 1
    }
  }
  { files, directories, symlinks: 0, bytes, }
}

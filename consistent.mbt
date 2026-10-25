///|
pub(all) struct FileVersion {
  fsid : UInt64
  fileid : UInt64
  size : UInt64
  modified : Timestamp
  changed : Timestamp
}

///|
pub fn Metadata::version(self : Metadata) -> FileVersion {
  {
    fsid: self.attributes.fsid,
    fileid: self.attributes.fileid,
    size: self.attributes.size,
    modified: self.modified,
    changed: self.changed,
  }
}

///|
pub fn FileVersion::matches(self : FileVersion, other : FileVersion) -> Bool {
  self.fsid == other.fsid &&
  self.fileid == other.fileid &&
  self.size == other.size &&
  self.modified.seconds == other.modified.seconds &&
  self.modified.nanoseconds == other.modified.nanoseconds &&
  self.changed.seconds == other.changed.seconds &&
  self.changed.nanoseconds == other.changed.nanoseconds
}

///|
pub async fn Client::require_version(
  self : Client,
  handle : Handle,
  expected : FileVersion,
) -> Unit {
  if !expected.matches(self.metadata(handle).version()) {
    raise ProtocolError("file changed during operation")
  }
}

///|
/// Detects changes visible in the server's size, identity and timestamp fields.
/// This is optimistic validation, not a lock or a filesystem snapshot.
pub async fn Client::copy_file_checked(
  self : Client,
  source : String,
  destination : String,
) -> UInt64 {
  let handle = self.resolve(source)
  let before = self.metadata(handle)
  if before.attributes.kind != 1U {
    raise InvalidArgument("copy requires a regular source")
  }
  let output = self.create_file(destination, mode=384U)
  let bytes = self.copy_handle(handle, output, before.attributes.size)
  self.require_version(handle, before.version())
  self.setattr(output, mode=Some(before.attributes.mode & 4095U))
  bytes
}

///|
pub async fn Client::verify_local_file(
  self : Client,
  local_path : String,
  remote_path : String,
) -> FileComparison {
  let file = @fs.open(local_path, mode=ReadOnly)
  defer file.close()
  if file.kind() != @fs.Regular {
    raise InvalidArgument("verification requires a regular local file")
  }
  let handle = self.resolve(remote_path)
  let before = self.metadata(handle)
  if before.attributes.kind != 1U {
    raise InvalidArgument("verification requires a regular remote file")
  }
  let local_size = file.size()
  let local_time = file.mtime()
  let buffer = FixedArray::make(self.read_size, b'\x00')
  let mut offset = 0UL
  let mut difference : UInt64? = None
  while true {
    let remote = self.read_at(handle, offset, self.read_size)
    if remote.data.length() == 0 {
      if offset < local_size.reinterpret_as_uint64() {
        difference = Some(offset)
      }
      break
    }
    let count = file.read_at(
      buffer,
      position=local_offset(offset),
      len=remote.data.length(),
    )
    for i in 0..<count {
      if buffer[i] != remote.data[i] {
        difference = Some(checked_offset(offset, i))
        offset = checked_offset(offset, i + 1)
        break
      }
    }
    if difference is Some(_) {
      break
    }
    offset = checked_offset(offset, count)
    if count < remote.data.length() {
      // Local random reads may also be short. Only zero progress proves file EOF.
      if count == 0 {
        difference = Some(offset)
        break
      }
      continue
    }
    if remote.eof {
      if offset < local_size.reinterpret_as_uint64() {
        difference = Some(offset)
      }
      break
    }
  }
  self.require_version(handle, before.version())
  if file.size() != local_size || file.mtime() != local_time {
    raise ProtocolError("local source changed during verification")
  }
  {
    equal: difference is None,
    compared_bytes: offset,
    first_difference: difference,
  }
}

///|
fn sibling_staging(
  destination : String,
  staging : String,
) -> Unit raise NfsError {
  let destination = path_components(destination)
  let staging = path_components(staging)
  if destination.length() == 0 || staging.length() != destination.length() {
    raise InvalidArgument("staging file must be a sibling of destination")
  }
  for i in 0..<(destination.length() - 1) {
    if destination[i] != staging[i] {
      raise InvalidArgument("staging file must be a sibling of destination")
    }
  }
  if destination[destination.length() - 1] == staging[staging.length() - 1] {
    raise InvalidArgument("staging file must differ from destination")
  }
}

///|
/// Publish a complete upload with LINK (no replacement) or RENAME (replacement).
/// A failed or ambiguous operation can leave staging behind for caller recovery.
pub async fn Client::upload_atomic(
  self : Client,
  local_path : String,
  destination : String,
  staging : String,
  replace? : Bool = false,
  mode? : UInt = 420U,
) -> UInt64 {
  sibling_staging(destination, staging)
  if mode > 4095U {
    raise InvalidArgument("invalid Unix mode")
  }
  if !replace && !self.fsinfo().supports_links() {
    raise InvalidArgument(
      "atomic no-replace publication requires server hard links",
    )
  }
  let file = @fs.open(local_path, mode=ReadOnly)
  defer file.close()
  if file.kind() != @fs.Regular {
    raise InvalidArgument("upload requires a regular local file")
  }
  let signed_size = file.size()
  if signed_size < 0L {
    raise InvalidArgument("invalid source file size")
  }
  let modified = file.mtime()
  let changed = file.ctime()
  let handle = self.create_file(staging, mode=384U)
  let size = signed_size.reinterpret_as_uint64()
  let copied = self.upload_range(handle, file, 0UL, size)
  if file.size() != signed_size ||
    file.mtime() != modified ||
    file.ctime() != changed {
    raise ProtocolError("local source changed before publication")
  }
  self.setattr(handle, mode=Some(mode))
  if replace {
    self.rename(staging, destination)
  } else {
    self.hard_link(staging, destination)
    self.remove(staging)
  }
  copied
}

///|
/// Staging is created exclusively and synced before a no-replace local rename.
/// The caller should put staging and destination on the same local filesystem.
pub async fn Client::download_atomic(
  self : Client,
  source : String,
  destination : String,
  staging : String,
) -> UInt64 {
  if destination == staging {
    raise InvalidArgument("staging must differ from destination")
  }
  let handle = self.resolve(source)
  let before = self.metadata(handle)
  if before.attributes.kind != 1U {
    raise InvalidArgument("download requires a regular file")
  }
  if @fs.exists(destination) {
    raise InvalidArgument("local destination already exists")
  }
  let file = @fs.open(staging, mode=WriteOnly, create_mode=CreateNew)
  defer file.close()
  let copied = self.download_handle(handle, file)
  self.require_version(handle, before.version())
  file.sync()
  file.close()
  @fs.rename(staging, destination, replace=false)
  copied
}

///|
/// Reads an exact bounded range. EOF before count is an error, even after a short read.
pub async fn Client::read_exactly_at(
  self : Client,
  handle : Handle,
  offset : UInt64,
  count : Int,
) -> Bytes {
  if count < 0 || count > self.options.block_size {
    raise InvalidArgument("exact read exceeds buffer budget")
  }
  ignore(checked_offset(offset, count))
  let result : Array[Byte] = []
  while result.length() < count {
    let remaining = count - result.length()
    let chunk = if remaining < self.read_size {
      remaining
    } else {
      self.read_size
    }
    let part = self.read_at(
      handle,
      checked_offset(offset, result.length()),
      chunk,
    )
    for byte in part.data.to_array() {
      result.push(byte)
    }
    if part.eof && result.length() < count {
      raise ProtocolError("unexpected EOF during exact range read")
    }
  }
  Bytes::from_array(result)
}

///|
/// Bounded memmove-style copy. Overlapping ranges in one object copy backwards
/// when needed, including when different handles name the same hard-linked inode.
pub async fn Client::copy_range(
  self : Client,
  source : Handle,
  destination : Handle,
  source_offset : UInt64,
  destination_offset : UInt64,
  length : UInt64,
) -> UInt64 {
  let source_end = checked_sum(source_offset, length)
  ignore(checked_sum(destination_offset, length))
  let input = self.getattr(source)
  let output = self.getattr(destination)
  if input.kind != 1U || output.kind != 1U {
    raise InvalidArgument("range copy requires regular files")
  }
  if source_end > input.size {
    raise InvalidArgument("copy range exceeds source size")
  }
  let same = input.fsid == output.fsid && input.fileid == output.fileid
  if same && source_offset == destination_offset {
    return length
  }
  let backwards = same &&
    destination_offset > source_offset &&
    destination_offset < source_end
  let mut copied = 0UL
  while copied < length {
    let remaining = length - copied
    let count = if remaining < self.read_size.to_uint64() {
      remaining.to_int()
    } else {
      self.read_size
    }
    let relative = if backwards {
      remaining - count.to_uint64()
    } else {
      copied
    }
    let bytes = self.read_exactly_at(
      source,
      checked_sum(source_offset, relative),
      count,
    )
    self.write_all(
      destination,
      checked_sum(destination_offset, relative),
      bytes,
    )
    copied = checked_sum(copied, bytes.length().to_uint64())
  }
  copied
}

///|
/// Copy to a fresh sibling staging file, validate the source version, then publish.
/// No-replace publication uses LINK so another creator cannot be overwritten.
pub async fn Client::copy_atomic(
  self : Client,
  source : String,
  destination : String,
  staging : String,
  replace? : Bool = false,
) -> UInt64 {
  sibling_staging(destination, staging)
  if !replace && !self.fsinfo().supports_links() {
    raise InvalidArgument("atomic no-replace copy requires server hard links")
  }
  let handle = self.resolve(source)
  let before = self.metadata(handle)
  if before.attributes.kind != 1U {
    raise InvalidArgument("atomic copy requires a regular source")
  }
  let output = self.create_file(staging, mode=384U)
  let copied = self.copy_handle(handle, output, before.attributes.size)
  self.require_version(handle, before.version())
  self.setattr(output, mode=Some(before.attributes.mode & 4095U))
  if replace {
    self.rename(staging, destination)
  } else {
    self.hard_link(staging, destination)
    self.remove(staging)
  }
  copied
}

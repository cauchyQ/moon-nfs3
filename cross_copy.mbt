///|
pub async fn Client::copy_file_to(
  self : Client,
  destination_client : Client,
  source : String,
  destination : String,
  preserve_mode? : Bool = true,
) -> UInt64 {
  let handle = self.resolve(source)
  let metadata = self.metadata(handle)
  if metadata.attributes.kind != 1U {
    raise InvalidArgument("cross-client copy requires a regular source")
  }
  let output = destination_client.create_file(destination, mode=384U)
  let copied = self.copy_between_handles(
    destination_client,
    handle,
    output,
    0UL,
    metadata.attributes.size,
  )
  self.require_version(handle, metadata.version())
  destination_client.setattr(
    output,
    mode=Some(
      if preserve_mode {
        metadata.attributes.mode & 4095U
      } else {
        420U
      },
    ),
  )
  copied
}

///|
async fn Client::copy_between_handles(
  self : Client,
  destination_client : Client,
  source : Handle,
  destination : Handle,
  offset : UInt64,
  length : UInt64,
) -> UInt64 {
  let end = checked_sum(offset, length)
  let mut position = offset
  while position < end {
    let remaining = end - position
    let count = if remaining < self.read_size.to_uint64() {
      remaining.to_int()
    } else {
      self.read_size
    }
    let part = self.read_at(source, position, count)
    if part.data.length() == 0 {
      raise ProtocolError("source shrank during cross-client copy")
    }
    destination_client.write_all(destination, position, part.data)
    position = checked_offset(position, part.data.length())
    if part.eof && position < end {
      raise ProtocolError("source shrank during cross-client copy")
    }
  }
  position - offset
}

///|
async fn Client::verify_remote_prefix(
  self : Client,
  other : Client,
  source : Handle,
  destination : Handle,
  length : UInt64,
) -> Unit {
  let mut offset = 0UL
  let block = if self.read_size < other.read_size {
    self.read_size
  } else {
    other.read_size
  }
  while offset < length {
    let remaining = length - offset
    let count = if remaining < block.to_uint64() {
      remaining.to_int()
    } else {
      block
    }
    let first = self.read_at(source, offset, count)
    let second = other.read_at(destination, offset, count)
    let common = if first.data.length() < second.data.length() {
      first.data.length()
    } else {
      second.data.length()
    }
    if common == 0 {
      raise ProtocolError("file shrank during prefix verification")
    }
    if first.data[0:common] != second.data[0:common] {
      raise InvalidArgument("remote resume prefix does not match source")
    }
    offset = checked_offset(offset, common)
  }
}

///|
/// Resumes an existing destination after comparing all prefix bytes.
/// Distinct client connections allow source and destination to be different exports.
pub async fn Client::resume_copy_to(
  self : Client,
  destination_client : Client,
  source : String,
  destination : String,
) -> UInt64 {
  let input = self.resolve(source)
  let output = destination_client.resolve(destination)
  let first = self.metadata(input)
  let second = destination_client.metadata(output)
  if first.attributes.kind != 1U ||
    second.attributes.kind != 1U ||
    second.attributes.size > first.attributes.size {
    raise InvalidArgument("invalid cross-client resume files")
  }
  let prefix = second.attributes.size
  self.verify_remote_prefix(destination_client, input, output, prefix)
  // Check both versions before writing, including same-size prefix replacement.
  self.require_version(input, first.version())
  destination_client.require_version(output, second.version())
  let copied = self.copy_between_handles(
    destination_client,
    input,
    output,
    prefix,
    first.attributes.size - prefix,
  )
  self.require_version(input, first.version())
  if destination_client.getattr(output).size != first.attributes.size {
    raise ProtocolError("destination changed during cross-client resume")
  }
  copied
}

///|
/// Copies a pre-collected tree into a fresh destination on another connection.
/// Local buffering is bounded by the source block size; modes are restored last.
pub async fn Client::copy_tree_to(
  self : Client,
  destination_client : Client,
  source : String,
  destination : String,
  preserve_mode? : Bool = true,
) -> TreeTransfer {
  if path_components(destination).length() == 0 {
    raise InvalidArgument("cannot replace destination export root")
  }
  let entries = self.collect_tree(source)
  require_copy_kinds(entries)
  let modes : Array[(Handle, UInt)] = []
  let mut files = 0
  let mut directories = 0
  let mut symlinks = 0
  let mut bytes = 0UL
  for entry in entries {
    let path = join_path(destination, entry.relative)
    let mode = if preserve_mode {
      entry.attributes.mode & 4095U
    } else if entry.attributes.kind == 2U {
      493U
    } else {
      420U
    }
    match entry.attributes.kind {
      2U => {
        let handle = destination_client.mkdir(path, mode=448U)
        modes.push((handle, mode))
        directories += 1
      }
      1U => {
        let before = self.metadata(entry.handle)
        let handle = destination_client.create_file(path, mode=384U)
        let copied = self.copy_between_handles(
          destination_client,
          entry.handle,
          handle,
          0UL,
          before.attributes.size,
        )
        self.require_version(entry.handle, before.version())
        destination_client.setattr(handle, mode=Some(mode))
        files += 1
        bytes = checked_sum(bytes, copied)
      }
      5U => {
        ignore(destination_client.symlink(path, self.readlink(entry.handle)))
        symlinks += 1
      }
      _ => raise InvalidArgument("unsupported cross-client tree node")
    }
  }
  for i = modes.length() - 1; i >= 0; i = i - 1 {
    let (handle, mode) = modes[i]
    destination_client.setattr(handle, mode=Some(mode))
  }
  { files, directories, symlinks, bytes, }
}

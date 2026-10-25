///|
pub async fn[W : @io.Writer] Client::download_range(
  self : Client,
  handle : Handle,
  sink : W,
  offset : UInt64,
  length : UInt64,
) -> UInt64 {
  ignore(checked_sum(offset, length))
  let mut position = offset
  let mut remaining = length
  while remaining > 0UL {
    let count = if remaining < self.read_size.to_uint64() {
      remaining.to_int()
    } else {
      self.read_size
    }
    let part = self.read_at(handle, position, count)
    sink.write(part.data)
    position = checked_offset(position, part.data.length())
    remaining -= part.data.length().to_uint64()
    if part.eof {
      break
    }
  }
  position - offset
}

///|
pub async fn[R : @io.Reader] Client::upload_range(
  self : Client,
  handle : Handle,
  source : R,
  offset : UInt64,
  length : UInt64,
  committed? : Bool = false,
) -> UInt64 {
  ignore(checked_sum(offset, length))
  let mut position = offset
  let mut remaining = length
  while remaining > 0UL {
    let count = if remaining < self.options.block_size.to_uint64() {
      remaining.to_int()
    } else {
      self.options.block_size
    }
    match source.read_some(max_len=count) {
      None => raise ProtocolError("source ended before requested upload range")
      Some(bytes) => {
        if bytes.length() == 0 || bytes.length() > count {
          raise ProtocolError("source returned an invalid upload chunk length")
        }
        if committed {
          self.write_committed(handle, position, bytes)
        } else {
          self.write_all(handle, position, bytes)
        }
        position = checked_offset(position, bytes.length())
        remaining -= bytes.length().to_uint64()
      }
    }
  }
  position - offset
}

///|
pub async fn Client::read_bytes(
  self : Client,
  path : String,
  max_bytes? : Int = 1048576,
) -> Bytes {
  if max_bytes < 0 || max_bytes > self.options.max_record {
    raise InvalidArgument("invalid in-memory read budget")
  }
  let (handle, attributes) = self.resolve_attributes(path)
  if attributes.kind != 1U {
    raise InvalidArgument("read_bytes requires a regular file")
  }
  if attributes.size > max_bytes.to_uint64() {
    raise InvalidArgument("file exceeds in-memory read budget")
  }
  let data : Array[Byte] = []
  let mut offset = 0UL
  while true {
    // A one-byte probe distinguishes exact budget EOF from a growing file.
    let room = max_bytes - data.length()
    let count = if room < self.read_size { room + 1 } else { self.read_size }
    let part = self.read_at(handle, offset, count)
    if part.data.length() > room {
      raise ProtocolError("file grew beyond in-memory read budget")
    }
    for byte in part.data.to_array() {
      data.push(byte)
    }
    offset = checked_offset(offset, part.data.length())
    if part.eof {
      return Bytes::from_array(data)
    }
  } nobreak {
    raise ProtocolError("incomplete in-memory read")
  }
}

///|
pub async fn Client::write_bytes(
  self : Client,
  path : String,
  bytes : Bytes,
  mode? : UInt = 420U,
) -> Handle {
  let handle = self.create_file(path, mode~)
  self.write_all(handle, 0UL, bytes)
  handle
}

///|
pub async fn Client::read_text(
  self : Client,
  path : String,
  max_bytes? : Int = 1048576,
) -> String {
  @utf8.decode(self.read_bytes(path, max_bytes~))
}

///|
pub async fn Client::write_text(
  self : Client,
  path : String,
  text : String,
  mode? : UInt = 420U,
) -> Handle {
  self.write_bytes(path, @utf8.encode(text), mode~)
}

///|
pub(all) struct FileComparison {
  equal : Bool
  compared_bytes : UInt64
  first_difference : UInt64?
}

///|
/// Compares byte content using bounded blocks, not timestamps or file sizes alone.
pub async fn Client::compare_files(
  self : Client,
  left : String,
  right : String,
) -> FileComparison {
  let (a, aa) = self.resolve_attributes(left)
  let (b, ba) = self.resolve_attributes(right)
  if aa.kind != 1U || ba.kind != 1U {
    raise InvalidArgument("comparison requires regular files")
  }
  let mut offset = 0UL
  while true {
    let first = self.read_at(a, offset, self.read_size)
    let second = self.read_at(b, offset, self.read_size)
    // Short replies are legal, so compare only the shared prefix.
    let common = if first.data.length() < second.data.length() {
      first.data.length()
    } else {
      second.data.length()
    }
    for i in 0..<common {
      if first.data[i] != second.data[i] {
        let difference = checked_offset(offset, i)
        return {
          equal: false,
          compared_bytes: difference + 1UL,
          first_difference: Some(difference),
        }
      }
    }
    offset = checked_offset(offset, common)
    if common == 0 {
      let equal = first.eof &&
        second.eof &&
        first.data.length() == 0 &&
        second.data.length() == 0
      return {
        equal,
        compared_bytes: offset,
        first_difference: if equal {
          None
        } else {
          Some(offset)
        },
      }
    }
    if first.eof &&
      second.eof &&
      first.data.length() == common &&
      second.data.length() == common {
      return { equal: true, compared_bytes: offset, first_difference: None, }
    }
  } nobreak {
    raise ProtocolError("incomplete file comparison")
  }
}

///|
pub async fn Client::copy_file(
  self : Client,
  source : String,
  destination : String,
  preserve_mode? : Bool = true,
) -> UInt64 {
  let (input, attributes) = self.resolve_attributes(source)
  if attributes.kind != 1U {
    raise InvalidArgument("copy requires a regular source")
  }
  let output = self.create_file(destination, mode=384U)
  let copied = self.copy_handle(input, output, attributes.size)
  self.set_attributes(output, {
    ..AttributeUpdate::default(),
    mode: Some(if preserve_mode { attributes.mode & 4095U } else { 420U }),
  })
  copied
}

///|
async fn Client::copy_handle(
  self : Client,
  source : Handle,
  destination : Handle,
  size : UInt64,
) -> UInt64 {
  self.copy_between_handles(self, source, destination, 0UL, size)
}

///|
fn local_offset(value : UInt64) -> Int64 raise NfsError {
  if value > 9223372036854775807UL {
    raise InvalidArgument("offset exceeds local filesystem signed range")
  }
  value.reinterpret_as_int64()
}

///|
/// Resume only after verifying every existing prefix byte. Files are not snapshots.
pub async fn Client::resume_download(
  self : Client,
  remote_path : String,
  local_path : String,
) -> UInt64 {
  let (handle, attributes) = self.resolve_attributes(remote_path)
  if attributes.kind != 1U {
    raise InvalidArgument("resume requires a regular source")
  }
  ignore(local_offset(attributes.size))
  let file = @fs.open(local_path, mode=ReadWrite)
  defer file.close()
  if file.kind() != @fs.Regular {
    raise InvalidArgument("resume requires a regular local file")
  }
  let size = file.size()
  if size < 0L || size.reinterpret_as_uint64() > attributes.size {
    raise InvalidArgument("local file is larger than remote source")
  }
  let prefix = size.reinterpret_as_uint64()
  let mut offset = 0UL
  while offset < attributes.size {
    let remaining = if offset < prefix {
      prefix - offset
    } else {
      attributes.size - offset
    }
    let count = if remaining < self.read_size.to_uint64() {
      remaining.to_int()
    } else {
      self.read_size
    }
    let part = self.read_at(handle, offset, count)
    if part.data.length() == 0 {
      raise ProtocolError("source shrank during resume")
    }
    if offset < prefix {
      let existing = file.read_exactly_at(
        part.data.length(),
        position=local_offset(offset),
      )
      if existing != part.data {
        raise InvalidArgument("resume prefix does not match source")
      }
    } else {
      file.write_at(part.data, position=local_offset(offset))
    }
    offset = checked_offset(offset, part.data.length())
    if part.eof && offset < attributes.size {
      raise ProtocolError("source shrank during resume")
    }
  }
  if file.size() != local_offset(attributes.size) {
    raise ProtocolError("local destination changed during resume")
  }
  file.sync()
  offset - prefix
}

///|
pub async fn Client::resume_upload(
  self : Client,
  local_path : String,
  remote_path : String,
) -> UInt64 {
  let file = @fs.open(local_path, mode=ReadOnly)
  defer file.close()
  if file.kind() != @fs.Regular {
    raise InvalidArgument("resume requires a regular local source")
  }
  let signed_size = file.size()
  if signed_size < 0L {
    raise InvalidArgument("invalid local size")
  }
  let size = signed_size.reinterpret_as_uint64()
  let (handle, attributes) = self.resolve_attributes(remote_path)
  if attributes.kind != 1U || attributes.size > size {
    raise InvalidArgument("invalid remote resume destination")
  }
  let prefix = attributes.size
  let mut offset = 0UL
  while offset < size {
    let remaining = if offset < prefix {
      prefix - offset
    } else {
      size - offset
    }
    let count = if remaining < self.read_size.to_uint64() {
      remaining.to_int()
    } else {
      self.read_size
    }
    let bytes = file.read_exactly_at(count, position=local_offset(offset))
    if offset < prefix {
      let part = self.read_at(handle, offset, count)
      if part.data != bytes[0:part.data.length()].to_owned() ||
        part.data.length() == 0 {
        raise InvalidArgument("resume prefix does not match source")
      }
      offset = checked_offset(offset, part.data.length())
    } else {
      self.write_all(handle, offset, bytes)
      offset = checked_offset(offset, bytes.length())
    }
  }
  if self.getattr(handle).size != size || file.size() != signed_size {
    raise ProtocolError("file size changed during resume")
  }
  offset - prefix
}

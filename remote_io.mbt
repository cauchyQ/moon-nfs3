///|
/// Bridges NFS reads to async/io using the public backpressured pipe adapter.
/// Close the returned reader to cancel a partially consumed transfer.
pub async fn Client::open_reader(
  self : Client,
  path : String,
  offset? : UInt64 = 0UL,
  length? : UInt64? = None,
) -> @io.MemoryReader {
  let (handle, attributes) = self.resolve_attributes(path)
  if attributes.kind != 1U {
    raise InvalidArgument("reader requires a regular file")
  }
  let end = match length {
    Some(size) => Some(checked_sum(offset, size))
    None => None
  }
  @io.MemoryReader(sink => {
    let mut position = offset
    while true {
      let mut count = self.read_size
      if end is Some(limit) {
        if position >= limit {
          break
        }
        if limit - position < count.to_uint64() {
          count = (limit - position).to_int()
        }
      }
      let part = self.read_at(handle, position, count)
      sink.write(part.data)
      position = checked_offset(position, part.data.length())
      if part.eof {
        break
      }
    }
  })
}

///|
pub struct RemoteWriter {
  priv client : Client
  priv handle : Handle
  priv mut position : UInt64
  priv mut closed : Bool
  priv mut busy : Bool
}

///|
pub async fn Client::open_writer(
  self : Client,
  path : String,
  mode? : UInt = 420U,
) -> RemoteWriter {
  let handle = self.create_file(path, mode~)
  self.writer_for(handle)
}

///|
pub fn Client::writer_for(
  self : Client,
  handle : Handle,
  offset? : UInt64 = 0UL,
) -> RemoteWriter {
  { client: self, handle, position: offset, closed: false, busy: false, }
}

///|
pub fn RemoteWriter::position(self : RemoteWriter) -> UInt64 {
  self.position
}

///|
/// All accepted data uses FILE_SYNC; closing releases no server-side descriptor.
pub fn RemoteWriter::close(self : RemoteWriter) -> Unit {
  self.closed = true
}

///|
pub extend RemoteWriter with @io.Writer::{write_once, write, write_reader}

///|
pub impl @io.Writer for RemoteWriter with fn write_once(
  self,
  bytes,
  offset~,
  len~,
) {
  if self.closed {
    raise InvalidArgument("remote writer is closed")
  }
  if self.busy {
    raise InvalidArgument("concurrent remote writer use")
  }
  if offset < 0 ||
    len < 0 ||
    offset > bytes.length() ||
    len > bytes.length() - offset {
    raise InvalidArgument("invalid writer buffer range")
  }
  if len == 0 {
    return 0
  }
  let count = if len < self.client.write_size {
    len
  } else {
    self.client.write_size
  }
  self.busy = true
  defer {
    self.busy = false
  }
  let result = self.client.write_at(
    self.handle,
    self.position,
    bytes[offset:offset + count].to_owned(),
  )
  self.position = checked_offset(self.position, result.count)
  result.count
}

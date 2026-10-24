///|
/// Streams to a fresh remote file. On failure, a partial file can remain.
pub async fn[R : @io.Reader] Client::upload_from(
  self : Client,
  path : String,
  source : R,
  committed? : Bool = false,
) -> UInt64 {
  let handle = self.create_file(path)
  let mut offset = 0UL
  while true {
    match source.read_some(max_len=self.options.block_size) {
      None => return offset
      Some(bytes) => {
        if bytes.length() == 0 {
          raise ProtocolError("source made no progress")
        }
        if committed {
          self.write_committed(handle, offset, bytes)
        } else {
          self.write_all(handle, offset, bytes)
        }
        offset = checked_offset(offset, bytes.length())
      }
    }
  } nobreak {
    raise ProtocolError("incomplete upload")
  }
}

///|
/// Streams until the server's EOF. Concurrent file changes are not a snapshot.
pub async fn[W : @io.Writer] Client::download_to(
  self : Client,
  path : String,
  sink : W,
) -> UInt64 {
  let (handle, attributes) = self.resolve_attributes(path)
  if attributes.kind != 1U {
    raise InvalidArgument("download requires a regular file")
  }
  self.download_handle(handle, sink)
}

///|
async fn[W : @io.Writer] Client::download_handle(
  self : Client,
  handle : Handle,
  sink : W,
) -> UInt64 {
  let mut offset = 0UL
  while true {
    let result = self.read_at(handle, offset, self.read_size)
    sink.write(result.data)
    offset = checked_offset(offset, result.data.length())
    if result.eof {
      return offset
    }
  } nobreak {
    raise ProtocolError("incomplete download")
  }
}

///|
pub async fn Client::upload(
  self : Client,
  local_path : String,
  remote_path : String,
  committed? : Bool = false,
) -> UInt64 {
  let file = @fs.open(local_path, mode=ReadOnly)
  defer file.close()
  if file.kind() != @fs.Regular {
    raise InvalidArgument("upload requires a regular local file")
  }
  self.upload_from(remote_path, file, committed~)
}

///|
/// Creates a new local file; existing destinations are never truncated.
pub async fn Client::download(
  self : Client,
  remote_path : String,
  local_path : String,
) -> UInt64 {
  // Validate the source before creating a local destination. Reuse the handle
  // so preflight does not add a second path lookup to the transfer.
  let (handle, attributes) = self.resolve_attributes(remote_path)
  if attributes.kind != 1U {
    raise InvalidArgument("download requires a regular file")
  }
  let file = @fs.open(local_path, mode=WriteOnly, create_mode=CreateNew)
  defer file.close()
  let size = self.download_handle(handle, file)
  file.sync()
  size
}

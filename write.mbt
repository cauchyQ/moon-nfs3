///|
pub(all) enum Stability {
  Unstable
  DataSync
  FileSync
}

///|
fn Stability::wire(self : Stability) -> UInt {
  match self {
    Unstable => 0U
    DataSync => 1U
    FileSync => 2U
  }
}

///|
pub(all) struct WriteResult {
  count : Int
  committed : Stability
  verifier : Bytes
}

///|
pub async fn Client::write_at(
  self : Client,
  handle : Handle,
  offset : UInt64,
  data : Bytes,
  stability? : Stability = FileSync,
) -> WriteResult {
  if data.length() > self.write_size {
    raise InvalidArgument("write exceeds negotiated block size")
  }
  ignore(checked_offset(offset, data.length()))
  let w = @xdr.Writer::new(limits=limits(self.options))
  put_handle(w, handle)
  w.write_uhyper(offset)
  w.write_uint(data.length().reinterpret_as_uint())
  w.write_uint(stability.wire())
  w.write_opaque(data.to_array())
  let r = self.invoke(7U, w, modifying=true)
  read_wcc(r)
  let count = r.read_uint()
  let level = r.read_uint()
  let verifier = Bytes::from_array(r.read_fixed(8))
  r.finish()
  if count > data.length().reinterpret_as_uint() ||
    (count == 0U && data.length() > 0) ||
    level > 2U ||
    level < stability.wire() {
    raise ProtocolError(
      "invalid WRITE count or weaker commitment than requested",
    )
  }
  {
    count: count.reinterpret_as_int(),
    committed: match level {
      0U => Unstable
      1U => DataSync
      _ => FileSync
    },
    verifier,
  }
}

///|
pub async fn Client::commit(
  self : Client,
  handle : Handle,
  offset : UInt64,
  count : UInt,
) -> Bytes {
  if offset > 18446744073709551615UL - count.to_uint64() {
    raise InvalidArgument("COMMIT range overflow")
  }
  let w = @xdr.Writer::new()
  put_handle(w, handle)
  w.write_uhyper(offset)
  w.write_uint(count)
  let r = self.invoke(21U, w, modifying=true)
  read_wcc(r)
  let verifier = Bytes::from_array(r.read_fixed(8))
  r.finish()
  verifier
}

///|
/// Stable bounded-buffer writes, correctly advancing after short writes.
pub async fn Client::write_all(
  self : Client,
  handle : Handle,
  offset : UInt64,
  data : Bytes,
) -> Unit {
  ignore(checked_offset(offset, data.length()))
  let mut position = 0
  while position < data.length() {
    let end = if data.length() - position < self.write_size {
      data.length()
    } else {
      position + self.write_size
    }
    let result = self.write_at(
      handle,
      checked_offset(offset, position),
      data[position:end].to_owned(),
    )
    position += result.count
  }
}

///|
/// Writes one bounded replay window, verifying COMMIT for pending data or metadata.
/// Retains the data until durability is confirmed; recovery has a finite retry budget.
pub async fn Client::write_committed(
  self : Client,
  handle : Handle,
  offset : UInt64,
  data : Bytes,
  retries? : Int = 2,
) -> Unit {
  if retries < 0 || retries > 10 || data.length() > self.options.block_size {
    raise InvalidArgument("invalid replay window")
  }
  ignore(checked_offset(offset, data.length()))
  if data.length() == 0 {
    return
  }
  for attempt = 0; attempt <= retries; attempt = attempt + 1 {
    let mut position = 0
    let mut verifier : Bytes? = None
    let mut changed = false
    let mut needs_commit = false
    while position < data.length() {
      let end = if data.length() - position < self.write_size {
        data.length()
      } else {
        position + self.write_size
      }
      let part = self.write_at(
        handle,
        checked_offset(offset, position),
        data[position:end].to_owned(),
        stability=Unstable,
      )
      // Only pending data depends on the server's boot verifier.
      if !(part.committed is FileSync) {
        needs_commit = true
      }
      if needs_commit {
        match verifier {
          Some(old) if old != part.verifier => {
            changed = true
            break
          }
          _ => verifier = Some(part.verifier)
        }
      }
      position += part.count
    }
    if !changed && !needs_commit {
      return
    }
    if !changed {
      let confirmed = self.commit(
        handle,
        offset,
        data.length().reinterpret_as_uint(),
      )
      if verifier is Some(v) && v == confirmed {
        return
      }
    }
  }
  raise RpcFailure("server write verifier changed beyond replay budget")
}

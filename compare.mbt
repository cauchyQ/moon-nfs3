///|
/// Each input retains its unread tail, so asymmetric short replies do not cause
/// the larger reply to be fetched again. Buffering is bounded by two read blocks.
async fn Client::compare_handles(
  self : Client,
  left : Handle,
  other : Client,
  right : Handle,
  length? : UInt64? = None,
) -> FileComparison {
  let mut first : ReadResult = { data: b"", eof: false, }
  let mut second : ReadResult = { data: b"", eof: false, }
  let mut first_index = 0
  let mut second_index = 0
  let mut offset = 0UL
  while true {
    if length is Some(limit) && offset == limit {
      return { equal: true, compared_bytes: offset, first_difference: None, }
    }
    if first_index == first.data.length() && !first.eof {
      let count = match length {
        Some(limit) if limit - offset < self.read_size.to_uint64() =>
          (limit - offset).to_int()
        _ => self.read_size
      }
      first = self.read_at(left, offset, count)
      first_index = 0
    }
    if second_index == second.data.length() && !second.eof {
      let count = match length {
        Some(limit) if limit - offset < other.read_size.to_uint64() =>
          (limit - offset).to_int()
        _ => other.read_size
      }
      second = other.read_at(right, offset, count)
      second_index = 0
    }
    let first_left = first.data.length() - first_index
    let second_left = second.data.length() - second_index
    let common = if first_left < second_left { first_left } else { second_left }
    for i in 0..<common {
      if first.data[first_index + i] != second.data[second_index + i] {
        let difference = checked_offset(offset, i)
        return {
          equal: false,
          compared_bytes: difference + 1UL,
          first_difference: Some(difference),
        }
      }
    }
    if common == 0 {
      let equal = first_left == 0 && second_left == 0 && first.eof && second.eof
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
    offset = checked_offset(offset, common)
    first_index += common
    second_index += common
  } nobreak {
    raise ProtocolError("incomplete file comparison")
  }
}

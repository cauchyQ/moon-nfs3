///|
priv struct RpcCounters {
  mut calls : UInt64
  mut replies : UInt64
  mut request_bytes : UInt64
  mut response_bytes : UInt64
  mut failures : UInt64
}

///|
/// Payload counts exclude TCP and record-marker overhead. Requests count attempts;
/// a lost reply can follow a request the server has already executed.
pub(all) struct RpcStatistics {
  calls : UInt64
  replies : UInt64
  request_bytes : UInt64
  response_bytes : UInt64
  failures : UInt64
}

///|
pub fn Rpc::statistics(self : Rpc) -> RpcStatistics {
  let counters = self.counters
  {
    calls: counters.calls,
    replies: counters.replies,
    request_bytes: counters.request_bytes,
    response_bytes: counters.response_bytes,
    failures: counters.failures,
  }
}

///|
pub fn Client::statistics(self : Client) -> RpcStatistics {
  self.rpc.statistics()
}

///|
pub fn RpcStatistics::since(
  self : RpcStatistics,
  before : RpcStatistics,
) -> RpcStatistics raise {
  if self.calls < before.calls ||
    self.replies < before.replies ||
    self.request_bytes < before.request_bytes ||
    self.response_bytes < before.response_bytes ||
    self.failures < before.failures {
    raise InvalidArgument(
      "statistics baseline does not precede current counters",
    )
  }
  {
    calls: self.calls - before.calls,
    replies: self.replies - before.replies,
    request_bytes: self.request_bytes - before.request_bytes,
    response_bytes: self.response_bytes - before.response_bytes,
    failures: self.failures - before.failures,
  }
}

///|
pub(all) struct ReadBenchmark {
  rounds : Int
  bytes : UInt64
  elapsed_ms : Int64
  fastest_ms : Int64
  slowest_ms : Int64
  rpc : RpcStatistics
}

///|
pub fn ReadBenchmark::mebibytes_per_second(self : ReadBenchmark) -> Double {
  if self.elapsed_ms <= 0L {
    return 0.0
  }
  self.bytes.to_double() * 1000.0 / self.elapsed_ms.to_double() / 1048576.0
}

///|
/// Measures real reads through this connection, with no application-level cache.
/// Server/OS caches can affect results. Time is wall-clock milliseconds.
pub async fn Client::benchmark_read(
  self : Client,
  path : String,
  rounds? : Int = 3,
  max_bytes? : UInt64 = 1073741824UL,
) -> ReadBenchmark {
  if rounds < 1 || rounds > 1000 {
    raise InvalidArgument("benchmark rounds must be 1..1000")
  }
  let handle = self.resolve(path)
  let before = self.metadata(handle)
  if before.attributes.kind != 1U {
    raise InvalidArgument("benchmark requires a regular file")
  }
  let size = before.attributes.size
  if size > max_bytes / rounds.to_uint64() {
    raise InvalidArgument("benchmark exceeds total byte budget")
  }
  let counters = self.statistics()
  let started = @async.now()
  let mut fastest_ms = 9223372036854775807L
  let mut slowest_ms = 0L
  let mut bytes = 0UL
  for _ in 0..<rounds {
    let start = @async.now()
    let mut offset = 0UL
    while offset < size {
      let remaining = size - offset
      let count = if remaining < self.read_size.to_uint64() {
        remaining.to_int()
      } else {
        self.read_size
      }
      let part = self.read_at(handle, offset, count)
      if part.data.length() == 0 {
        raise ProtocolError("file shrank during benchmark")
      }
      offset = checked_offset(offset, part.data.length())
      if part.eof && offset < size {
        raise ProtocolError("file shrank during benchmark")
      }
    }
    self.require_version(handle, before.version())
    bytes = checked_sum(bytes, offset)
    let duration = @async.now() - start
    if duration < 0L {
      raise ProtocolError("clock moved backwards during benchmark")
    }
    if duration < fastest_ms {
      fastest_ms = duration
    }
    if duration > slowest_ms {
      slowest_ms = duration
    }
  }
  let elapsed_ms = @async.now() - started
  if elapsed_ms < 0L {
    raise ProtocolError("clock moved backwards during benchmark")
  }
  {
    rounds,
    bytes,
    elapsed_ms,
    fastest_ms,
    slowest_ms,
    rpc: self.statistics().since(counters),
  }
}

///|
pub suberror NfsError {
  InvalidArgument(String)
  ProtocolError(String)
  RpcFailure(String)
  Status(UInt)
  OutcomeUnknown(String)
}

///|
pub fn NfsError::message(self : NfsError) -> String {
  match self {
    InvalidArgument(reason) => "invalid argument: " + reason
    ProtocolError(reason) => "invalid NFS/RPC response: " + reason
    RpcFailure(reason) => "RPC failure: " + reason
    Status(code) => "NFS status \{status_name(code)} (\{code})"
    OutcomeUnknown(reason) => "operation outcome unknown: " + reason
  }
}

///|
pub extend NfsError with Show::{to_string, output}

///|
pub impl Show for NfsError with fn output(self, logger) {
  logger.write_string(self.message())
}

///|
/// TCP connections are sequential: one outstanding RPC per connection.
pub(all) struct Options {
  uid : UInt
  gid : UInt
  groups : Array[UInt]
  timeout_ms : Int
  block_size : Int
  max_record : Int
  max_entries : Int
}

///|
pub fn Options::default() -> Options {
  {
    uid: 65534U,
    gid: 65534U,
    groups: [],
    timeout_ms: 10000,
    block_size: 65536,
    max_record: 1048576,
    max_entries: 100000,
  }
}

///|
pub fn Options::validate(self : Options) -> Unit raise NfsError {
  if self.timeout_ms <= 0 ||
    self.block_size <= 0 ||
    self.max_record < 4096 ||
    self.max_record > 67108864 ||
    self.block_size > self.max_record - 4096 ||
    self.groups.length() > 16 ||
    self.max_entries <= 0 {
    raise InvalidArgument(
      "invalid timeout, buffer budget, entry budget or group count",
    )
  }
}

///|
pub fn checked_offset(offset : UInt64, count : Int) -> UInt64 raise NfsError {
  if count < 0 || offset > 18446744073709551615UL - count.to_uint64() {
    raise InvalidArgument("file offset overflow")
  }
  offset + count.to_uint64()
}

///|
test "default resource limits and offset overflow" {
  Options::default().validate()
  assert_eq(checked_offset(4294967296UL, 1), 4294967297UL)
  try {
    ignore(checked_offset(18446744073709551615UL, 1))
    fail("expected overflow")
  } catch {
    InvalidArgument(_) => ()
    other => raise other
  }
}

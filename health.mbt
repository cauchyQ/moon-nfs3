///|
pub(all) struct HealthReport {
  attributes : Attributes
  granted_access : UInt
  filesystem : FileSystemInfo
  space : Space
  paths : PathConfig
  rpc : RpcStatistics
  elapsed_ms : Int64
}

///|
/// Read-only service diagnostics: validates the RPC endpoint, selected object,
/// access mask, negotiated filesystem capabilities and capacity replies.
pub async fn Client::health_check(
  self : Client,
  path? : String = "/",
) -> HealthReport {
  let started = @async.now()
  let counters = self.statistics()
  self.ping()
  let (handle, attributes) = self.resolve_attributes(path)
  let granted_access = self.access(handle, 63U)
  let filesystem = self.fsinfo(handle=Some(handle))
  let space = self.space(handle=Some(handle))
  let paths = self.pathconf(handle=Some(handle))
  let elapsed_ms = @async.now() - started
  if elapsed_ms < 0L {
    raise ProtocolError("clock moved backwards during health check")
  }
  {
    attributes,
    granted_access,
    filesystem,
    space,
    paths,
    rpc: self.statistics().since(counters),
    elapsed_ms,
  }
}

///|
pub fn HealthReport::to_json(self : HealthReport) -> Json {
  Json::object(
    Map([
      ("kind", file_kind_name(self.attributes.kind).to_json()),
      ("granted_access", self.granted_access.to_json()),
      ("read_max", self.filesystem.read_max.to_json()),
      ("write_max", self.filesystem.write_max.to_json()),
      ("max_file_size", self.filesystem.max_file_size.to_string().to_json()),
      ("hard_links", self.filesystem.supports_links().to_json()),
      ("symbolic_links", self.filesystem.supports_symlinks().to_json()),
      ("set_time", self.filesystem.can_set_time().to_json()),
      ("total_bytes", self.space.total_bytes.to_string().to_json()),
      ("available_bytes", self.space.available_bytes.to_string().to_json()),
      ("name_max", self.paths.name_max.to_json()),
      ("calls", self.rpc.calls.to_string().to_json()),
      ("replies", self.rpc.replies.to_string().to_json()),
      ("request_payload_bytes", self.rpc.request_bytes.to_string().to_json()),
      ("response_payload_bytes", self.rpc.response_bytes.to_string().to_json()),
      ("elapsed_ms", self.elapsed_ms.to_string().to_json()),
    ]),
  )
}

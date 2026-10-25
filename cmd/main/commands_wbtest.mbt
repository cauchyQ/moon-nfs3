///|
test "invalid CLI requests fail before connection setup" {
  for
    args in [
      ["nfs", "unknown", "host", "/"],
      ["nfs", "rm", "host", "/"],
      ["nfs", "put", "host", "/", "only-one"],
      ["nfs", "get-range", "host", "/", "file", "out", "-1", "5"],
      ["nfs", "services", "host", "unexpected-export"],
    ] {
    try parse_request(args) catch {
      _ => ()
    } noraise {
      _ => fail("invalid CLI request accepted")
    }
  }
  let service = parse_request(["nfs", "services", "host"])
  assert_eq(service.export_path, "")
  let root = parse_request(["nfs", "stat", "host", "/export"])
  assert_eq(root.operands.length(), 0)
}

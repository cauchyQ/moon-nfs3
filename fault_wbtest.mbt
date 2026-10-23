///|
async fn with_fake(
  steps : Int,
  response : (@xdr.RpcCall) -> @xdr.RpcReply? raise,
  action : async (Client) -> Unit,
) -> Unit {
  let listener = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer listener.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| tasks => {
      tasks.spawn_bg() <| () => {
        let (socket, _) = listener.accept()
        defer socket.close()
        for _ in 0..<steps {
          let header = @xdr.Reader::new(socket.read_exactly(4).to_array())
          let size = header.read_uint() & 0x7fffffffU
          let request = @xdr.decode_call(
            socket.read_exactly(size.reinterpret_as_int()).to_array(),
          )
          match response(request) {
            None => return
            Some(reply) =>
              socket.write(
                Bytes::from_array(
                  @xdr.fragment_record(@xdr.encode_reply(reply), 7),
                ),
              )
          }
        }
      }
      let options = Options::default()
      let rpc = Rpc::connect("127.0.0.1", listener.addr.port(), options~)
      defer rpc.close()
      let client : Client = {
        rpc,
        options,
        root: { bytes: b"root", },
        read_size: 65536,
        write_size: 65536,
      }
      action(client)
    }
  })
}

///|
fn ok_reply(request : @xdr.RpcCall, w : @xdr.Writer) -> @xdr.RpcReply? {
  Some({
    xid: request.xid,
    body: Accepted(@xdr.OpaqueAuth::none(), Success(w.bytes())),
  })
}

///|
fn read_reply(
  request : @xdr.RpcCall,
  count : UInt,
  eof : Bool,
  data : Bytes,
) -> @xdr.RpcReply? raise {
  let w = @xdr.Writer::new()
  w.write_uint(0U)
  w.write_bool(false)
  w.write_uint(count)
  w.write_bool(eof)
  w.write_opaque(data.to_array())
  ok_reply(request, w)
}

///|
fn write_reply(
  request : @xdr.RpcCall,
  count : UInt,
  level : UInt,
  verifier : Bytes,
) -> @xdr.RpcReply? raise {
  let w = @xdr.Writer::new()
  w.write_uint(0U)
  w.write_bool(false)
  w.write_bool(false)
  if request.procedure == 7U {
    w.write_uint(count)
    w.write_uint(level)
  }
  w.write_fixed(verifier.to_array())
  ok_reply(request, w)
}

///|
async test "mismatched RPC XID invalidates the connection" {
  with_fake(
    1,
    req => {
      Some({
        xid: req.xid + 1U,
        body: Accepted(@xdr.OpaqueAuth::none(), Success([])),
      })
    },
    client => {
      try client.ping() catch {
        ProtocolError(_) => ()
        e => raise e
      } noraise {
        _ => fail("accepted wrong XID")
      }
      try client.ping() catch {
        RpcFailure(_) => ()
        e => raise e
      } noraise {
        _ => fail("reused broken connection")
      }
    },
  )
}

///|
async test "lost mutation reply reports unknown outcome" {
  with_fake(1, _ => None, client => {
    try client.write_at(client.root_handle(), 0UL, b"x") catch {
      OutcomeUnknown(_) => ()
      e => raise e
    } noraise {
      _ => fail("lost write reply was accepted")
    }
  })
}

///|
async test "READ validates reported count against actual payload" {
  with_fake(1, req => read_reply(req, 3U, true, b"a"), client => {
    try client.read_at(client.root_handle(), 0UL, 4) catch {
      ProtocolError(_) => ()
      e => raise e
    } noraise {
      _ => fail("invalid count accepted")
    }
  })
}

///|
async test "READ rejects zero progress without EOF" {
  with_fake(1, req => read_reply(req, 0U, false, b""), client => {
    try client.read_at(client.root_handle(), 0UL, 4) catch {
      ProtocolError(_) => ()
      e => raise e
    } noraise {
      _ => fail("zero progress accepted")
    }
  })
}

///|
async test "short READ is not automatically EOF" {
  with_fake(1, req => read_reply(req, 1U, false, b"a"), client => {
    let part = client.read_at(client.root_handle(), 4294967296UL, 4)
    assert_eq(part.data, b"a")
    assert_false(part.eof)
  })
}

///|
async test "short WRITE advances only acknowledged bytes at 64-bit offsets" {
  let mut calls = 0
  with_fake(
    3,
    req => {
      let r = @xdr.Reader::new(req.arguments)
      ignore(get_handle(r))
      assert_eq(r.read_uhyper(), 4294967296UL + calls.to_uint64())
      assert_eq(r.read_uint(), (3 - calls).reinterpret_as_uint())
      assert_eq(r.read_uint(), 2U)
      assert_eq(Bytes::from_array(r.read_opaque()), b"abc"[calls:].to_owned())
      r.finish()
      calls += 1
      write_reply(req, 1U, 2U, b"12345678")
    },
    client => client.write_all(client.root_handle(), 4294967296UL, b"abc"),
  )
  assert_eq(calls, 3)
}

///|
async test "stable WRITE rejects downgraded durability" {
  with_fake(1, req => write_reply(req, 1U, 0U, b"12345678"), client => {
    try client.write_at(client.root_handle(), 0UL, b"a") catch {
      ProtocolError(_) => ()
      e => raise e
    } noraise {
      _ => fail("weaker durability accepted")
    }
  })
}

///|
async test "COMMIT verifier change replays retained bytes" {
  let mut calls = 0
  with_fake(
    4,
    req => {
      calls += 1
      assert_eq(req.procedure, if calls % 2 == 1 { 7U } else { 21U })
      let verifier = if calls == 1 { b"oldboot!" } else { b"newboot!" }
      write_reply(req, 3U, 0U, verifier)
    },
    client => client.write_committed(client.root_handle(), 0UL, b"abc"),
  )
  assert_eq(calls, 4)
}

///|
async test "COMMIT verifier mismatch stops at retry budget" {
  with_fake(
    2,
    req => {
      write_reply(
        req,
        1U,
        0U,
        if req.procedure == 7U {
          b"oldboot!"
        } else {
          b"newboot!"
        },
      )
    },
    client => {
      try
        client.write_committed(client.root_handle(), 0UL, b"a", retries=0)
      catch {
        RpcFailure(_) => ()
        e => raise e
      } noraise {
        _ => fail("uncommitted data accepted")
      }
    },
  )
}

///|
async test "directory pagination preserves BAD_COOKIE as server status" {
  with_fake(
    1,
    req => {
      let w = @xdr.Writer::new()
      w.write_uint(10003U)
      w.write_bool(false)
      ok_reply(req, w)
    },
    client => {
      try client.list_dir("/") catch {
        Status(code) => assert_eq(code, 10003U)
        e => raise e
      } noraise {
        _ => fail("stale cookie accepted")
      }
    },
  )
}

///|
async test "repeated directory cookie cannot create an infinite traversal" {
  with_fake(
    2,
    req => {
      let w = @xdr.Writer::new()
      w.write_uint(0U)
      w.write_bool(false)
      w.write_fixed(b"12345678".to_array())
      w.write_bool(true)
      w.write_uhyper(1UL)
      w.write_opaque(b"entry".to_array())
      w.write_uhyper(1UL)
      w.write_bool(false)
      w.write_bool(false)
      w.write_bool(false)
      w.write_bool(false)
      ok_reply(req, w)
    },
    client => {
      try client.list_dir("/") catch {
        ProtocolError(_) => ()
        e => raise e
      } noraise {
        _ => fail("cookie loop accepted")
      }
    },
  )
}

///|
fn metadata_reply(
  request : @xdr.RpcCall,
  include_attributes : Bool,
  kind : UInt,
  size : UInt64,
) -> @xdr.RpcReply? raise {
  let w = @xdr.Writer::new()
  w.write_uint(0U)
  if request.procedure == 3U {
    put_handle(w, { bytes: b"file", })
    w.write_bool(include_attributes)
  } else {
    assert_eq(request.procedure, 1U)
  }
  if include_attributes {
    w.write_uint(kind)
    for value in [420U, 1U, 65534U, 65534U] {
      w.write_uint(value) // mode, links, uid, gid
    }
    w.write_uhyper(size)
    w.write_uhyper(size)
    w.write_uint(0U)
    w.write_uint(0U) // device numbers
    w.write_uhyper(1UL)
    w.write_uhyper(2UL) // filesystem and file IDs
    for _ in 0..<6 {
      w.write_uint(0U) // seconds and nanoseconds for three timestamps
    }
  }
  if request.procedure == 3U {
    w.write_bool(false) // parent attributes
  }
  ok_reply(request, w)
}

///|
async test "stat uses final LOOKUP attributes without an extra RPC" {
  with_fake(
    1,
    request => {
      assert_eq(request.procedure, 3U)
      metadata_reply(request, true, 1U, 42UL)
    },
    client => assert_eq(client.stat("file").size, 42UL),
  )
}

///|
async test "missing final LOOKUP attributes fall back to GETATTR, not parent data" {
  let mut calls = 0
  with_fake(
    3,
    request => {
      calls += 1
      assert_eq(request.procedure, if calls < 3 { 3U } else { 1U })
      metadata_reply(
        request,
        calls != 2,
        if calls == 1 {
          2U
        } else {
          1U
        },
        if calls == 1 {
          11UL
        } else {
          42UL
        },
      )
    },
    client => {
      let attributes = client.stat("directory/file")
      assert_eq(attributes.kind, 1U)
      assert_eq(attributes.size, 42UL)
    },
  )
  assert_eq(calls, 3)
}

///|
async test "stat of the export root still uses GETATTR" {
  with_fake(
    1,
    request => {
      assert_eq(request.procedure, 1U)
      metadata_reply(request, true, 2U, 11UL)
    },
    client => assert_eq(client.stat("/").kind, 2U),
  )
}

///|
async test "stable write window skips COMMIT across server boot changes" {
  let mut calls = 0
  with_fake(
    2,
    request => {
      calls += 1
      assert_eq(request.procedure, 7U)
      let r = @xdr.Reader::new(request.arguments)
      ignore(get_handle(r))
      assert_eq(r.read_uhyper(), (calls - 1).to_uint64())
      write_reply(
        request,
        1U,
        2U,
        if calls == 1 {
          b"oldboot!"
        } else {
          b"newboot!"
        },
      )
    },
    client => client.write_committed(client.root_handle(), 0UL, b"ab"),
  )
  assert_eq(calls, 2)
}

///|
async test "stable prefix does not pin the verifier for an unstable suffix" {
  let mut calls = 0
  with_fake(
    3,
    request => {
      calls += 1
      assert_eq(request.procedure, if calls < 3 { 7U } else { 21U })
      write_reply(
        request,
        1U,
        if calls == 1 {
          2U
        } else {
          0U
        },
        if calls == 1 {
          b"oldboot!"
        } else {
          b"newboot!"
        },
      )
    },
    client => {
      client.write_size = 1
      client.write_committed(client.root_handle(), 0UL, b"ab")
    },
  )
  assert_eq(calls, 3)
}

///|
async test "DATA_SYNC still requires metadata COMMIT" {
  let mut calls = 0
  with_fake(
    2,
    request => {
      calls += 1
      assert_eq(request.procedure, if calls == 1 { 7U } else { 21U })
      write_reply(request, 1U, 1U, b"12345678")
    },
    client => client.write_committed(client.root_handle(), 0UL, b"a"),
  )
  assert_eq(calls, 2)
}

///|
async test "wrong mutation XID is an unknown outcome and closes the session" {
  with_fake(
    1,
    request => {
      Some({
        xid: request.xid + 1U,
        body: Accepted(@xdr.OpaqueAuth::none(), Success([])),
      })
    },
    client => {
      try client.write_at(client.root_handle(), 0UL, b"x") catch {
        OutcomeUnknown(_) => ()
        error => raise error
      } noraise {
        _ => fail("mutation reply was not confirmed")
      }
      try client.ping() catch {
        RpcFailure(_) => ()
        error => raise error
      } noraise {
        _ => fail("invalid session remained usable")
      }
    },
  )
}

///|
async test "changed verifier on a successful final page invalidates traversal" {
  let mut calls = 0
  with_fake(
    2,
    request => {
      calls += 1
      let w = @xdr.Writer::new()
      w.write_uint(0U)
      w.write_bool(false)
      w.write_fixed(
        (if calls == 1 { b"oldview!" } else { b"newview!" }).to_array(),
      )
      w.write_bool(true)
      w.write_uhyper(calls.to_uint64())
      w.write_opaque(b"entry".to_array())
      w.write_uhyper(calls.to_uint64())
      w.write_bool(false)
      w.write_bool(false)
      w.write_bool(false)
      w.write_bool(calls == 2)
      ok_reply(request, w)
    },
    client => {
      try client.list_dir("/") catch {
        ProtocolError(_) => ()
        error => raise error
      } noraise {
        _ => fail("mixed directory views accepted")
      }
    },
  )
}

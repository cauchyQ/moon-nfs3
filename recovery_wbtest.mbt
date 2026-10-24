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

///|
fn test_attributes(
  w : @xdr.Writer,
  kind : UInt,
  fileid : UInt64,
  size : UInt64,
  modified_seconds? : UInt = 0U,
) -> Unit raise {
  w.write_uint(kind)
  for value in [420U, 1U, 65534U, 65534U] {
    w.write_uint(value)
  }
  w.write_uhyper(size)
  w.write_uhyper(size)
  w.write_uint(0U)
  w.write_uint(0U)
  w.write_uhyper(1UL)
  w.write_uhyper(fileid)
  for i in 0..<6 {
    w.write_uint(if i == 2 { modified_seconds } else { 0U })
  }
}

///|
fn test_created(req : @xdr.RpcCall) -> @xdr.RpcReply? raise {
  let w = @xdr.Writer::new()
  w.write_uint(0U)
  w.write_bool(true)
  put_handle(w, { bytes: b"created", })
  w.write_bool(false)
  w.write_bool(false)
  w.write_bool(false)
  ok_reply(req, w)
}

///|
test "attribute updates validate nanoseconds and preserve optional fields" {
  let w = @xdr.Writer::new()
  put_attribute_update(w, {
    ..AttributeUpdate::default(),
    uid: Some(4294967295U),
    size: Some(4294967297UL),
    modified: ExactTime({ seconds: 123U, nanoseconds: 999999999U, }),
  })
  let r = @xdr.Reader::new(w.bytes())
  assert_false(r.read_bool())
  assert_true(r.read_bool())
  assert_eq(r.read_uint(), 4294967295U)
  assert_false(r.read_bool())
  assert_true(r.read_bool())
  assert_eq(r.read_uhyper(), 4294967297UL)
  assert_eq(r.read_uint(), 0U)
  assert_eq(r.read_uint(), 2U)
  assert_eq(r.read_uint(), 123U)
  assert_eq(r.read_uint(), 999999999U)
  r.finish()
  try Timestamp::{ seconds: 0U, nanoseconds: 1000000000U, }.validate() catch {
    InvalidArgument(_) => ()
    error => raise error
  } noraise {
    _ => fail("invalid timestamp accepted")
  }
}

///|
async test "SETATTR sends an exact ctime guard" {
  with_fake(
    1,
    req => {
      assert_eq(req.procedure, 2U)
      let r = @xdr.Reader::new(req.arguments)
      ignore(get_handle(r))
      for _ in 0..<4 {
        assert_false(r.read_bool())
      }
      assert_eq(r.read_uint(), 0U)
      assert_eq(r.read_uint(), 0U)
      assert_true(r.read_bool())
      assert_eq(r.read_uint(), 17U)
      assert_eq(r.read_uint(), 19U)
      r.finish()
      write_reply(req, 0U, 0U, b"")
    },
    client => {
      client.set_attributes(
        client.root_handle(),
        AttributeUpdate::default(),
        ctime_guard=Some({ seconds: 17U, nanoseconds: 19U, }),
      )
    },
  )
}

///|
async test "SYMLINK serializes a relative target without resolving it" {
  with_fake(
    1,
    req => {
      assert_eq(req.procedure, 10U)
      let r = @xdr.Reader::new(req.arguments)
      assert_eq(get_handle(r).bytes, b"root")
      assert_eq(Bytes::from_array(r.read_opaque()), b"link")
      assert_true(r.read_bool())
      assert_eq(r.read_uint(), 511U)
      for _ in 0..<3 {
        assert_false(r.read_bool())
      }
      assert_eq(r.read_uint(), 0U)
      assert_eq(r.read_uint(), 0U)
      assert_eq(Bytes::from_array(r.read_opaque()), b"../target")
      r.finish()
      test_created(req)
    },
    client => assert_eq(client.symlink("link", b"../target").bytes, b"created"),
  )
}

///|
async test "MKNOD encodes the device discriminant and numbers" {
  with_fake(
    1,
    req => {
      assert_eq(req.procedure, 11U)
      let r = @xdr.Reader::new(req.arguments)
      ignore(get_handle(r))
      ignore(r.read_opaque())
      assert_eq(r.read_uint(), 4U)
      assert_true(r.read_bool())
      assert_eq(r.read_uint(), 384U)
      for _ in 0..<3 {
        assert_false(r.read_bool())
      }
      assert_eq(r.read_uint(), 0U)
      assert_eq(r.read_uint(), 0U)
      assert_eq(r.read_uint(), 8U)
      assert_eq(r.read_uint(), 17U)
      r.finish()
      test_created(req)
    },
    client => ignore(client.mknod("device", CharacterDevice(8U, 17U))),
  )
}

///|
async test "raw filenames preserve arbitrary bytes in guarded CREATE" {
  with_fake(
    1,
    req => {
      assert_eq(req.procedure, 8U)
      let r = @xdr.Reader::new(req.arguments)
      ignore(get_handle(r))
      assert_eq(Bytes::from_array(r.read_opaque()), b"\xff\xfe")
      assert_eq(r.read_uint(), 1U)
      test_created(req)
    },
    client => ignore(client.create_entry(client.root_handle(), b"\xff\xfe")),
  )
}

///|
test "portable local paths reject device aliases and traversal" {
  for
    name in [
      "NUL.txt", "con", "COM1.bin", "..", "a/b", "a\\b", "x:", "end.", "a?b",
    ] {
    try local_component(name) catch {
      InvalidArgument(_) => ()
      error => raise error
    } noraise {
      _ => fail("unsafe local name accepted")
    }
  }
  local_component("数据 file.bin")
  assert_eq(relative_path("root", "root/a/file"), "a/file")
  try relative_path("root/a", "root/ab/file") catch {
    InvalidArgument(_) => ()
    error => raise error
  } noraise {
    _ => fail("textual prefix escaped subtree")
  }
  assert_eq(permission_string(1U, 2541U), "-rwsr-xr-x")
}

///|
async test "exact range reads accumulate short replies and reject early EOF" {
  let mut calls = 0
  with_fake(
    3,
    req => {
      calls += 1
      read_reply(req, 1U, calls == 3, b"a")
    },
    client => {
      assert_eq(
        client.read_exactly_at(client.root_handle(), 4294967296UL, 3),
        b"aaa",
      )
    },
  )
  with_fake(1, req => read_reply(req, 1U, true, b"a"), client => {
    try client.read_exactly_at(client.root_handle(), 0UL, 3) catch {
      ProtocolError(_) => ()
      error => raise error
    } noraise {
      _ => fail("early EOF accepted")
    }
  })
}

///|
async test "range copying overlapping handles uses memmove order across short blocks" {
  for (from, to) in [(0UL, 2UL), (2UL, 0UL)] {
    let data = b"abcdefghij".to_array()
    let mut calls = 0
    with_fake(
      10,
      req => {
        calls += 1
        let r = @xdr.Reader::new(req.arguments)
        ignore(get_handle(r))
        if req.procedure == 1U {
          let w = @xdr.Writer::new()
          w.write_uint(0U)
          test_attributes(w, 1U, 1UL, 10UL)
          ok_reply(req, w)
        } else {
          let offset = r.read_uhyper().to_int()
          let count = r.read_uint().reinterpret_as_int()
          if req.procedure == 6U {
            read_reply(
              req,
              count.reinterpret_as_uint(),
              offset + count == data.length(),
              Bytes::from_array(data[offset:offset + count].to_owned()),
            )
          } else {
            assert_eq(req.procedure, 7U)
            assert_eq(r.read_uint(), 2U)
            let bytes = r.read_opaque()
            for i in 0..<count {
              data[offset + i] = bytes[i]
            }
            write_reply(req, count.reinterpret_as_uint(), 2U, b"12345678")
          }
        }
      },
      client => {
        client.read_size = 2
        client.write_size = 2
        assert_eq(
          client.copy_range(
            client.root_handle(),
            { bytes: b"hardlink", },
            from,
            to,
            8UL,
          ),
          8UL,
        )
      },
    )
    assert_eq(
      Bytes::from_array(data),
      if from == 0UL {
        b"ababcdefgh"
      } else {
        b"cdefghijij"
      },
    )
    assert_eq(calls, 10)
  }
}

///|
async test "tree walker yields a regular export root without directory RPCs" {
  with_fake(
    1,
    req => {
      let w = @xdr.Writer::new()
      w.write_uint(0U)
      test_attributes(w, 1U, 1UL, 0UL)
      ok_reply(req, w)
    },
    client => {
      let walker = client.walk("/", max_nodes=1)
      assert_true(walker.next() is Some(_))
      assert_true(walker.next() is None)
      walker.close()
    },
  )
}

///|
async test "tree node budget closes the walker before yielding an extra entry" {
  with_fake(
    2,
    req => {
      let w = @xdr.Writer::new()
      w.write_uint(0U)
      if req.procedure == 1U {
        test_attributes(w, 2U, 1UL, 0UL)
      } else {
        assert_eq(req.procedure, 17U)
        w.write_bool(false)
        w.write_fixed(b"12345678".to_array())
        w.write_bool(true)
        w.write_uhyper(2UL)
        w.write_opaque(b"child".to_array())
        w.write_uhyper(1UL)
        w.write_bool(true)
        test_attributes(w, 1U, 2UL, 0UL)
        w.write_bool(true)
        put_handle(w, { bytes: b"child", })
        w.write_bool(false)
        w.write_bool(true)
      }
      ok_reply(req, w)
    },
    client => {
      let walker = client.walk("/", max_nodes=1)
      assert_true(walker.next() is Some(_))
      try walker.next() catch {
        ProtocolError(_) => ()
        error => raise error
      } noraise {
        _ => fail("node budget was ignored")
      }
      assert_true(walker.next() is None)
    },
  )
}

///|
async test "RPC statistics distinguish lost replies from completed replies" {
  with_fake(1, _ => None, client => {
    let before = client.statistics()
    try client.ping() catch {
      _ => ()
    } noraise {
      _ => fail("reply unexpectedly received")
    }
    let delta = client.statistics().since(before)
    assert_eq(delta.calls, 1UL)
    assert_eq(delta.replies, 0UL)
    assert_eq(delta.failures, 1UL)
    assert_true(delta.request_bytes > 0UL)
  })
}

///|
async test "malformed successful NFS mutation body reports unknown outcome" {
  with_fake(
    1,
    req => {
      let w = @xdr.Writer::new()
      w.write_uint(0U) // Server reports success, but omits mandatory WCC data.
      ok_reply(req, w)
    },
    client => {
      try
        client.set_attributes(client.root_handle(), AttributeUpdate::default())
      catch {
        OutcomeUnknown(_) => ()
        error => raise error
      } noraise {
        _ => fail("malformed mutation body accepted")
      }
      try client.ping() catch {
        RpcFailure(_) => ()
        error => raise error
      } noraise {
        _ => fail("connection was not invalidated")
      }
    },
  )
}

///|
test "server time updates encode discriminants without client timestamp payloads" {
  let w = @xdr.Writer::new()
  put_attribute_update(w, {
    ..AttributeUpdate::default(),
    accessed: ServerTime,
    modified: ServerTime,
  })
  let r = @xdr.Reader::new(w.bytes())
  for _ in 0..<4 {
    assert_false(r.read_bool())
  }
  assert_eq(r.read_uint(), 1U)
  assert_eq(r.read_uint(), 1U)
  r.finish()
}

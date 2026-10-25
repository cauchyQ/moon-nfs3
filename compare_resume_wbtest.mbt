///|
async test "comparison retains unread tails across asymmetric short reads" {
  let mut reads = 0
  let mut left_bytes = 0
  let mut right_bytes = 0
  with_fake(
    5,
    req => {
      assert_eq(req.procedure, 6U)
      reads += 1
      let r = @xdr.Reader::new(req.arguments)
      let handle = get_handle(r)
      let offset = r.read_uhyper().to_int()
      let requested = r.read_uint().reinterpret_as_int()
      r.finish()
      let count = if handle.bytes == b"left" { 4 - offset } else { 1 }
      assert_true(count <= requested)
      if handle.bytes == b"left" {
        left_bytes += count
      } else {
        right_bytes += count
      }
      read_reply(
        req,
        count.reinterpret_as_uint(),
        offset + count == 4,
        b"abcd"[offset:offset + count].to_owned(),
      )
    },
    client => {
      client.read_size = 4
      let result = client.compare_handles({ bytes: b"left", }, client, {
        bytes: b"right",
      })
      assert_true(result.equal)
      assert_eq(result.compared_bytes, 4UL)
    },
  )
  assert_eq(reads, 5)
  assert_eq(left_bytes, 4)
  assert_eq(right_bytes, 4)
}

///|
async test "comparison locates a mismatch inside a retained read tail" {
  with_fake(
    4,
    req => {
      let r = @xdr.Reader::new(req.arguments)
      let handle = get_handle(r)
      let offset = r.read_uhyper().to_int()
      let data = if handle.bytes == b"left" { b"abcd" } else { b"abXd" }
      let count = if handle.bytes == b"left" { 4 } else { 1 }
      read_reply(
        req,
        count.reinterpret_as_uint(),
        offset + count == 4,
        data[offset:offset + count].to_owned(),
      )
    },
    client => {
      client.read_size = 4
      let result = client.compare_handles({ bytes: b"left", }, client, {
        bytes: b"right",
      })
      assert_false(result.equal)
      assert_true(result.first_difference is Some(2UL))
      assert_eq(result.compared_bytes, 3UL)
    },
  )
}

///|
async test "prefix verification stops at the exact bound without an EOF probe" {
  with_fake(
    2,
    req => {
      let r = @xdr.Reader::new(req.arguments)
      ignore(get_handle(r))
      assert_eq(r.read_uhyper(), 0UL)
      assert_eq(r.read_uint(), 3U)
      read_reply(req, 3U, false, b"abc")
    },
    client => {
      client.verify_remote_prefix(
        client,
        { bytes: b"left", },
        { bytes: b"right", },
        3UL,
      )
    },
  )
}

///|
async test "two equal early EOF replies cannot validate a longer resume prefix" {
  with_fake(2, req => read_reply(req, 2U, true, b"ab"), client => {
    try
      client.verify_remote_prefix(
        client,
        { bytes: b"left", },
        { bytes: b"right", },
        3UL,
      )
    catch {
      ProtocolError(_) => ()
      error => raise error
    } noraise {
      _ => fail("truncated prefix was accepted")
    }
  })
}

///|
async fn with_resume_file(
  data : Bytes,
  action : async (String) -> Unit,
) -> Unit {
  let directory = @fs.tmpdir(prefix="moonnfs3-resume-")
  defer @fs.rmdir(directory)
  let path = directory + "/data"
  @fs.write_file(path, data, create_mode=CreateNew)
  defer @fs.remove(path)
  action(path)
}

///|
async test "resume upload uses the upload budget when READ maximum is tiny" {
  with_resume_file(b"abcdef", path => {
    let mut writes = 0
    with_fake(
      5,
      req => {
        match req.procedure {
          3U => metadata_reply(req, true, 1U, 0UL)
          1U =>
            metadata_reply(req, true, 1U, if writes == 0 { 0UL } else { 6UL })
          7U => {
            let r = @xdr.Reader::new(req.arguments)
            ignore(get_handle(r))
            assert_eq(r.read_uhyper(), 0UL)
            assert_eq(r.read_uint(), 6U)
            assert_eq(r.read_uint(), 2U)
            assert_eq(Bytes::from_array(r.read_opaque()), b"abcdef")
            r.finish()
            writes += 1
            write_reply(req, 6U, 2U, b"12345678")
          }
          _ => fail("unexpected RPC during resumed upload")
        }
      },
      client => {
        client.read_size = 1
        client.write_size = 6
        assert_eq(client.resume_upload(path, "remote"), 6UL)
      },
    )
    assert_eq(writes, 1)
  })
}

///|
async test "resume upload refuses a destination modified during prefix verification" {
  with_resume_file(b"abc", path => {
    let mut attributes = 0
    with_fake(
      4,
      req => {
        match req.procedure {
          3U => metadata_reply(req, true, 1U, 1UL)
          1U => {
            attributes += 1
            let w = @xdr.Writer::new()
            w.write_uint(0U)
            test_attributes(
              w,
              1U,
              17UL,
              1UL,
              modified_seconds=attributes.reinterpret_as_uint(),
            )
            ok_reply(req, w)
          }
          6U => read_reply(req, 1U, true, b"a")
          _ => fail("destination was written after a version change")
        }
      },
      client => {
        try client.resume_upload(path, "remote") catch {
          ProtocolError(_) => ()
          error => raise error
        } noraise {
          _ => fail("changed destination accepted")
        }
      },
    )
    assert_eq(attributes, 2)
  })
}

///|
async test "resume download preserves its local prefix when remote version changes" {
  with_resume_file(b"ab", path => {
    let mut attributes = 0
    with_fake(
      4,
      req => {
        match req.procedure {
          3U => metadata_reply(req, true, 1U, 4UL)
          1U => {
            attributes += 1
            let w = @xdr.Writer::new()
            w.write_uint(0U)
            test_attributes(
              w,
              1U,
              17UL,
              4UL,
              modified_seconds=attributes.reinterpret_as_uint(),
            )
            ok_reply(req, w)
          }
          6U => read_reply(req, 2U, false, b"ab")
          _ => fail("unexpected RPC during changed download")
        }
      },
      client => {
        try client.resume_download("remote", path) catch {
          ProtocolError(_) => ()
          error => raise error
        } noraise {
          _ => fail("changed remote source accepted")
        }
      },
    )
    assert_eq(@fs.read_file(path).binary(), b"ab")
    assert_eq(attributes, 2)
  })
}

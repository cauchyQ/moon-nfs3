///|
pub struct Rpc {
  priv tcp : @socket.Tcp
  priv options : Options
  priv credential : @xdr.OpaqueAuth
  priv mut xid : UInt
  priv mut busy : Bool
  priv mut closed : Bool
}

///|
pub async fn Rpc::connect(
  host : String,
  port : Int,
  options? : Options = Options::default(),
) -> Rpc {
  options.validate()
  if port <= 0 || port > 65535 {
    raise InvalidArgument("invalid TCP port")
  }
  let credential = @xdr.AuthSys::{
    stamp: 0U,
    machine: "moonnfs3",
    uid: options.uid,
    gid: options.gid,
    groups: options.groups.copy(),
  }.to_auth()
  let tcp = @async.with_timeout(options.timeout_ms, () => {
    @socket.Tcp::connect_to_host(host, port~)
  })
  { tcp, options, credential, xid: 0U, busy: false, closed: false, }
}

///|
pub fn Rpc::close(self : Rpc) -> Unit {
  self.closed = true
  self.tcp.close()
}

///|
pub async fn Rpc::call(
  self : Rpc,
  program : UInt,
  version : UInt,
  procedure : UInt,
  arguments : Array[Byte],
  modifying? : Bool = false,
) -> @xdr.Reader {
  if self.closed {
    raise RpcFailure("connection closed")
  }
  if self.busy {
    raise InvalidArgument("concurrent calls require separate connections")
  }
  // Encode before touching the socket, so local validation cannot poison a session.
  let xid = self.xid + 1U
  let payload = @xdr.encode_call(
    {
      xid,
      program,
      version,
      procedure,
      credential: self.credential,
      verifier: @xdr.OpaqueAuth::none(),
      arguments,
    },
    limits=limits(self.options),
  )
  let framed = Bytes::from_array(
    @xdr.fragment_record(payload, 65536, limits=limits(self.options)),
  )
  self.busy = true
  defer {
    self.busy = false
  }
  errdefer self.close()
  self.xid = xid
  let reply_bytes = @async.with_timeout(self.options.timeout_ms, () => {
    self.tcp.write(framed)
    let decoder = @xdr.RecordDecoder::new(limits=limits(self.options))
    // Read a bounded prefix/body at a time; do not consume a future RPC response.
    while true {
      let marker = self.tcp.read_exactly(4)
      let mr = @xdr.Reader::new(marker.to_array())
      let word = mr.read_uint()
      let size = word & 0x7fffffffU
      if size > self.options.max_record.reinterpret_as_uint() {
        raise ProtocolError("RPC fragment exceeds budget")
      }
      let headers = decoder.feed(marker.to_array())
      if headers.length() == 1 {
        return headers[0]
      }
      let bodies = decoder.feed(
        self.tcp.read_exactly(size.reinterpret_as_int()).to_array(),
      )
      if bodies.length() == 1 {
        return bodies[0]
      }
    } nobreak {
      raise ProtocolError("incomplete RPC record")
    }
  }) catch {
    error => raise transport_error(error, modifying)
  }
  let response = @xdr.decode_reply(reply_bytes, limits=limits(self.options))
  if response.xid != xid {
    raise ProtocolError("RPC response XID mismatch")
  }
  match response.body {
    Accepted(auth, Success(bytes)) => {
      if auth.flavor != 0U || auth.body.length() != 0 {
        raise ProtocolError("unexpected RPC reply verifier")
      }
      @xdr.Reader::new(bytes, limits=limits(self.options))
    }
    _ =>
      raise RpcFailure(
        "RPC rejected program, procedure, arguments or credentials",
      )
  }
}

///|
fn transport_error(error : Error, modifying : Bool) -> Error {
  if modifying {
    OutcomeUnknown("mutation RPC transport failed: \{error}")
  } else {
    error
  }
}

///|
async test "TCP RPC reassembles fragmented replies and matches xid" {
  let server = @socket.TcpServer(@socket.Addr::parse("127.0.0.1:0"))
  defer server.close()
  @async.with_timeout(5000, () => {
    @async.with_task_group() <| group => {
      group.spawn_bg() <| () => {
        let (tcp, _) = server.accept()
        defer tcp.close()
        let marker = @xdr.Reader::new(tcp.read_exactly(4).to_array())
        let count = (marker.read_uint() & 0x7fffffffU).reinterpret_as_int()
        let request = @xdr.decode_call(tcp.read_exactly(count).to_array())
        assert_eq(request.program, 100003U)
        let reply = @xdr.encode_reply({
          xid: request.xid,
          body: Accepted(@xdr.OpaqueAuth::none(), Success([0, 0, 0, 0])),
        })
        tcp.write(Bytes::from_array(@xdr.fragment_record(reply, 3)))
      }
      let rpc = Rpc::connect("127.0.0.1", server.addr.port())
      defer rpc.close()
      let r = rpc.call(100003U, 3U, 0U, [])
      assert_eq(r.read_uint(), 0U)
      r.finish()
    }
  })
}

///|
pub(all) struct Timestamp {
  seconds : UInt
  nanoseconds : UInt
}

///|
pub fn Timestamp::validate(self : Timestamp) -> Unit raise NfsError {
  if self.nanoseconds >= 1000000000U {
    raise InvalidArgument("nanoseconds must be below one billion")
  }
}

///|
fn read_timestamp(r : @xdr.Reader) -> Timestamp raise {
  let seconds = r.read_uint()
  let nanoseconds = r.read_uint()
  if nanoseconds >= 1000000000U {
    raise ProtocolError("invalid timestamp nanoseconds")
  }
  { seconds, nanoseconds, }
}

///|
fn put_timestamp(w : @xdr.Writer, value : Timestamp) -> Unit raise {
  value.validate()
  w.write_uint(value.seconds)
  w.write_uint(value.nanoseconds)
}

///|
pub(all) struct Metadata {
  attributes : Attributes
  device_major : UInt
  device_minor : UInt
  accessed : Timestamp
  modified : Timestamp
  changed : Timestamp
}

///|
pub(all) enum TimeUpdate {
  KeepTime
  ServerTime
  ExactTime(Timestamp)
}

///|
pub(all) struct AttributeUpdate {
  mode : UInt?
  uid : UInt?
  gid : UInt?
  size : UInt64?
  accessed : TimeUpdate
  modified : TimeUpdate
}

///|
pub fn AttributeUpdate::default() -> AttributeUpdate {
  {
    mode: None,
    uid: None,
    gid: None,
    size: None,
    accessed: KeepTime,
    modified: KeepTime,
  }
}

///|
pub fn AttributeUpdate::validate(self : AttributeUpdate) -> Unit raise {
  if self.mode is Some(mode) && mode > 4095U {
    raise InvalidArgument("invalid Unix mode")
  }
  if self.accessed is ExactTime(time) {
    time.validate()
  }
  if self.modified is ExactTime(time) {
    time.validate()
  }
}

///|
fn put_optional_uint(w : @xdr.Writer, value : UInt?) -> Unit raise {
  w.write_bool(value is Some(_))
  if value is Some(number) {
    w.write_uint(number)
  }
}

///|
fn put_time_update(w : @xdr.Writer, value : TimeUpdate) -> Unit raise {
  match value {
    KeepTime => w.write_uint(0U)
    ServerTime => w.write_uint(1U)
    ExactTime(time) => {
      w.write_uint(2U)
      put_timestamp(w, time)
    }
  }
}

///|
fn put_attribute_update(w : @xdr.Writer, value : AttributeUpdate) -> Unit raise {
  value.validate()
  put_optional_uint(w, value.mode)
  put_optional_uint(w, value.uid)
  put_optional_uint(w, value.gid)
  w.write_bool(value.size is Some(_))
  if value.size is Some(size) {
    w.write_uhyper(size)
  }
  put_time_update(w, value.accessed)
  put_time_update(w, value.modified)
}

///|
pub async fn Client::metadata(self : Client, handle : Handle) -> Metadata {
  let w = @xdr.Writer::new()
  put_handle(w, handle)
  let r = self.invoke(1U, w)
  let result = read_metadata(r)
  r.finish()
  result
}

///|
pub async fn Client::set_attributes(
  self : Client,
  handle : Handle,
  update : AttributeUpdate,
  ctime_guard? : Timestamp? = None,
) -> Unit {
  let w = @xdr.Writer::new()
  put_handle(w, handle)
  put_attribute_update(w, update)
  w.write_bool(ctime_guard is Some(_))
  if ctime_guard is Some(time) {
    put_timestamp(w, time)
  }
  let r = self.invoke(2U, w, modifying=true)
  self.decode_mutation(r, reader => {
    read_wcc(reader)
    reader.finish()
  })
}

///|
pub async fn Client::chmod(self : Client, path : String, mode : UInt) -> Unit {
  let update = AttributeUpdate::{
    ..AttributeUpdate::default(),
    mode: Some(mode),
  }
  update.validate()
  self.set_attributes(self.resolve(path), update)
}

///|
pub async fn Client::chown(
  self : Client,
  path : String,
  uid : UInt?,
  gid : UInt?,
) -> Unit {
  self.set_attributes(self.resolve(path), {
    ..AttributeUpdate::default(),
    uid,
    gid,
  })
}

///|
pub async fn Client::truncate(
  self : Client,
  path : String,
  size : UInt64,
) -> Unit {
  self.set_attributes(self.resolve(path), {
    ..AttributeUpdate::default(),
    size: Some(size),
  })
}

///|
pub async fn Client::touch(self : Client, path : String) -> Unit {
  self.set_attributes(self.resolve(path), {
    ..AttributeUpdate::default(),
    accessed: ServerTime,
    modified: ServerTime,
  })
}

///|
pub fn file_kind_name(kind : UInt) -> String {
  match kind {
    1U => "file"
    2U => "directory"
    3U => "block-device"
    4U => "character-device"
    5U => "symlink"
    6U => "socket"
    7U => "fifo"
    _ => "unknown"
  }
}

///|
pub fn permission_string(kind : UInt, mode : UInt) -> String {
  let prefix = match kind {
    1U => "-"
    2U => "d"
    3U => "b"
    4U => "c"
    5U => "l"
    6U => "s"
    7U => "p"
    _ => "?"
  }
  let parts = [prefix]
  for shift in [6, 3, 0] {
    parts.push(if (mode & (4U << shift)) != 0U { "r" } else { "-" })
    parts.push(if (mode & (2U << shift)) != 0U { "w" } else { "-" })
    let execute = (mode & (1U << shift)) != 0U
    let special = mode &
      (if shift == 6 { 2048U } else if shift == 3 { 1024U } else { 512U })
    parts.push(
      if special != 0U {
        if shift == 0 {
          if execute {
            "t"
          } else {
            "T"
          }
        } else if execute {
          "s"
        } else {
          "S"
        }
      } else if execute {
        "x"
      } else {
        "-"
      },
    )
  }
  parts.join("")
}

///|
pub fn status_name(code : UInt) -> String {
  match code {
    0U => "OK"
    1U => "PERM"
    2U => "NOENT"
    5U => "IO"
    6U => "NXIO"
    13U => "ACCES"
    17U => "EXIST"
    18U => "XDEV"
    19U => "NODEV"
    20U => "NOTDIR"
    21U => "ISDIR"
    22U => "INVAL"
    27U => "FBIG"
    28U => "NOSPC"
    30U => "ROFS"
    31U => "MLINK"
    63U => "NAMETOOLONG"
    66U => "NOTEMPTY"
    69U => "DQUOT"
    70U => "STALE"
    71U => "REMOTE"
    10001U => "BADHANDLE"
    10002U => "NOT_SYNC"
    10003U => "BAD_COOKIE"
    10004U => "NOTSUPP"
    10005U => "TOOSMALL"
    10006U => "SERVERFAULT"
    10007U => "BADTYPE"
    10008U => "JUKEBOX"
    _ => "UNKNOWN"
  }
}

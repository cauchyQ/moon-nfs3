///|
pub async fn Client::symlink(
  self : Client,
  path : String,
  target : Bytes,
  mode? : UInt = 511U,
) -> Handle {
  if target.length() == 0 ||
    target.length() > 1024 ||
    target.to_array().contains(0) {
    raise InvalidArgument("invalid symbolic link target")
  }
  let update = AttributeUpdate::{
    ..AttributeUpdate::default(),
    mode: Some(mode),
  }
  update.validate()
  let (parent, name) = self.parent(path)
  let w = @xdr.Writer::new()
  put_handle(w, parent)
  put_name(w, name)
  put_attribute_update(w, update)
  w.write_opaque(target.to_array(), bound=1024U)
  self.created_handle(parent, @utf8.encode(name), 10U, w)
}

///|
async fn Client::created_handle(
  self : Client,
  parent : Handle,
  name : Bytes,
  procedure : UInt,
  w : @xdr.Writer,
) -> Handle {
  let r = self.invoke(procedure, w, modifying=true)
  let handle = self.decode_mutation(r, reader => {
    let handle = if reader.read_bool() {
      Some(get_handle(reader))
    } else {
      None
    }
    ignore(post_attributes(reader))
    read_wcc(reader)
    reader.finish()
    handle
  })
  match handle {
    Some(value) => value
    None => self.lookup_bytes(parent, name)
  }
}

///|
pub async fn Client::hard_link(
  self : Client,
  source : String,
  destination : String,
) -> Unit {
  let handle = self.resolve(source)
  let (parent, name) = self.parent(destination)
  let w = @xdr.Writer::new()
  put_handle(w, handle)
  put_handle(w, parent)
  put_name(w, name)
  let r = self.invoke(15U, w, modifying=true)
  self.decode_mutation(r, reader => {
    ignore(post_attributes(reader))
    read_wcc(reader)
    reader.finish()
  })
}

///|
pub(all) enum SpecialNode {
  BlockDevice(UInt, UInt)
  CharacterDevice(UInt, UInt)
  UnixSocket
  NamedPipe
}

///|
pub async fn Client::mknod(
  self : Client,
  path : String,
  kind : SpecialNode,
  mode? : UInt = 384U,
) -> Handle {
  let update = AttributeUpdate::{
    ..AttributeUpdate::default(),
    mode: Some(mode),
  }
  update.validate()
  let (parent, name) = self.parent(path)
  let w = @xdr.Writer::new()
  put_handle(w, parent)
  put_name(w, name)
  w.write_uint(
    match kind {
      BlockDevice(_, _) => 3U
      CharacterDevice(_, _) => 4U
      UnixSocket => 6U
      NamedPipe => 7U
    },
  )
  put_attribute_update(w, update)
  match kind {
    BlockDevice(major, minor) | CharacterDevice(major, minor) => {
      w.write_uint(major)
      w.write_uint(minor)
    }
    UnixSocket | NamedPipe => ()
  }
  self.created_handle(parent, @utf8.encode(name), 11U, w)
}

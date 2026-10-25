///|
fn cli_options(small : Bool) -> @nfs.Options raise {
  let options = @nfs.Options::{
    ..@nfs.Options::default(),
    uid: env_uid("NFS_UID", 65534U),
    gid: env_uid("NFS_GID", 65534U),
    timeout_ms: env_number("NFS_TIMEOUT_MS", 10000),
    max_entries: env_number("NFS_MAX_ENTRIES", 100000),
    block_size: env_number("NFS_BLOCK_SIZE", if small { 4096 } else { 65536 }),
    max_record: env_number("NFS_MAX_RECORD", if small { 8192 } else { 1048576 }),
  }
  options.validate()
  options
}

///|
async fn connect_destination(
  host : String,
  export_path : String,
) -> @nfs.Client {
  let defaults = cli_options(false)
  let options = @nfs.Options::{
    ..defaults,
    uid: env_uid("NFS_DEST_UID", defaults.uid),
    gid: env_uid("NFS_DEST_GID", defaults.gid),
  }
  @nfs.connect_export(
    host,
    export_path,
    mount_port=env_number(
      "NFS_DEST_MOUNT_PORT",
      env_number("NFS_MOUNT_PORT", 0),
    ),
    nfs_port=env_number("NFS_DEST_PORT", env_number("NFS_PORT", 0)),
    options~,
  )
}

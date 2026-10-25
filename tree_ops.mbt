///|
pub(all) struct TreeTransfer {
  files : Int
  directories : Int
  symlinks : Int
  bytes : UInt64
}

///|
fn require_copy_kinds(entries : Array[TreeEntry]) -> Unit raise NfsError {
  for entry in entries {
    if entry.attributes.kind != 1U &&
      entry.attributes.kind != 2U &&
      entry.attributes.kind != 5U {
      raise InvalidArgument(
        "tree copy does not copy special devices or sockets",
      )
    }
  }
}

///|
fn require_disjoint_destination(
  source : String,
  destination : String,
) -> Unit raise {
  let source = normalize_path(source)
  let destination = normalize_path(destination)
  if source == "/" ||
    destination == source ||
    destination.has_prefix(source + "/") {
    raise InvalidArgument("copy destination must be outside source subtree")
  }
  if destination == "/" {
    raise InvalidArgument("cannot replace export root")
  }
}

///|
pub async fn Client::copy_tree(
  self : Client,
  source : String,
  destination : String,
  preserve_mode? : Bool = true,
) -> TreeTransfer {
  require_disjoint_destination(source, destination)
  self.copy_tree_to(self, source, destination, preserve_mode~)
}

///|
/// Collects and validates the traversal before the first deletion. Never follows links.
pub async fn Client::remove_tree(self : Client, path : String) -> Int {
  if path_components(path).length() == 0 {
    raise InvalidArgument("cannot remove export root")
  }
  let entries = self.collect_tree(path)
  let mut removed = 0
  for i = entries.length() - 1; i >= 0; i = i - 1 {
    let entry = entries[i]
    let current = self.stat(entry.path)
    if current.fsid != entry.attributes.fsid ||
      current.fileid != entry.attributes.fileid ||
      current.kind != entry.attributes.kind {
      raise ProtocolError("tree entry was replaced before removal")
    }
    self.remove(entry.path, directory=entry.attributes.kind == 2U)
    removed += 1
  }
  removed
}

///|
pub(all) enum TreeDifferenceKind {
  MissingLeft
  MissingRight
  DifferentType
  DifferentSize
  DifferentContent
  DifferentMode
  DifferentLinkTarget
}

///|
pub(all) struct TreeDifference {
  relative : String
  kind : TreeDifferenceKind
}

///|
pub async fn Client::compare_trees(
  self : Client,
  left : String,
  right : String,
  compare_mode? : Bool = false,
) -> Array[TreeDifference] {
  let first = self.collect_tree(left)
  let second = self.collect_tree(right)
  let by_path : Map[String, TreeEntry] = Map([])
  let visited : Map[String, Bool] = Map([])
  let result : Array[TreeDifference] = []
  for entry in second {
    by_path[entry.relative] = entry
  }
  for entry in first {
    visited[entry.relative] = true
    match by_path.get(entry.relative) {
      None => result.push({ relative: entry.relative, kind: MissingRight, })
      Some(other) => {
        let relative = entry.relative
        let a = entry.attributes
        let b = other.attributes
        if a.kind != b.kind {
          result.push({ relative, kind: DifferentType, })
          continue
        }
        if compare_mode && (a.mode & 4095U) != (b.mode & 4095U) {
          result.push({ relative, kind: DifferentMode, })
        }
        match a.kind {
          1U =>
            if a.size != b.size {
              result.push({ relative, kind: DifferentSize, })
            } else if !self.compare_files(entry.path, other.path).equal {
              result.push({ relative, kind: DifferentContent, })
            }
          5U =>
            if self.readlink(entry.handle) != self.readlink(other.handle) {
              result.push({ relative, kind: DifferentLinkTarget, })
            }
          2U => ()
          _ =>
            raise InvalidArgument("comparison of special nodes is unsupported")
        }
      }
    }
  }
  for entry in second {
    if !visited.contains(entry.relative) {
      result.push({ relative: entry.relative, kind: MissingLeft, })
    }
  }
  result
}

///|
pub fn TreeDifferenceKind::name(self : TreeDifferenceKind) -> String {
  match self {
    MissingLeft => "missing-left"
    MissingRight => "missing-right"
    DifferentType => "type"
    DifferentSize => "size"
    DifferentContent => "content"
    DifferentMode => "mode"
    DifferentLinkTarget => "link-target"
  }
}

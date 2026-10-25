///|
pub(all) struct LocalTreeComparison {
  differences : Array[TreeDifference]
  compared_bytes : UInt64
}

///|
/// Verifies directory round trips by reading each regular file's content.
pub async fn Client::verify_local_tree(
  self : Client,
  local_path : String,
  remote_path : String,
) -> LocalTreeComparison {
  let first = collect_local_tree(local_path, self.options.max_entries, 128)
  let second = self.collect_tree(
    remote_path,
    max_nodes=self.options.max_entries,
  )
  let by_path : Map[String, LocalEntry] = Map([])
  let visited : Map[String, Bool] = Map([])
  let differences : Array[TreeDifference] = []
  let mut compared_bytes = 0UL
  for entry in first {
    by_path[entry.relative] = entry
  }
  for entry in second {
    let relative = entry.relative
    visited[relative] = true
    match by_path.get(relative) {
      None => differences.push({ relative, kind: MissingLeft, })
      Some(counterpart) => {
        let expected = if counterpart.directory { 2U } else { 1U }
        if entry.attributes.kind != expected {
          differences.push({ relative, kind: DifferentType, })
        } else if !counterpart.directory {
          let result = self.verify_local_file(counterpart.path, entry.path)
          compared_bytes = checked_sum(compared_bytes, result.compared_bytes)
          if !result.equal {
            differences.push({ relative, kind: DifferentContent, })
          }
        }
      }
    }
  }
  for entry in first {
    if !visited.contains(entry.relative) {
      differences.push({ relative: entry.relative, kind: MissingRight, })
    }
  }
  { differences, compared_bytes, }
}

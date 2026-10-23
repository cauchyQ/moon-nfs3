// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "cauchyQ/moon-nfs3"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/cauchyQ/moon-nfs3"

license = "Apache-2.0"

keywords = [ "nfs", "rpc", "storage" ]

preferred_target = "wasm"

description = "NFSv3 over TCP file client for MoonBit"

import {
  "kekeshuo/moonxdr@0.2.0",
  "moonbitlang/async@0.22.1",
}

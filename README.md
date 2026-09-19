# TODO

- Support invoking `.cmd` directly from `exec`, including shell dispatch on Unix and Windows. Tests currently invoke the OS shell explicitly.
- Fix Windows `exec` path resolution to use the child's `cwd`: with a parent on `C:` and child on `D:`, redirected `\out.txt` must resolve to `D:\out.txt`. Check executable paths and `PATH` entries too, and add Windows regression tests.
- Test symlink metadata, dangling links, and recursive removal around links/cycles. Needs symlink creation in the native filesystem API, including Windows directory links/junctions.
- Test HTTP responses, methods/bodies, repeated headers, redirects, TLS rejection, and failed downloads preserving files. Needs a local HTTPS server helper, a test certificate with portable per-process trust configuration, and startup/shutdown coordination (initially via `io.popen`).
- Test fresh bootstrap downloads, SHA-256 rejection, and cache reuse. Needs a controlled download source for the launcher.
- Add a shared OS-appropriate tool cache: download, verify the pinned SHA-256, extract, and publish completed installs safely, including concurrent runs.
- Bootstrap our own build with `.cmd`: move `build` and `build.ps1` into Lua, preserving pinned dependencies and skipping unchanged builds, then remove the old scripts.
- Add reusable Lua recipes for downloading SDKs or checking installed versions, starting with our build tools and later Java. Support platform-specific URLs and hashes.
- Add an explicit launcher update command that updates the pinned version and hashes together.
- Embed API documentation and LuaLS annotations for the pinned version. Add `--setup-luals` to extract definitions and scope them to `.cmd.lua` with `---@type dotcmd.Env|_G` and `local _ENV = _ENV`. Initially create `.luarc.json` only when absent; otherwise show the required setting. Automatic updates to existing JSON/JSONC need formatting- and comment-preserving edits.
- Polish: colored outputs

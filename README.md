# TODO

- Support C functions as `fetch` preparation callbacks, including `prepare = extract`. Use the symbolic API name already supplied when registering each native function as its stable cache identity, so the same generic registration path automatically covers future native functions without a separate identity list.
- Fix Windows `exec` path resolution to use the child's `cwd`: with a parent on `C:` and child on `D:`, redirected `\out.txt` must resolve to `D:\out.txt`. Check executable paths and `PATH` entries too, and add Windows regression tests.
- Test symlink metadata, dangling links, and recursive removal around links/cycles. Needs symlink creation in the native filesystem API, including Windows directory links/junctions.
- Test fresh bootstrap downloads, SHA-256 rejection, and cache reuse. Needs a controlled download source for the launcher.
- Add reusable Lua plugins for downloading SDKs or checking installed versions, starting with our build tools and later Java. Support platform-specific URLs and hashes.
  Experimental streaming Lua parser for statically discovering plugin calls: [lua_recipe_parser.cpp](https://gist.github.com/vlaaad/59c7b500fec8b699da6b3880abe69e1c).
- Generate LuaLS definitions from installed plugins for the global `plugin(url, sha256)` function. Collect overloads with literal URLs and source SHA-256s in one definition file, using each plugin chunk's return type, so callers need no type annotation. Keep `@return any` before the overloads and leave the generic parameters unannotated: broad `@param url string`/`@param sha256 string` annotations suppress literal argument suggestions. This shape supports URL and SHA-256 completion and plugin-specific return-type narrowing. Example (replace hash placeholders with the installed plugins' actual hashes):

  ```lua
  ---@meta
  ---@return any
  ---@overload fun(url: "https://example.com/jdk.lua", sha256: "<jdk-source-sha256>"): JdkPlugin
  ---@overload fun(url: "https://example.com/clj.lua", sha256: "<clj-source-sha256>"): CljPlugin
  function plugin(url, sha256) end
  ```

  Include the plugins' `JdkPlugin`/`CljPlugin` type definitions alongside these overloads.
- Embed API documentation and LuaLS annotations for the pinned version. Add `--setup-luals` to extract definitions and scope them to `.cmd.lua` with `---@type dotcmd.Env|_G` and `local _ENV = _ENV`. Initially create `.luarc.json` only when absent; otherwise show the required setting. Automatic updates to existing JSON/JSONC need formatting- and comment-preserving edits.
- Polish: colored outputs
- json support?
- Implement persistent completion caching. Normal invocations atomically cache the result of loading `.cmd.lua`: either completion metadata or failure. `--complete` reuses an existing cached result. If none exists, it loads `.cmd.lua` once and caches the outcome. Successful results provide project completions; failed results provide built-ins only.

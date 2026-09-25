Plugins register commands through an injected, plugin-bound global `cli`. Their return values remain unrestricted.

```lua
cli(function(api)
    return {
        update = {
            description = "Update Ninja",
            args = {
                { "version", arity = "?", default = "latest" },
            },
            run = function(version)
                local config = api.get_config()
                config.version = resolve_version(version)
                config.sha256 = resolve_hashes(config.version)
                api.set_config(config)
            end,
        },
    }
end)
```

The factory API consists of:

- `get_config()`: returns fresh copies of the associated call’s literal arguments, preserving multiple values and nils.
- `set_config(...)`: stages replacement of the entire argument list. Zero arguments means an empty call; one nil means a call with one nil argument.

Both report an error if there is no associated call or its arguments aren’t statically readable. Availability depends on source syntax, not the plugin’s return type. Commands use the existing argument, help, completion, and exit-code conventions.

Internally, track two contexts:

| Context | Represents | Used for |
|---|---|---|
| Source | One `plugin(...)` declaration, its URL/hash and source location | Updating plugin code |
| Invocation | One recognized call to the returned value, its arguments and location; references a source context | Invoking commands and editing configuration |

```lua
local a = plugin("url", "hash")("1.12", nil)

local ninja = plugin("url", "hash")
local b = ninja { version = "1.13" }
local c = ninja { version = "1.14" }
```

Source updates and command invocation have different target sets:

```sh
# Source targets: a, ninja
./.cmd --plugin --update a
./.cmd --plugin --update ninja

# Command targets: a, b, c
./.cmd --plugin a update
./.cmd --plugin b update
./.cmd --plugin c update
```

`--plugin --update b` explains that `b` uses the source declared as `ninja`, whose update also affects `c`. Help and completion list the appropriate targets.

Each invocation gets its own factory context. A source without recognized invocations still exposes commands under its own name, with configuration access unavailable.

Repeated identical `plugin(...)` declarations remain separate source contexts and independently editable pins. Downloaded bytes may be shared; contexts are not merged.

Source updates use an optional plugin-defined `__update` hook receiving the current URL/hash and returning their replacement. Otherwise, dotcmd can provide an updater for recognized hosts/path patterns with a defined revision-following policy. There is no generic configuration command or automatic batching of arbitrary plugin commands.

Discovery and execution:

- Recognize literal source declarations in positional or options-table form, optionally followed by literal arguments of any supported type.
- Recognize calls through locals initialized directly by `plugin(...)`. Respect scope and shadowing; conservatively skip associating calls through reassigned locals. Don’t follow aliases or table fields.
- Discover declarations and invocations inside branches, functions, and loops without executing their surroundings. One syntactic occurrence remains one target regardless of execution count.
- Prefer local binding names, falling back to the plugin URL basename without `.lua`. Within each target set, collisions become `ninja:1`, `ninja:2`, in source order. Bare `ninja` then reports ambiguity.
- Load the selected pinned plugin directly, collect its registration, and ignore chunk returns. Invoke the factory with the API bound to the selected command context. Don’t execute the surrounding project code.
- Give nested plugins separate `cli` bindings; don’t automatically expose their commands through the parent.

After successful command completion, dotcmd validates staged replacements, checks for concurrent file changes, preserves surrounding text, syntax-checks the result, and writes atomically. `--dry-run` shows the proposed `.cmd.lua` diff without applying it; other command effects still happen.

Initial editing support targets project-owned declarations and invocations. Downloaded plugin sources remain immutable.
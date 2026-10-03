# .cmd

A cross-platform task runner you check in.

> If you use .cmd, please consider [sponsoring its development](https://github.com/sponsors/vlaaad).

# Why it exists

.cmd solves a problem of setting up dev dependencies and build scripts for cross-platform projects in a way that exposes the same command line interface on Linux, macOS and Windows. It is designed to be checked into the repo. A fresh checkout should be enough to build, test, and run a project. It simplifies both contributor onboarding and CI configuration: **with `.cmd`, there are no prerequisites**.

# What it is

.cmd is a small polyglot shell script that works on Linux, macOS and Windows, in shells such as zsh, bash, pwsh and cmd. It's purpose is to download a self-contained Lua executable that is then used as a cross-platform program downloader and launcher. It's small, performant and secure — built-in tools make it trivial to pin all dependencies using SHA-256 hashes.

# Installation

There is no system-wide installation step, getting `.cmd` into your repo is simply downloading a file.

Get it on Linux/macOS:

```sh
curl -fsSL https://github.com/dotcmdhq/dotcmd/releases/latest/download/dotcmd.cmd -o .cmd && chmod +x .cmd
```

Windows (PowerShell):

```pwsh
Invoke-WebRequest -UseBasicParsing https://github.com/dotcmdhq/dotcmd/releases/latest/download/dotcmd.cmd -OutFile .cmd
```

Windows (cmd.exe):
```bat
curl.exe -fsSL https://github.com/dotcmdhq/dotcmd/releases/latest/download/dotcmd.cmd -o .cmd
```

# Getting started

Once installed, run `./.cmd --init` to create `.cmd.lua` that configures the build. 

For human convenience, you may install shell completions with `./.cmd --setup completions` and Lua annotations for [Lua language server](https://github.com/LuaLS/lua-language-server) with `./.cmd --setup luals`.

For coding agents, `./.cmd` has all the necessary documentation built-in, just point the agent to `.cmd` and it will figure it out.

Here is a complete `.cmd.lua` example for a Go program:
```lua
return {
    build = {
        description = "Build hello.go",
        args = {},
        run = function()
            local version = "1.27.1"
            local go_os = { linux = "linux", macos = "darwin", windows = "windows" }
            local go_arch = { x64 = "amd64", arm64 = "arm64" }
            local hashes = { -- SHA-256 values from https://go.dev/dl/?mode=json
                linux = {
                    x64 = "63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445",
                    arm64 = "3450b45a3f9ee8568792736a5c5e70a1f2e9b36c35a8f74958c03e51d7d92bec"
                },
                macos = {
                    x64 = "8f8f52c6649542cf027bbc9b9c68d1ec042f9f34808a40413f0b8b3f66f3caa4",
                    arm64 = "ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12"
                },
                windows = {
                    x64 = "a3911b5e0e1b1053f25ed0675f4c1c6aad1e2bfcf253df2b9be4caabd2edd95d",
                    arm64 = "13b69b87bb0e83f96bc68560a8cace7f0343b1e03469f1110ea18d17e3234069"
                }
            }
            fs.mkdir("build")
            local suffix = host.os == "windows" and ".zip" or ".tar.gz"
            local filename = "go" .. version .. "." .. go_os[host.os] .. "-" .. go_arch[host.arch] .. suffix
            local root = fetch {
                url = "https://go.dev/dl/" .. filename,
                sha256 = hashes[host.os][host.arch],
                prepare = function(input, output)
                    extract { path = input, to = output, strip_components = 1 }
                end
            }
            exec {
                root .. "/bin/go" .. host.exe_suffix, "build", "-o", "build/hello" .. host.exe_suffix, "hello.go",
                env = { GOROOT = root, GOTOOLCHAIN = "local", CGO_ENABLED = "0" }
            }
        end
    },
    run = {
        description = "Build and run the greeting program",
        args = { { "name", arity = "*" } },
        run = function(...)
            task("build")
            exec { "./build/hello" .. host.exe_suffix, ... }
        end
    }
}
```

With this config, anyone with a local checkout of a repo can run `./.cmd run` and execute a go program, without needing to install anything. The very first invocation will download Go toolchain, while subsequent ones will use the cached version.

# Main concepts

## Tasks

`.cmd.lua` returns a table of named tasks. Running `./.cmd build` calls the `build` task's `run` function. Tasks can declare descriptions, positional arguments, and options; these definitions drive argument parsing, help, and shell completion.

## `fetch`

`fetch` turns a download URL and a pinned SHA-256 hash into a local path. It verifies new downloads and reuses cached files across invocations and projects. An optional `prepare(input, output)` function creates a prepared file or directory, e.g., by extracting an archive.

In the example, `fetch` supplies the Go toolchain for the current platform without a system-wide installation.

## `exec`

`exec` runs a program with the arguments supplied in a Lua table. It launches the program directly, so each argument is passed as written without shell quoting or expansion. Commands run from the project directory by default; `cwd` and `env` can customize the child's working directory and environment.

Output goes directly to the terminal by default, and a nonzero exit code fails the task. In the example, `exec` first runs the downloaded Go compiler, then runs the resulting program.

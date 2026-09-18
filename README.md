# dotcmd

[![Smoke test](https://github.com/vlaaad/dotcmd/actions/workflows/smoke.yml/badge.svg)](https://github.com/vlaaad/dotcmd/actions/workflows/smoke.yml)

A project-local command entry point, spelled `.cmd`.

This initial experiment tests whether one file can run as both a POSIX shell
script and a Windows batch script, including the unusual bare `.cmd` filename.
It prints the selected interpreter when called without arguments. Otherwise,
it forwards a command and its arguments and preserves the exit code.

```sh
# Linux / macOS
./.cmd
./.cmd java -version
```

```powershell
# Windows: PowerShell or CMD
.\.cmd
.\.cmd java -version
```

The command must already be installed. Downloading tools, pinning versions,
caching, and project configuration are future work.

## How it works

CMD treats the first line as a label. A POSIX shell executes that line and
exits or replaces itself with the requested command before reaching the batch
section. The file has LF line endings and its executable bit is tracked in Git.

There is no shebang: Unix invocation relies on the calling shell's fallback for
executable text files. Direct process APIs that require a shebang must use
`sh ./.cmd ...`. The leading dot also hides the file in ordinary Unix listings.

When calling from another batch file, use `call .\.cmd ...` if that batch file
needs to resume afterward.

## Smoke tests

GitHub Actions tests Linux (Bash and sh), macOS (Bash and zsh), and Windows
(PowerShell and CMD), with the checkout in a directory containing spaces.
The tests check interpreter selection, argument forwarding (including a quoted
argument containing a space), and a child exit code of 37. Python is only the
CI probe; it is not required by `.cmd` itself. These are basic smoke tests, not
a guarantee of arbitrary quoting or metacharacter handling across shells.

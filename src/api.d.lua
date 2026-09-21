---@meta

---@class dotcmd.Host
---@field os "linux"|"macos"|"windows"
---@field arch "x64"|"arm64"
---@field version string
---@field build "debug"|"release"
---@field lua_version string
---@field compiler string
---@field executable string Absolute executable path.
---@field cwd string Initial working directory.
---@field project_dir string Directory containing the launcher.
---@field cache_dir string Shared cache root; honors DOTCMD_CACHE_DIR.
---@field licenses string Bundled third-party license text.

---@class dotcmd.HttpOptions
---@field url string HTTPS URL.
---@field method? string Defaults to GET.
---@field headers? table<string, string|string[]> Arrays send repeated headers.
---@field body? string Binary-safe request body.
---@field path? string Output file, relative to cwd. Only a successful 2xx response replaces it.
---@field connect_timeout? integer Seconds; defaults to 30.
---@field timeout? integer Seconds; defaults to 0 (unlimited).
---@field check? boolean Raise on a final non-2xx response; defaults to false.

---@class dotcmd.HttpResponse
---@field url string Final URL after redirects.
---@field status integer
---@field headers table<string, string[]> Lowercase names; values always arrays.
---@field body string Binary-safe response body; absent when using path. Annotated as a string to avoid nil checks for in-memory responses.

---@class dotcmd.File
---@field path string

---@alias dotcmd.Output "inherit"|"capture"|"discard"|dotcmd.File
---@alias dotcmd.Input "inherit"|"discard"|dotcmd.File

---@class dotcmd.ExecOptions
---@field [integer] string Program at index 1, followed by arguments.
---@field cwd? string Child working directory; defaults to the caller's cwd.
---@field env? table<string, string|false> Overlay inherited variables; false removes one.
---@field stdin? dotcmd.Input Defaults to inherit. File paths are relative to the child's cwd.
---@field stdout? dotcmd.Output Defaults to inherit. File paths are relative to the child's cwd.
---@field stderr? dotcmd.Output|"stdout" Defaults to inherit; stdout merges into standard output.
---@field check? boolean Raise on a nonzero exit; defaults to false.

---@class dotcmd.ExecResult
---@field code integer Exit code.
---@field stdout string Present only when captured; annotated as a string to avoid nil checks at capture sites.
---@field stderr string Present only when captured; annotated as a string to avoid nil checks at capture sites.

---@class dotcmd.SpawnOptions
---@field [integer] string Program at index 1, followed by arguments.
---@field cwd? string Child working directory; defaults to the caller's cwd.
---@field env? table<string, string|false> Overlay inherited variables; false removes one.
---@field stdin? dotcmd.Input|"pipe" Defaults to inherit. File paths are relative to the child's cwd.
---@field stdout? dotcmd.Output|"pipe" Defaults to inherit. Output files are truncated.
---@field stderr? dotcmd.Output|"pipe"|"stdout" Defaults to inherit; stdout merges into standard output.

---@class dotcmd.Process
---@field stdin file* Present when stdin is piped. Writes block; close it to send EOF.
---@field stdout file* Present when stdout is piped. Reads block; callers must drain piped output.
---@field stderr file* Present when stderr is piped. Reads block; callers must drain piped output.
---@field wait fun(self: dotcmd.Process, options?: {check?: boolean}): dotcmd.ExecResult Wait for exit and captured output. check defaults to false; true raises on nonzero exit.
---@field poll fun(self: dotcmd.Process): dotcmd.ExecResult? Return the completed result, or nil while running or collecting output.
---@field kill fun(self: dotcmd.Process) Force-stop the direct child if running, without waiting.
---@field close fun(self: dotcmd.Process) Stop the direct child, wait, and close pipes. Also called by <close>; safe to repeat.

---@class dotcmd.Stat
---@field type "file"|"directory"|"symlink"|"other"
---@field size integer Bytes.
---@field mode integer Unix permission bits (0777 mask); 0 on Windows, where chmod is a no-op.

---@class dotcmd.Fs
---@field stat fun(path: string, options?: {follow?: boolean}): dotcmd.Stat? Missing paths return nil; follow defaults to true.
---@field realpath fun(path: string): string Absolute path with symlinks resolved; the path must exist. Raises on failure. Windows returns an extended-length path.
---@field list fun(path: string): fun(): string? Unsorted entry names for a generic for loop.
---@field mkdir fun(path: string) Creates parent directories too.
---@field remove fun(path: string, options?: {recursive?: boolean}) Ignores missing paths; never traverses symlinks.
---@field rename fun(from: string, to: string, options?: {if_exists?: dotcmd.IfExists}): boolean Atomic rename; if_exists defaults to error. Returns true on success, false when skipped; failures raise.
---@field chmod fun(path: string, mode: integer|"+x") Sets Unix permission bits (0 through 0777), or adds execute bits allowed by umask with "+x"; no-op on Windows.

---@class dotcmd.Extraction
---@field strip_components? integer Leading path components to remove; defaults to 0.
---@field include? string[] Exact archive paths or directory prefixes, matched before stripping.

---@alias dotcmd.IfExists "error"|"skip"|"replace"

---@class dotcmd.ExtractOptions: dotcmd.Extraction
---@field if_exists? dotcmd.IfExists Defaults to error. Replacement swaps trees on Unix; Windows moves the old tree aside before publication.
---@field path string Archive file; format detected by contents.
---@field to? string New destination directory; defaults to the archive path without its suffix.

---Creates output as a file or directory. Its parent exists; output does not.
---Input is the cached download and must not be modified. Return values are ignored.
---Output is temporary and will be moved after success; do not embed its path.
---Cache identity includes stripped Lua bytecode, not captured values or ambient state.
---@alias dotcmd.Prepare fun(input: string, output: string)

---@class dotcmd.CachedOptions
---@field url string HTTPS download URL.
---@field sha256 string Pinned download hash. Verified only when downloading; cache hits are trusted.
---@field name? string Download filename; defaults to the URL filename, or download.
---@field prepare? dotcmd.Prepare Run only on a prepared-cache miss. Must be a Lua function; errors discard partial output.

---@alias dotcmd.Run fun(...: string): integer?

---@alias dotcmd.Arity "1"|"?"|"+"|"*"
---@alias dotcmd.ArgType "string"|"number"|"integer"|"boolean"|"file"|"directory"|string[]
---@alias dotcmd.Parse fun(text: string): any?, string? Return nil and an optional message on invalid input; false is valid.

---@class dotcmd.ValueSpec
---@field type? dotcmd.ArgType Defaults to string. An array declares an enum. Path types preserve strings without checking existence.
---@field parse? dotcmd.Parse Custom conversion/validation, instead of type. Exceptions remain Lua errors.
---@field arity? dotcmd.Arity 1 = required scalar, ? = optional scalar, + = required repeated, * = optional repeated.
---@field default? any Already-parsed value for optional arity, passed through unchanged; repeated defaults are arrays.
---@field description? string Help description.

---@class dotcmd.Option: dotcmd.ValueSpec
---@field flag? boolean Consume no value and produce true; cannot have type or parse. Absent scalar flags default to false.
---@field short? string Letters or punctuation used as short aliases: h? declares -h and -?. Values use -j 4 or -j=4.
-- Option arity defaults to ?. Repeated options produce arrays, including flags.

---@class dotcmd.Argument: dotcmd.ValueSpec
---@field [integer] string Display name at index 1, for help and errors.
-- Positional arity defaults to 1. Only the final positional may have another arity.
-- Repeated positionals expand into varargs; a missing optional scalar passes nil.

---@class dotcmd.Arguments: dotcmd.Argument[]
---@field end_opts? boolean The first token that is not a declared option or -- starts the positionals and ends option recognition. Defaults to false; positional parsing still applies.

---@class dotcmd.Command
---@field aliases? string[] Additional literal CLI names, listed after the primary name in help.
---@field description? string First line is the summary in command listings; command help shows the full text.
---@field opts? table<string, dotcmd.Option> Result keys; underscores become hyphens in long-option spellings. Presence enables option parsing and prepends an options table to run.
---@field args? dotcmd.Arguments Positional schema; omitted means unrestricted strings, empty means no positionals.
---@field run fun(...: any): integer? Receives opts first when declared, then individual positionals. Returns nil or an exit code from 0 to 255.

---@alias dotcmd.Commands table<string, dotcmd.Run|dotcmd.Command> Underscores in keys become hyphens in CLI command names.

-- Opt in per file with: ---@type dotcmd.Env|_G followed by local _ENV = _ENV.
---@class dotcmd.Env
---@field host dotcmd.Host
---@field http fun(options: string|dotcmd.HttpOptions): dotcmd.HttpResponse HTTPS requests; transport/filesystem failures raise. SSL_CERT_FILE selects a PEM trust bundle.
---@field exec fun(program: string|dotcmd.ExecOptions, ...: string): dotcmd.ExecResult Executes without a shell; returns the exit code and captured output.
---@field spawn fun(program: string|dotcmd.SpawnOptions, ...: string): dotcmd.Process Starts without a shell and returns immediately. Startup failures raise; captured output is drained automatically.
---@field sha256 fun(input: string|dotcmd.File): string Hash bytes or a file; returns lowercase hexadecimal.
---@field fs dotcmd.Fs
---@field extract fun(options: string|dotcmd.ExtractOptions): boolean Extract ZIP, tar, tar.gz, or tar.xz. Returns true on success, false when skipped; parent must exist.
---@field cached fun(options: dotcmd.CachedOptions): string Absolute download path, or prepared file/directory path when prepare is supplied.

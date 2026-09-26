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

---@class dotcmd.HttpOptions
---@field url string HTTPS URL.
---@field method? string Defaults to GET.
---@field headers? table<string, string|string[]> Arrays send repeated headers.
---@field body? string Binary-safe request body.
---@field to? string Output file, relative to cwd. Only a successful 2xx response replaces it.
---@field connect_timeout? integer Seconds; defaults to 30.
---@field timeout? integer Seconds; defaults to 0 (unlimited).
---@field check? false Disable checking the final HTTP status; non-2xx responses raise by default.

---@class dotcmd.HttpResponse
---@field url string Final URL after redirects.
---@field status integer
---@field headers table<string, string[]> Lowercase names; values always arrays.
---@field body string Binary-safe response body; absent when using to. Annotated as a string to avoid nil checks for in-memory responses.

---@class dotcmd.Sha256Options
---@field bytes? string Binary-safe contents; mutually exclusive with path. Exactly one is required.
---@field path? string File to hash; mutually exclusive with bytes.

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
---@field check? false Disable checking the exit code; nonzero exits raise by default.

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
---@field wait fun(self: dotcmd.Process, options?: {check?: false}): dotcmd.ExecResult Wait for exit and captured output. check defaults to true; nonzero exits raise a table with message and exit_code. false returns nonzero exits without raising.
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

---@alias dotcmd.IfExists "error"|"skip"|"replace"

---@class dotcmd.ExtractOptions
---@field if_exists? dotcmd.IfExists Defaults to error. Replacement swaps trees on Unix; Windows moves the old tree aside before publication.
---@field include? string[] Exact archive paths or directory prefixes, matched before stripping.
---@field path string Archive file; format detected by contents.
---@field strip_components? integer Leading path components to remove; defaults to 0.
---@field to? string New destination directory; defaults to the archive path without its suffix.

---Creates output as a file or directory. Its parent exists; output does not.
---Input is the cached download and must not be modified. Return values are ignored.
---Output is temporary and will be moved after success; do not embed its path.
---Cache identity includes stripped Lua bytecode, not captured values or ambient state.
---@alias dotcmd.Prepare fun(input: string, output: string)

---@class dotcmd.PinnedSource
---@field url string HTTPS download URL.
---@field sha256 string Pinned download hash.

---@class dotcmd.FetchOptions: dotcmd.PinnedSource
---@field name? string Download filename; defaults to the URL filename, or download.
---@field prepare? dotcmd.Prepare Run only on a prepared-cache miss. Accepts a function; errors discard partial output.

---@alias dotcmd.Run fun(...: string): any

---@alias dotcmd.Color "black"|"red"|"green"|"yellow"|"blue"|"magenta"|"cyan"|"white"|"bright_black"|"bright_red"|"bright_green"|"bright_yellow"|"bright_blue"|"bright_magenta"|"bright_cyan"|"bright_white"|integer|string

---@class dotcmd.Style
---@field fg? dotcmd.Color|false Named color, palette index from 0 to 255, #RRGGBB, or false for the default.
---@field bg? dotcmd.Color|false Named color, palette index from 0 to 255, #RRGGBB, or false for the default.
---@field bold? boolean
---@field dim? boolean
---@field underline? boolean

---@alias dotcmd.Markup string|number|boolean|dotcmd.MarkupNode

---@class dotcmd.MarkupNode: dotcmd.Style
---@field style? dotcmd.Style Applied before keys directly on the node.
---@field [integer] dotcmd.Markup

---@class dotcmd.Format
---@field plain fun(markup: dotcmd.Markup): string
---@field ansi fun(markup: dotcmd.Markup): string
---@field writer fun(file: file*): dotcmd.FormatWriter Detects terminal support once when constructed.

---@class dotcmd.FormatWriter
---@field write fun(self: dotcmd.FormatWriter, markup: dotcmd.Markup): dotcmd.FormatWriter
---@field flush fun(self: dotcmd.FormatWriter): dotcmd.FormatWriter

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
---@field hidden? boolean Omit this option from help and completion suggestions; it remains accepted by the parser.
-- Option arity defaults to ?. Repeated options produce arrays, including flags.

---@class dotcmd.Argument: dotcmd.ValueSpec
---@field [integer] string Display name at index 1, for help and errors.
-- Positional arity defaults to 1. Only the final positional may have another arity.
-- Repeated positionals expand into varargs; a missing optional scalar passes nil.

---@class dotcmd.Arguments
---@field [integer] dotcmd.Argument
---@field end_opts? boolean The first token that is not a declared option or -- starts the positionals and ends option recognition. Defaults to false; positional parsing still applies.

---Errors print without an added traceback and default to exit 1. For a custom status, raise
---error({message = "...", exit_code = 2}). message is optional and converted with tostring;
---exit_code must be an integer from 0 to 255, otherwise it falls back to 1.
---@class dotcmd.Command
---@field hidden? boolean Omit this command and its aliases from help listings and completion suggestions; it remains callable.
---@field aliases? string[] Additional literal CLI names, listed after the primary name in help.
---@field description? string First line is the summary in command listings; command help shows the full text.
---@field opts? table<string, dotcmd.Option> Result keys; underscores become hyphens in long-option spellings. Inherited by descendants; their option spellings must not conflict.
---@field args? dotcmd.Arguments Leaf positional schema; omitted means unrestricted strings, empty means no positionals. Cannot be combined with commands.
---@field commands? dotcmd.Commands Named child commands. May be combined with opts and a run for bare invocation, but not args.
---@field run? fun(...: any): any Required on leaves. Receives one combined opts table first when this command or an ancestor declares opts, then individual positionals. On a group, runs only when no child is selected; omitting it shows group help. Every returned value is printed on its own line using print, including nil; returning no values prints nothing. Normal completion exits 0. Raise an error for failure.

---@alias dotcmd.Commands table<string, dotcmd.Run|dotcmd.Command> Underscores in keys become hyphens in CLI command names at every level.

---@class dotcmd.Json
---@field decode fun(text: string): any Decode strict JSON. Objects and arrays become tables; null becomes nil. Invalid input raises.

-- Globals provided by the dotcmd runtime.
---@type dotcmd.Host
host = nil

---@type dotcmd.Fs
fs = nil

---@type dotcmd.Json
json = nil

---HTTPS requests; transport/filesystem failures raise. SSL_CERT_FILE selects a PEM trust bundle.
---@param options string|dotcmd.HttpOptions
---@return dotcmd.HttpResponse
function http(options) end

---Executes without a shell; returns the exit code and captured output.
---Checked nonzero exits raise a table with the child's exit_code and a message.
---@param program string|dotcmd.ExecOptions
---@param ... string
---@return dotcmd.ExecResult
function exec(program, ...) end

---Starts without a shell and returns immediately. Startup failures raise; captured output is drained automatically.
---@param program string|dotcmd.SpawnOptions
---@param ... string
---@return dotcmd.Process
function spawn(program, ...) end

---Hash bytes or a file; returns lowercase hexadecimal.
---@param options dotcmd.Sha256Options
---@return string
function sha256(options) end

---Accepts (path, to?) or an options table. Extracts ZIP, tar, tar.gz, or tar.xz.
---Returns true on success, false when skipped; parent must exist.
---@param options string|dotcmd.ExtractOptions
---@param to? string
---@return boolean
function extract(options, to) end

---Accepts (url, sha256) or an options table. Returns an absolute download or prepared path.
---Downloads are verified; cache hits are trusted.
---@param options string|dotcmd.FetchOptions
---@param sha256? string
---@return string
function fetch(options, sha256) end

---Forwards arguments after url and sha256 to the plugin chunk.
---Caches the download, reverifies and executes the source on every call in the normal global environment.
---Returns every value returned by the plugin chunk.
---@param url string
---@param sha256 string
---@param ... any
---@return any
function plugin(url, sha256, ...) end

---@meta

---@class Host
---@field os "linux"|"macos"|"windows"
---@field arch "x64"|"arm64"
---@field exe_suffix ""|".exe" Executable filename suffix.
---@field path_sep ":"|";" Separator between PATH entries.
---@field dir_sep "/"|"\\" Directory separator.
---@field executable string Absolute executable path.
---@field project_dir string Directory containing the launcher; relative paths resolve here. Uses native separators.
---@field invocation_dir string Initial working directory before entering the project. Uses native separators.
---@field cache_dir string Shared cache root; honors DOTCMD_CACHE_DIR.

---Called with binary string chunks; chunk boundaries are arbitrary and empty strings are valid.
---Called with no arguments once after success to complete; its first return value becomes the result.
---Chunk-call return values are ignored. Errors abort the producer; failures skip completion.
---Consumers own their state and must arrange cleanup independently of successful completion.
---@alias ChunkConsumer fun(chunk?: string): any

---Called without arguments once per operation to create a fresh consumer.
---@alias ConsumerFactory fun(): ChunkConsumer

---@class HttpOptions
---@field url string HTTPS URL.
---@field method? string Defaults to GET.
---@field headers? table<string, string|string[]> Arrays send repeated headers. User-Agent defaults to dotcmd/<version>.
---@field body? string Binary-safe request body.
---@field to? string|ConsumerFactory Output file or consumer factory. File paths are relative to cwd; only a successful 2xx response replaces a file. Consumers receive the final response body; completion runs only after transport and enabled status checks succeed. With check=false, error response bodies are consumed and completed too.
---@field connect_timeout? integer Seconds; defaults to 30.
---@field timeout? integer Seconds; defaults to 0 (unlimited).
---@field check? false Disable checking the final HTTP status; non-2xx responses raise by default.
---@field progress? true Show download progress on terminal stderr after a short delay.

---@class HttpResponse
---@field url string Final URL after redirects.
---@field status integer
---@field headers table<string, string[]> Lowercase names; values always arrays.
---@field body string|any Binary-safe response string by default, or the consumer completion value when to is a factory. Absent when to is a file path. Streaming does not retain the response bytes.

---@class Sha256Options
---@field bytes? string Binary-safe contents; mutually exclusive with path. Exactly one is required.
---@field path? string File to hash; mutually exclusive with bytes.

---@class File
---@field path string

---@alias Output "inherit"|"capture"|"discard"|File
---@alias Input "inherit"|"discard"|File
---Update or remove a command's environment variable.
---Receives the effective previous value inherited from the parent process or an inner command, or nil when absent.
---Return a string to set the variable, or nil or false to remove it.
---@alias EnvUpdate fun(old: string?): string|false|nil
---@alias EnvValue string|false|EnvUpdate

---@class Command
---@field [integer] string|Command Index 1 is a program string or inner command; remaining indexed values are string arguments.
---@field cwd? string Child working directory; the outermost specified value wins and otherwise defaults to the project directory. Use host.invocation_dir to run where dotcmd was invoked.
---@field env? table<string, EnvValue> Overlay inherited and inner command variables; outer values win. An update function receives the effective old value, or nil when absent; nil or false removes the variable.

---Execution settings are read only from the command table passed directly to exec, never from inner commands.
---@class ExecCommand: Command
---@field stdin? Input Defaults to inherit. File paths are relative to the child's cwd.
---@field stdout? Output Defaults to inherit. File paths are relative to the child's cwd.
---@field stderr? Output|"stdout" Defaults to inherit; stdout merges into standard output.
---@field check? false Disable checking the exit code; nonzero exits raise by default.

---@class ExecResult
---@field code integer Exit code.
---@field stdout string Present only when captured; annotated as a string to avoid nil checks at capture sites.
---@field stderr string Present only when captured; annotated as a string to avoid nil checks at capture sites.

---Execution settings are read only from the command table passed directly to spawn, never from inner commands.
---@class SpawnCommand: Command
---@field stdin? Input|"pipe" Defaults to inherit. File paths are relative to the child's cwd.
---@field stdout? Output|"pipe" Defaults to inherit. Output files are truncated.
---@field stderr? Output|"pipe"|"stdout" Defaults to inherit; stdout merges into standard output.

---@class Process
---@field stdin file* Present when stdin is piped. Writes block; close it to send EOF.
---@field stdout file* Present when stdout is piped. Reads block; callers must drain piped output.
---@field stderr file* Present when stderr is piped. Reads block; callers must drain piped output.
---@field wait fun(self: Process, options?: {check?: false}): ExecResult Wait for exit and captured output. check defaults to true; nonzero exits raise a table with exit_code and, unless effective stderr is inherited, a message. false returns nonzero exits without raising.
---@field poll fun(self: Process): ExecResult? Return the completed result, or nil while running or collecting output.
---@field kill fun(self: Process) Force-stop the direct child if running, without waiting.
---@field close fun(self: Process) Stop the direct child, wait, and close pipes. Also called by <close>; safe to repeat.

---@class Stat
---@field type "file"|"directory"|"symlink"|"other"
---@field size integer Bytes.
---@field mode integer Unix permission bits (0777 mask); 0 on Windows, where chmod is a no-op.

---@class Fs
---@field read fun(path: string): string? Reads the whole file as binary bytes; nil when missing, other failures raise.
---@field write fun(path: string, bytes: string, options?: WriteOptions): boolean Atomic whole-file write; true on success, false only when skipped. Checks writing and closing; does not sync to durable storage.
---@field stat fun(path: string, options?: {follow?: boolean}): Stat? Missing paths return nil; follow defaults to true.
---@field realpath fun(path: string): string Absolute path with symlinks resolved; the path must exist. Raises on failure. Windows returns an extended-length path.
---@field list fun(path: string): fun(): string? Unsorted entry names for a generic for loop.
---@field mkdir fun(path: string) Creates parent directories too.
---@field remove fun(path: string, options?: {recursive?: boolean}) Ignores missing paths; never traverses symlinks.
---@field rename fun(from: string, to: string, options?: {if_exists?: IfExists}): boolean Atomic rename; if_exists defaults to error. Returns true on success, false when skipped; failures raise.
---@field chmod fun(path: string, mode: integer|"+x") Sets Unix permission bits (0 through 0777), or adds execute bits allowed by umask with "+x"; no-op on Windows.

---@alias IfExists "error"|"skip"|"replace"

---@class WriteOptions
---Replacement changes file identity: other hardlinks retain the previous file.
---@field parents? boolean Create parent directories; defaults to true.
---@field if_exists? IfExists Defaults to replace, without reading or comparing existing contents. Replacement follows existing symlinks (dangling links raise) and preserves Unix permissions. Error and skip apply to any existing entry, including a symlink.

---@class ExtractOptions
---@field if_exists? IfExists Defaults to error. Replacement swaps trees on Unix; Windows moves the old tree aside before publication.
---@field include? string[] Exact archive paths or directory prefixes, matched before stripping.
---@field path string Archive file; format detected by contents.
---@field strip_components? integer Leading path components to remove; defaults to 0.
---@field to? string New destination directory; defaults to the archive path without its suffix. Missing parents are created.

---Creates output as a file or directory. Its parent exists; output does not.
---Input is the cached download and must not be modified. Return values are ignored.
---Output is temporary and will be moved after success; do not embed its path.
---Cache identity includes stripped Lua bytecode, not captured values or ambient state.
---@alias Prepare fun(input: string, output: string)

---@class PinnedSource
---@field url string HTTPS download URL.
---@field sha256 string Pinned download hash.

---@class FetchOptions: PinnedSource
---@field name? string Download filename; defaults to the URL filename, or download.
---@field prepare? Prepare Run only on a prepared-cache miss. Accepts a function; errors discard partial output.

---Task function receiving unparsed command-line arguments.
---Use directly as a value in the task table returned by .cmd.lua.
---Each returned value is printed on its own line; return no values to print nothing. Errors fail the task.
---@alias TaskFunction fun(...: string): any

---@alias Arity "1"|"?"|"+"|"*"
---@alias ArgType "string"|"number"|"integer"|"boolean"|"file"|"directory"|string[]
---@alias Parse fun(text: string): any?, string? Return nil and an optional message on invalid input; false is valid.

---@class ValueSpec
---@field type? ArgType Defaults to string. An array declares an enum. Path types preserve strings without checking existence.
---@field parse? Parse Custom conversion/validation, instead of type. Exceptions remain Lua errors.
---@field arity? Arity 1 = required scalar, ? = optional scalar, + = required repeated, * = optional repeated.
---@field default? any Already-parsed value for optional arity, passed through unchanged; repeated defaults are arrays.
---@field description? string Help description.

---@class Option: ValueSpec
---@field flag? boolean Consume no value and produce true; cannot have type or parse. Absent scalar flags default to false.
---@field short? string Letters or punctuation used as short aliases: h? declares -h and -?. Values use -j 4 or -j=4.
---@field hidden? boolean Omit this option from help and completion suggestions; it remains accepted by the parser.
-- Option arity defaults to ?. Repeated options produce arrays, including flags.

---@class Argument: ValueSpec
---@field [integer] string Display name at index 1, for help and errors.
-- Positional arity defaults to 1. Only the final positional may have another arity.
-- Repeated positionals expand into varargs; a missing optional scalar passes nil.

---@class Arguments
---@field [integer] Argument
---@field end_opts? boolean The first token that is not a declared option or -- starts the positionals and ends option recognition. Defaults to false; positional parsing still applies.

---Errors print without an added traceback and default to exit 1. For a custom status, raise
---error({message = "...", exit_code = 2}). message is optional and converted with tostring;
---exit_code must be an integer from 0 to 255, otherwise it falls back to 1.
---@class Task
---@field hidden? boolean Omit this task and its aliases from help listings and completion suggestions; it remains callable.
---@field aliases? string[] Additional literal CLI names, listed after the primary name in help.
---@field description? string First line is the summary in task listings; task help shows the full text.
---@field opts? table<string, Option> Result keys; underscores become hyphens in long-option spellings. Inherited by descendants; their option spellings must not conflict.
---@field args? Arguments Leaf positional schema; omitted means unrestricted strings, empty means no positionals. Cannot be combined with tasks.
---@field tasks? Tasks Named child tasks. May be combined with opts and a run for bare invocation, but not args.
---@field run? fun(...: any): any Required on leaves. Receives one combined opts table first when this task or an ancestor declares opts, then individual positionals. On a group, runs only when no child is selected; omitting it shows group help. Every returned value is printed on its own line, including nil; returning no values prints nothing. Strings are quoted and escaped as Lua literals. Plain tables are printed deterministically; tables with a __tostring metamethod and other non-table values retain print behavior. Return values are syntax-colored on terminals unless NO_COLOR is set or TERM is dumb; redirected output remains plain. Values and keys that have no Lua literal representation, including functions, userdata, threads, cycles, table keys, and non-finite numbers, are shown as angle-bracketed tostring pseudo-values. Normal completion exits 0. Raise an error for failure.

---@alias Tasks table<string, TaskFunction|Task> Underscores in keys become hyphens in CLI task names at every level.

---@class JsonEncodeOptions
---@field pretty? boolean Use two-space indentation; defaults to compact JSON. No trailing newline.

---Table metatables may specify __jsontype = "array" or "object". Hints are enforced:
---arrays require consecutive integer keys starting at 1; objects require string keys.
---Nonempty untagged tables are inferred from their keys; empty untagged tables raise.
---Use json.decode("[]") or json.decode("{}") to create an empty table with a hint.
---@class Json
---@field decode fun(text: string): any Decode strict JSON. Objects and arrays become tables with __jsontype metatable hints; null becomes nil. Invalid input raises. Nulls are not preserved for re-encoding.
---@field encode fun(value: any, options?: JsonEncodeOptions): string Encode nil as null, booleans, finite numbers, UTF-8 strings, and tables. Object keys are sorted by bytes. Cycles, sparse arrays, incompatible keys, invalid hints, and unsupported values raise. Shared tables are allowed.

-- Globals provided by the dotcmd runtime.
---@type Host
host = nil

---@type Fs
fs = nil

---@type Json
json = nil

---Invokes a task with CLI words, including built-ins, aliases, nested tasks, defaults, and conversions.
---Uses the loaded project task definitions without reloading .cmd.lua. Available after project loading completes.
---Returns the task's original Lua values without printing them; explicit task output is retained.
---Task errors propagate. Lookup and argument errors raise tables with message and the CLI exit_code.
---A group without run shows help and raises exit_code 2.
---@param ... string CLI words: task path followed by options and positional arguments.
---@return any ...
function task(...) end

---HTTPS requests; transport/filesystem failures raise. SSL_CERT_FILE selects a PEM trust bundle.
---@param options string|HttpOptions
---@return HttpResponse
function http(options) end

---Executes without a shell; returns the exit code and captured output.
---Checked nonzero exits raise a table with the child's exit_code and, unless effective stderr is inherited, a message.
---@param command string|Command|ExecCommand
---@param ... string
---@return ExecResult
function exec(command, ...) end

---Starts without a shell and returns immediately. Startup failures raise; captured output is drained automatically.
---@param command string|Command|SpawnCommand
---@param ... string
---@return Process
function spawn(command, ...) end

---Hash bytes or a file; returns lowercase hexadecimal.
---With no arguments, returns a chunk consumer: call with one string to update or no arguments to finish.
---Completion releases native resources and returns the digest; further calls raise.
---Abandoned consumers release their native state when garbage-collected.
---@overload fun(): ChunkConsumer
---@param options Sha256Options
---@return string
function sha256(options) end

---Accepts (path, to?) or an options table. Extracts ZIP, tar, tar.gz, or tar.xz.
---Returns true on success, false when skipped. Missing parents are created and may remain after failure.
---@param options string|ExtractOptions
---@param to? string
---@return boolean
function extract(options, to) end

---Accepts (url, sha256) or an options table. Returns an absolute download or prepared path.
---Downloads are verified; cache hits are trusted.
---@param options string|FetchOptions
---@param sha256? string
---@return string
function fetch(options, sha256) end

---Executes a source SHA-256 once and caches all values returned by its chunk for this run.
---The URL locates the source and is not part of its identity.
---Returns every value returned by the plugin chunk.
---@param url string
---@param sha256 string
---@return any
function plugin(url, sha256) end

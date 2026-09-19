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
---@field status integer
---@field headers table<string, string[]> Lowercase names; values always arrays.
---@field body? string Binary-safe response body; absent when using path.

---@class dotcmd.File
---@field path string

---@alias dotcmd.Output "inherit"|"capture"|"discard"|dotcmd.File

---@class dotcmd.ExecOptions
---@field [integer] string Program at index 1, followed by arguments.
---@field cwd? string Child working directory; defaults to the caller's cwd.
---@field env? table<string, string|false> Overlay inherited variables; false removes one.
---@field stdout? dotcmd.Output Defaults to inherit. File paths are relative to the child's cwd.
---@field stderr? dotcmd.Output|"stdout" Defaults to inherit; stdout merges into standard output.
---@field check? boolean Raise on a nonzero exit; defaults to false.

---@class dotcmd.Stat
---@field type "file"|"directory"|"symlink"|"other"
---@field size integer Bytes.

---@class dotcmd.Fs
---@field stat fun(path: string, options?: {follow?: boolean}): dotcmd.Stat? Missing paths return nil; follow defaults to true.
---@field list fun(path: string): fun(): string? Unsorted entry names for a generic for loop.
---@field mkdir fun(path: string) Creates parent directories too.
---@field remove fun(path: string, options?: {recursive?: boolean}) Ignores missing paths; never traverses symlinks.
---@field rename fun(from: string, to: string, options?: {replace?: boolean}) Atomic rename; replace defaults to true. An existing destination raises dotcmd.DestinationExists when replace=false.
---@field make_executable fun(path: string) Adds Unix execute bits; no-op on Windows.

---@class dotcmd.Extraction
---@field strip_components? integer Leading path components to remove; defaults to 0.
---@field include? string[] Exact archive paths or directory prefixes, matched before stripping.

---@class dotcmd.DestinationExists
---@field code "destination_exists"
---@field message string Also returned by tostring(error).

---@class dotcmd.ExtractOptions: dotcmd.Extraction
---@field path string Archive file; format detected by contents.
---@field to? string New destination directory; defaults to the archive path without its suffix.

---@class dotcmd.CachedOptions
---@field url string HTTPS download URL.
---@field sha256 string Pinned download hash. Verified only when downloading; cache hits are trusted.
---@field name? string Download filename; defaults to the URL filename, or download.
---@field extract? boolean|dotcmd.Extraction Extract into a cached directory; defaults to false.

---@alias dotcmd.Run fun(...: string): integer?

---@class dotcmd.Command
---@field description? string Help description.
---@field run dotcmd.Run

---@alias dotcmd.Commands table<string, dotcmd.Run|dotcmd.Command>

-- Opt in per file with: ---@type dotcmd.Env|_G followed by local _ENV = _ENV.
---@class dotcmd.Env
---@field host dotcmd.Host
---@field http fun(options: string|dotcmd.HttpOptions): dotcmd.HttpResponse HTTPS requests; transport/filesystem failures raise.
---@field exec fun(program: string|dotcmd.ExecOptions, ...: string): integer, string?, string? Exit code and captured stdout/stderr. Executes without a shell.
---@field sha256 fun(input: string|dotcmd.File): string Hash bytes or a file; returns lowercase hexadecimal.
---@field fs dotcmd.Fs
---@field extract fun(options: string|dotcmd.ExtractOptions) Extract ZIP, tar, tar.gz, or tar.xz. Destination must not exist; parent must exist.
---@field cached fun(options: dotcmd.CachedOptions): string Absolute cached file path, or directory path when extracting.

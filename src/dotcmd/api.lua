-- Public runtime contracts. The root describes the runtime globals. Native functions
-- keep their own checks; their signatures and result interfaces are descriptive.
-- In particular, Process describes a native userdata's members, not a Lua table.
-- Captured strings and pipe handles are nonnullable for convenient use at sites
-- that explicitly request them; their descriptions say when they are present.
local S = require("dotcmd.schema")

local function signature(params, returns)
    return { params = S.table { fields = params }, returns = S.table { fields = returns or {} } }
end
local function func(params, returns, properties)
    properties = properties or {}
    properties.signatures = { signature(params, returns) }
    return S.func(properties)
end

local api = S.registry {
    definitions = {
        Host = S.table { description = "Platform, executable, project, and cache information.",
            examples = [[Select platform-specific values from nested OS and architecture tables:

    local hashes = {
        linux = { x64 = "...", arm64 = "..." },
        macos = { x64 = "...", arm64 = "..." },
        windows = { x64 = "...", arm64 = "..." }
    }

    local hash = hashes[host.os][host.arch]
]],
            fields = {
                os = S.enum { values = { "linux", "macos", "windows" } }, arch = S.enum { values = { "x64", "arm64" } },
                exe_suffix = S.enum { description = "Executable filename suffix.", values = { "", ".exe" } },
                path_sep = S.enum { description = "Separator between PATH entries.", values = { ":", ";" } },
                dir_sep = S.enum { description = "Directory separator.", values = { "/", "\\" } },
                executable = S.string { description = "Absolute executable path." },
                project_dir = S.string { description = "Directory containing the launcher; relative paths resolve here. Uses native separators." },
                invocation_dir = S.string { description = "Initial working directory before entering the project. Uses native separators." },
                cache_dir = S.string { description = "Shared cache root; honors DOTCMD_CACHE_DIR." },
            },
        },
        ChunkConsumer = S.func { description = "Called with binary string chunks; chunk boundaries are arbitrary and empty strings are valid.\nCalled with no "
            .. "arguments once after success to complete; its first return value becomes the result.\nChunk-call return values "
            .. "are ignored. Errors abort the producer; failures skip completion.\nConsumers own their state and must arrange "
            .. "cleanup independently of successful completion.", signatures = {
            signature({ { "chunk", S.string { description = "Binary chunk; empty strings are valid." } } },
                { { "ignored", S.any(), arity = "*" } }),
            signature({}, { { "result", S.any(), arity = "?" } }),
        } },
        ConsumerFactory = func({}, { { "consumer", S.ref { name = "ChunkConsumer" } } }, {
            description = "Called without arguments once per operation to create a fresh consumer.",
        }),
        HttpOptions = S.table { description = "HTTPS request and response handling options.", fields = {
            url = S.string { description = "HTTPS URL." },
            method = S.optional { schema = S.string { description = "Defaults to GET." } },
            headers = S.optional { description = "Arrays send repeated headers. User-Agent defaults to dotcmd/<version>.", schema = S.map { key = S.string(), value = S.union { alternatives = { S.string(), S.array { items = S.string() } } } } },
            body = S.optional { schema = S.string { description = "Binary-safe request body." } },
            to = S.optional { description = "Output file or consumer factory. File paths are relative to cwd; only a successful 2xx response replaces a "
                .. "file. Consumers receive the final response body; completion runs only after transport and enabled status "
                .. "checks succeed. With check=false, error response bodies are consumed and completed too.", schema = S.union { alternatives = { S.string(), S.ref { name = "ConsumerFactory" } } } },
            connect_timeout = S.optional { schema = S.integer { description = "Nonnegative seconds; defaults to 30." } },
            timeout = S.optional { schema = S.integer { description = "Nonnegative seconds; defaults to 0 (unlimited)." } },
            check = S.any { description = "False disables HTTP status checking; every other value enables it. Non-2xx responses raise by default." },
        } },
        HttpResponse = S.table { description = "Final HTTPS response, including headers and the requested body result.", fields = {
            url = S.string { description = "Final URL after redirects." }, status = S.integer { description = "Final HTTP status code." },
            headers = S.map { description = "Lowercase names; values always arrays.", key = S.string(), value = S.array { items = S.string() } },
            body = S.union {
                description = "Binary-safe response string by default, or the consumer completion value when to is a factory. Absent when to "
                    .. "is a file path. Streaming does not retain the response bytes.",
                alternatives = { S.string(), S.any() },
            },
        } },
        Sha256Options = S.table {
            description = "Hash exactly one of bytes or a file path.",
            fields = {
                bytes = S.optional { description = "Binary-safe contents; mutually exclusive with path. Exactly one is required.", schema = S.string() },
                path = S.optional { description = "File to hash; mutually exclusive with bytes.", schema = S.string() },
            },
            validate = function(value)
                return (value.bytes ~= nil) ~= (value.path ~= nil), "specify exactly one of \"bytes\" or \"path\""
            end,
        },
        File = S.table { description = "File path for command stream redirection.", fields = { path = S.string() } },
        Output = S.union { description = "Inherited, captured, discarded, or redirected output.", alternatives = { S.enum { values = { "inherit", "capture", "discard" } }, S.ref { name = "File" } } },
        Input = S.union { description = "Inherited, discarded, or redirected standard input.", alternatives = { S.enum { values = { "inherit", "discard" } }, S.ref { name = "File" } } },
        EnvUpdate = func({ { "old", S.optional { schema = S.string { description = "Effective previous value, or nil when absent." } }, arity = "?" } }, {
            { "value", S.union { alternatives = { S.string(), S.literal { value = false }, S.null() } } },
        }, { description = "Update or remove a command's environment variable.\n"
            .. "Receives the effective previous value inherited from the parent process or an inner command, or nil when absent.\n"
            .. "Return a string to set the variable, or nil or false to remove it." }),
        EnvValue = S.union { description = "Environment replacement, removal, or update function.", alternatives = { S.string(), S.literal { value = false }, S.ref { name = "EnvUpdate" } } },
        Command = S.table {
            description = "Program or nested command, with string arguments, working directory, and environment.",
            examples = [[Reuse a command's working directory and environment while appending arguments:

    local git = {
        "git",
        cwd = host.invocation_dir,
        env = { GIT_TERMINAL_PROMPT = "0" }
    }

    exec { git, "status", "--short" }
    exec { git, "diff", "--stat" }

Forward all task arguments with named fields first and ... last:

    exec { cwd = host.invocation_dir, env = env, program, ... }
]],
            fields = {
                { "command", S.union { description = "Program string or inner command at index 1.", alternatives = { S.string(), S.ref { name = "Command" } } } },
                { "arguments", S.string { description = "String arguments after the program or inner command." }, arity = "*" },
                cwd = S.optional { schema = S.string { description = "Child working directory; the outermost specified value wins and otherwise defaults to the project directory. "
                    .. "Use host.invocation_dir to run where dotcmd was invoked." } },
                env = S.optional { description = "Overlay inherited and inner command variables; outer values win. An update function receives the effective "
                    .. "old value, or nil when absent; nil or false removes the variable.", schema = S.map { key = S.string(), value = S.ref { name = "EnvValue" } } },
            },
        },
        ExecCommand = S.table {
            description = "Execution settings are read only from the command table passed directly to exec, never from inner commands.",
            extends = S.ref { name = "Command" },
            fields = {
                stdin = S.optional { schema = S.ref { description = "Defaults to inherit. File paths are relative to the child's cwd.", name = "Input" } },
                stdout = S.optional { schema = S.ref { description = "Defaults to inherit. File paths are relative to the child's cwd.", name = "Output" } },
                stderr = S.optional { schema = S.union { description = "Defaults to inherit; stdout merges into standard output.",
                    alternatives = { S.ref { name = "Output" }, S.literal { value = "stdout" } } } },
                check = S.optional { schema = S.boolean { description = "False disables exit-code checking; defaults to true. Nonzero exits raise by default." } },
            },
        },
        SpawnCommand = S.table {
            description = "Execution settings are read only from the command table passed directly to spawn, never from inner commands.",
            extends = S.ref { name = "Command" },
            fields = {
                stdin = S.optional { schema = S.union { description = "Defaults to inherit. File paths are relative to the child's cwd.",
                    alternatives = { S.ref { name = "Input" }, S.literal { value = "pipe" } } } },
                stdout = S.optional { schema = S.union { description = "Defaults to inherit. Output files are truncated.",
                    alternatives = { S.ref { name = "Output" }, S.literal { value = "pipe" } } } },
                stderr = S.optional { schema = S.union { description = "Defaults to inherit; stdout merges into standard output.",
                    alternatives = { S.ref { name = "Output" }, S.enum { values = { "pipe", "stdout" } } } } },
            },
        },
        ExecResult = S.table { description = "Exit code and requested captured output.", fields = {
            exit_code = S.integer { description = "Exit code." }, stdout = S.string { description = "Present when captured." },
            stderr = S.string { description = "Present when captured." },
        } },
        Process = S.table { description = "Running process, with requested pipes and lifecycle methods.", fields = {
            stdin = S.file { description = "Present when stdin is piped. Writes block; close it to send EOF." },
            stdout = S.file { description = "Present when stdout is piped. Reads block; callers must drain piped output." },
            stderr = S.file { description = "Present when stderr is piped. Reads block; callers must drain piped output." },
            wait = func({ { "self", S.ref { name = "Process" } }, { "options", S.optional { schema = S.table { fields = {
                check = S.optional { schema = S.boolean { description = "False disables exit-code checking; defaults to true." } },
            } } }, arity = "?" } }, { { "result", S.ref { name = "ExecResult" } } }, { description = "Wait for exit and captured output. check defaults to true; nonzero exits raise a table with exit_code and, "
                .. "unless effective stderr is inherited, a message. false returns nonzero exits without raising." }),
            poll = func({ { "self", S.ref { name = "Process" } } }, { { "result", S.optional { schema = S.ref { name = "ExecResult" } } } }, { description = "Return the completed result, or nil while running or collecting output." }),
            kill = func({ { "self", S.ref { name = "Process" } } }, {}, { description = "Force-stop the direct child if running, without waiting." }),
            close = func({ { "self", S.ref { name = "Process" } } }, {}, { description = "Stop the direct child, wait, and close pipes. Also called by <close>; safe to repeat." }),
        } },
        Stat = S.table { description = "Filesystem entry type, size, and permissions.", fields = { type = S.enum { values = { "file", "directory", "symlink", "other" } }, size = S.integer { description = "Bytes." }, mode = S.integer { description = "Unix permission bits (0777 mask); 0 on Windows, where chmod is a no-op." } } },
        IfExists = S.enum { description = "How to handle an existing destination.", values = { "error", "skip", "replace" } },
        WriteOptions = S.table { description = "Replacement changes file identity: other hardlinks retain the previous file.", fields = {
            parents = S.optional { schema = S.boolean { description = "Create parent directories; defaults to true." } },
            if_exists = S.optional { schema = S.ref { name = "IfExists", description = "Defaults to replace, without reading or comparing existing contents. Replacement follows existing symlinks "
                .. "(dangling links raise) and preserves Unix permissions. Error and skip apply to any existing entry, including "
                .. "a symlink." } },
        } },
        Fs = S.table { description = "Read, write, and manage files.", fields = {
            read = func({ { "path", S.string() } }, { { "bytes", S.optional { schema = S.string() } } }, { description = "Reads the whole file as binary bytes; nil when missing, other failures raise." }),
            write = func({ { "path", S.string() }, { "bytes", S.string() },
                { "options", S.optional { schema = S.ref { name = "WriteOptions" } }, arity = "?" } }, { { "written", S.boolean() } },
                { description = "Atomic whole-file write; true on success, false only when skipped. Checks writing and closing; does not sync to durable storage." }),
            stat = func({ { "path", S.string() }, { "options", S.optional { schema = S.table { fields = {
                follow = S.optional { schema = S.boolean { description = "Follow symlinks; defaults to true." } },
            } } }, arity = "?" } }, { { "stat", S.optional { schema = S.ref { name = "Stat" } } } }, { description = "Missing paths return nil; follow defaults to true." }),
            realpath = func({ { "path", S.string() } }, { { "path", S.string() } }, { description = "Absolute path with symlinks resolved; the path must exist. Raises on failure. Windows returns an extended-length path." }),
            list = func({ { "path", S.string() } }, { { "iterator", func({}, { { "name", S.optional { schema = S.string() } } }) } }, { description = "Unsorted entry names for a generic for loop." }),
            mkdir = func({ { "path", S.string() } }, {}, { description = "Creates parent directories too." }),
            remove = func({ { "path", S.string() }, { "options", S.optional { schema = S.table { fields = {
                recursive = S.optional { schema = S.boolean() },
            } } }, arity = "?" } }, {}, { description = "Ignores missing paths; never traverses symlinks." }),
            rename = func({ { "from", S.string() }, { "to", S.string() }, { "options", S.optional { schema = S.table { fields = {
                if_exists = S.optional { schema = S.ref { name = "IfExists", description = "Defaults to error." } },
            } } }, arity = "?" } }, { { "renamed", S.boolean() } }, { description = "Atomic rename; if_exists defaults to error. Returns true on success, false when skipped; failures raise." }),
            chmod = func({ { "path", S.string() }, { "mode", S.union { alternatives = { S.integer(), S.literal { value = "+x" } } } } }, {},
                { description = "Sets Unix permission bits (0 through 0777), or adds execute bits allowed by umask with \"+x\"; no-op on Windows." }),
        } },
        ExtractOptions = S.table { description = "Archive source, destination, and extraction options.", fields = {
            path = S.string { description = "Archive file; format detected by contents." }, to = S.optional { schema = S.string { description = "New destination directory; defaults to the archive path without its suffix. Missing parents are created." } },
            if_exists = S.optional { schema = S.ref { name = "IfExists", description = "Defaults to error. Replacement swaps trees on Unix; Windows moves the old tree aside before publication." } },
            include = S.optional { schema = S.array { items = S.string { description = "Exact archive paths or directory prefixes, matched before stripping." } } },
            strip_components = S.optional { schema = S.integer { description = "Leading path components to remove; defaults to 0." } },
            progress = S.optional { schema = S.boolean { description = "Show approximate progress through archive bytes on terminal stderr after a short delay; defaults to true." } },
        } },
        Prepare = func({ { "input", S.string() }, { "output", S.string() } },
            { { "ignored", S.any(), arity = "*" } }, {
                description = "Creates output as a file or directory. Its parent exists; output does not.\nInput is the cached download and "
                    .. "must not be modified. Return values are ignored.\nOutput is temporary and will be moved after success; do not "
                    .. "embed its path.\nCache identity includes stripped Lua bytecode, not captured values or ambient state.",
            }),
        PinnedSource = S.table { description = "Download URL and pinned SHA-256 hash.", fields = {
            url = S.string { description = "HTTPS download URL." }, sha256 = S.string { description = "Pinned download hash." },
        } },
        FetchOptions = S.table { description = "Pinned download and optional preparation.", extends = S.ref { name = "PinnedSource" }, fields = {
            name = S.optional { schema = S.string { description = "Download filename; defaults to the URL filename, or download." } },
            prepare = S.optional { schema = S.ref { name = "Prepare", description = "Run only on a prepared-cache miss. Accepts a function; errors discard partial output." } },
        } },
        TaskFunction = func({ { "arguments", S.string { description = "Unparsed command-line arguments, passed as individual strings." }, arity = "*" } },
            { { "values", S.any(), arity = "*" } }, {
                description = "Task function receiving unparsed command-line arguments.\n"
                    .. "Use directly as a value in the task table returned by .cmd.lua.\n"
                    .. "Each returned value is printed on its own line; return no values to print nothing. Errors fail the task.",
            }),
        Arity = S.enum { description = "Required scalar (1), optional scalar (?), required repeated (+), or optional repeated (*).", values = { "1", "?", "+", "*" } },
        ArgType = S.union { description = "Built-in argument type or an enum of strings.", alternatives = { S.enum { values = { "string", "number", "integer", "boolean", "file", "directory" } }, S.array { items = S.string() } } },
        Parse = func({ { "text", S.string() } }, {
            { "value", S.any() }, { "message", S.optional { schema = S.string() }, arity = "?" },
        }, { description = "Return nil and an optional message on invalid input; false is valid. Exceptions propagate." }),
        ValueSpec = S.table { description = "Value conversion, cardinality, defaults, and help text.", fields = {
            type = S.optional { schema = S.ref { name = "ArgType", description = "Defaults to string. An array declares an enum. Path types preserve strings without checking existence." } },
            parse = S.optional { schema = S.ref { name = "Parse", description = "Custom conversion/validation, instead of type. Exceptions remain Lua errors." } },
            arity = S.optional { description = "1 = required scalar, ? = optional scalar, + = required repeated, * = optional repeated.", schema = S.ref { name = "Arity" } },
            default = S.any { description = "Already-parsed value for optional arity, passed through unchanged; repeated defaults are arrays." },
            description = S.optional { description = "Help description.", schema = S.string() },
        } },
        Option = S.table {
            description = "Option arity defaults to ?. Repeated options produce arrays, including flags.",
            extends = S.ref { name = "ValueSpec" },
            fields = {
                flag = S.optional { schema = S.boolean { description = "Consume no value and produce true; cannot have type or parse. Absent scalar flags default to false." } },
                short = S.optional { schema = S.string { description = "Letters or punctuation used as short aliases: h? declares -h and -?. Values use -j 4 or -j=4." } },
                hidden = S.optional { description = "Omit this option from help and completion suggestions; it remains accepted by the parser.", schema = S.boolean() },
            },
        },
        Argument = S.table {
            description = "Positional arity defaults to 1. Only the final positional may have another arity.\nRepeated positionals expand "
                .. "into varargs; a missing optional scalar passes nil.",
            extends = S.ref { name = "ValueSpec" },
            fields = { { "name", S.string { description = "Display name at index 1, for help and errors." } } },
        },
        Arguments = S.table { description = "Positional argument definitions and option-boundary behavior.", fields = { { "arguments", S.ref { name = "Argument" }, arity = "*" },
            end_opts = S.optional { schema = S.boolean { description = "The first token that is not a declared option or -- starts the positionals and ends option recognition. "
                .. "Defaults to false; positional parsing still applies." } },
        } },
        Task = S.table { description = "Task or group, with options, positional arguments, and children.\n\nErrors print without an added traceback and default to exit 1. For a custom status, raise\nerror({message = "
            .. "\"...\", exit_code = 2}). message is optional and converted with tostring;\nexit_code must be an integer from 0 "
            .. "to 255, otherwise it falls back to 1.", fields = {
            hidden = S.optional { description = "Omit this task and its aliases from help listings and completion suggestions; it remains callable.", schema = S.boolean() },
            aliases = S.optional { description = "Additional literal CLI names, listed after the primary name in help.", schema = S.array { items = S.string() } },
            description = S.optional { description = "First line is the summary in task listings; task help shows the full text.", schema = S.string() },
            opts = S.optional { description = "Result keys; underscores become hyphens in long-option spellings. Inherited by descendants; their option spellings must not conflict.", schema = S.map { key = S.string(), value = S.ref { name = "Option" } } },
            args = S.optional { description = "Leaf positional schema; omitted means unrestricted strings, empty means no positionals. Cannot be combined with tasks.", schema = S.ref { name = "Arguments" } },
            tasks = S.optional { description = "Named child tasks. May be combined with opts and a run for bare invocation, but not args.", schema = S.ref { name = "Tasks" } },
            run = S.optional { schema = func({ { "arguments", S.any(), arity = "*" } }, { { "values", S.any(), arity = "*" } }, {
                description = "Required on leaves. Receives one combined opts table first when this task or an ancestor declares opts, then "
                    .. "individual positionals. On a group, runs only when no child is selected; omitting it shows group help. Every "
                    .. "returned value is printed on its own line, including nil; returning no values prints nothing. Strings are "
                    .. "quoted and escaped as Lua literals. Plain tables are printed deterministically; tables with a __tostring "
                    .. "metamethod and other non-table values retain print "
                    .. "behavior. Return values are syntax-colored on terminals unless NO_COLOR is set or TERM is dumb; redirected "
                    .. "output remains plain. Values and keys that have no Lua literal representation, including functions, userdata, "
                    .. "threads, cycles, table keys, and non-finite numbers, are shown as angle-bracketed tostring pseudo-values. "
                    .. "Normal completion exits 0. Raise an error for failure.",
            }) },
        } },
        Tasks = S.map {
            description = "Named tasks returned by .cmd.lua.\nUnderscores in keys become hyphens in CLI task names at every level.",
            examples = [[Define a task in .cmd.lua that downloads, extracts, and launches a tool.
Assume rg_config[os][arch] contains url and sha256 for each platform's archive,
with rg (or rg.exe on Windows) at the archive root.
Run it with .cmd search '*.lua' TODO src --hidden:

---@type Tasks
return {
    search = {
        description = "Search files matching a glob with ripgrep",
        args = { end_opts = true, { "glob", type = "string" }, { "args", arity = "*" } },
        run = function(glob, ...)
            local config = rg_config[host.os][host.arch]
            local dir = fetch { url = config.url, sha256 = config.sha256, prepare = extract }
            exec { cwd = host.invocation_dir, dir .. "/rg" .. host.exe_suffix, "--glob", glob, ... }
        end
    }
}
]],
            key = S.string(),
            value = S.union { alternatives = { S.ref { name = "TaskFunction" }, S.ref { name = "Task" } } },
        },
        JsonEncodeOptions = S.table { description = "JSON output formatting.", fields = { pretty = S.optional { schema = S.boolean { description = "Use two-space indentation; defaults to compact JSON. No trailing newline." } } } },
        Json = S.table { description = "JSON encoding and decoding.\n\nTable metatables may specify __jsontype = \"array\" or \"object\". Hints are enforced:\narrays require consecutive "
            .. "integer keys starting at 1; objects require string keys.\nNonempty untagged tables are inferred from their "
            .. "keys; empty untagged tables raise.\nUse json.decode(\"[]\") or json.decode(\"{}\") to create an empty table with a "
            .. "hint.", fields = {
            decode = func({ { "text", S.string() } }, { { "value", S.any() } },
                { description = "Decode strict JSON. Objects and arrays become tables with __jsontype metatable hints; null becomes nil. "
                    .. "Invalid input raises. Nulls are not preserved for re-encoding." }),
            encode = func({ { "value", S.any() }, { "options", S.optional { schema = S.ref { name = "JsonEncodeOptions" } }, arity = "?" } },
                { { "text", S.string() } }, { description = "Encode nil as null, booleans, finite numbers, UTF-8 strings, and tables. Object keys are sorted by bytes. "
                    .. "Cycles, sparse arrays, incompatible keys, invalid hints, and unsupported values raise. Shared tables are "
                    .. "allowed." }),
        } },
    },
    schema = S.table {
        description = ".cmd.lua returns a table of tasks and is evaluated for every invocation,\n"
            .. "including help and completion. Put task-specific work inside task functions.",
        fields = {
        host = S.ref { name = "Host" }, fs = S.ref { name = "Fs" },
        json = S.ref { name = "Json", description = "Encode and decode JSON." },
        prepend_path = func({ { "directories", S.string { description = "Directories to prepend in the given order, using host.path_sep." }, arity = "+" } },
            { { "update", S.ref { name = "EnvUpdate" } } }, {
                description = "Returns an environment updater that prepends directories to PATH.\n"
                    .. "Use as env.PATH with exec or spawn. Preserves the effective inherited or inner command PATH;\n"
                    .. "an absent or empty PATH adds no trailing separator. Does not normalize or deduplicate directories.",
                examples = [[Prepend a tool's bin directory while preserving the effective PATH:

    exec { "tool", env = { PATH = prepend_path(sdk .. "/bin") } }

Prepend multiple directories in order:

    exec { "tool", env = { PATH = prepend_path(sdk .. "/bin", other_sdk .. "/bin") } }]],
            }),
        task = func({ { "arguments", S.string { description = "CLI words: task path followed by options and positional arguments." }, arity = "*" } },
            { { "values", S.any(), arity = "*" } }, {
                description = "Invokes a task with CLI words, including built-ins, aliases, nested tasks, defaults, and conversions.\n"
                    .. "Uses the loaded project task definitions without reloading .cmd.lua. Available after project loading completes.\n"
                    .. "Returns every original Lua value, including nils, without printing them; explicit task output is retained.\n"
                    .. "Task errors propagate. Lookup and argument errors raise tables with message and the CLI exit_code.\n"
                    .. "A group without run shows help and raises exit_code 2.",
                examples = [[Show help for the API documentation command:

    task("--help", "--api")

Delegate to another task and return its values:

    return task("build", "--release")]],
            }),
        http = func({ { "options", S.union { alternatives = { S.string(), S.ref { name = "HttpOptions" } } } } }, { { "response", S.ref { name = "HttpResponse" } } }, { description = "HTTPS requests; transport/filesystem failures raise. SSL_CERT_FILE selects a PEM trust bundle." }),
        exec = S.func { description = "Executes without a shell; returns the exit code and captured output.\nChecked nonzero exits raise a table with "
            .. "the child's exit_code and, unless effective stderr is inherited, a message.", signatures = {
            signature({ { "command", S.union { alternatives = { S.ref { name = "Command" }, S.ref { name = "ExecCommand" } } } } },
                { { "result", S.ref { name = "ExecResult" } } }),
            signature({ { "program", S.string() }, { "arguments", S.string(), arity = "*" } }, { { "result", S.ref { name = "ExecResult" } } }),
        } },
        spawn = S.func { description = "Starts without a shell and returns immediately. Startup failures raise; captured output is drained automatically.", signatures = {
            signature({ { "command", S.union { alternatives = { S.ref { name = "Command" }, S.ref { name = "SpawnCommand" } } } } },
                { { "process", S.ref { name = "Process" } } }),
            signature({ { "program", S.string() }, { "arguments", S.string(), arity = "*" } }, { { "process", S.ref { name = "Process" } } }),
        } },
        sha256 = S.func { description = "Hash bytes or a file; returns lowercase hexadecimal.\nWith no arguments, returns a chunk consumer: call with "
            .. "one string to update or no arguments to finish.\nCompletion releases native resources and returns the digest; "
            .. "further calls raise.\nAbandoned consumers release their native state when garbage-collected.", signatures = {
            signature({ { "options", S.ref { name = "Sha256Options" } } }, { { "digest", S.string() } }),
            signature({}, { { "consumer", S.ref { name = "ChunkConsumer" } } }),
        } },
        extract = S.func { signatures = {
            signature({ { "options", S.ref { name = "ExtractOptions" } } }, { { "extracted", S.boolean() } }),
            signature({ { "path", S.string() }, { "to", S.optional { schema = S.string() }, arity = "?" } }, { { "extracted", S.boolean() } }),
        }, description = "Accepts (path, to?) or an options table. Extracts ZIP, tar, tar.gz, or tar.xz.\nReturns true on success, false when skipped. Missing parents are created and may remain after failure." },
        fetch = S.func { signatures = {
            signature({ { "options", S.ref { name = "FetchOptions" } } }, { { "path", S.string() } }),
            signature({ { "url", S.string() }, { "sha256", S.string() } }, { { "path", S.string() } }),
        }, description = "Accepts (url, sha256) or an options table. Returns an absolute download or prepared path.\nDownloads are verified; cache hits are trusted.",
            examples = [[Download and extract an archive into the prepared cache. extract creates output:

    local sdk = fetch {
        url = url,
        sha256 = hash,
        prepare = function(input, output)
            extract { path = input, to = output, strip_components = 1 }
        end
    }
]],
        },
        plugin = func({ { "url", S.string() }, { "sha256", S.string() } }, { { "values", S.any(), arity = "*" } },
            { description = "Executes a source SHA-256 once and caches all values returned by its chunk for this run.\nThe URL locates the "
                .. "source and is not part of its identity.\nReturns every value returned by the plugin chunk." }),
    } },
}

---@class dotcmd.Api: dotcmd.schema.Registry
---@field show fun(name?: string) Print the API index or documentation for a global, named type, or member.
---@cast api dotcmd.Api

---Write API documentation through format; predicates and runtime functions are never called.
---@param name? string Global, named type, or dotted member path.
function api.show(name)
    local format = require("dotcmd.format")
    local output = format.writer(io.stdout)
    local function sorted_keys(value)
        local result = {}
        for key in pairs(value) do result[#result + 1] = key end
        table.sort(result, function(a, b)
            if type(a) ~= type(b) then return type(a) < type(b) end
            return a < b
        end)
        return result
    end
    local function resolve(value)
        while value.type == "ref" do value = api.definitions[value.name] end
        return value
    end
    local function fields(value)
        value = resolve(value)
        if not value.extends then return value.fields end
        local inherited, result = fields(value.extends), {}
        for key, field in pairs(inherited) do result[key] = field end
        if #value.fields > 0 then for i = 1, #result do result[i] = nil end end
        for key, field in pairs(value.fields) do result[key] = field end
        return result
    end
    local function property(value, key)
        while true do
            if value[key] ~= nil then return value[key] end
            if value.type ~= "ref" then return nil end
            value = api.definitions[value.name]
        end
    end
    local function description(value)
        local text = property(value, "description")
        if text then return text end
        value = resolve(value)
        if value.type == "union" then
            local candidate
            for _, alternative in ipairs(value.alternatives) do
                if alternative.type ~= "nil" then
                    if candidate then return nil end
                    candidate = alternative
                end
            end
            return candidate and description(candidate)
        end
        if value.type == "table" and #value.fields == 1 then return description(value.fields[1][2]) end
    end
    local function nullable(value)
        value = resolve(value)
        if value.type == "nil" or value.type == "any" then return true end
        if value.type == "literal" then return value.value == nil end
        if value.type == "union" then
            for _, alternative in ipairs(value.alternatives) do if nullable(alternative) then return true end end
        end
        return false
    end
    local function optional(value)
        return property(value, "default") ~= nil or nullable(value)
    end
    local function literal(value)
        return type(value) == "string" and string.format("%q", value) or tostring(value)
    end
    local type_text, call_signatures
    local function sequences(value)
        value = resolve(value)
        if value.type ~= "alt" then return { fields(value) } end
        local result = {}
        for _, branch in ipairs(value.alternatives) do
            for _, sequence in ipairs(sequences(branch[2])) do result[#result + 1] = sequence end
        end
        return result
    end
    local function sequence_text(sequence, returns)
        local result = {}
        for _, entry in ipairs(sequence) do
            local arity = entry.arity or "1"
            local text = type_text(entry[2], not returns and arity == "?")
            if returns then
                if arity == "?" and not nullable(entry[2]) then text = text .. "|nil" end
                if arity == "*" then text = text .. "..."
                elseif arity == "+" then text = text .. ", " .. text .. "..." end
            else
                local suffix = arity == "?" and "?" or arity == "*" and "..." or arity == "+" and "+" or ""
                text = entry[1] .. suffix .. ": " .. text
            end
            result[#result + 1] = text
        end
        return table.concat(result, ", ")
    end
    call_signatures = function(value, label)
        local result = {}
        for _, signature in ipairs(value.signatures) do
            for _, params in ipairs(sequences(signature.params)) do
                for _, returns in ipairs(sequences(signature.returns)) do
                    local text = sequence_text(returns, true)
                    result[#result + 1] = label .. "(" .. sequence_text(params, false) .. ")"
                        .. (text == "" and "" or " -> " .. text)
                end
            end
        end
        return result
    end
    type_text = function(value, omit_nil)
        local kind = value.type
        if kind == "ref" then return value.name end
        if kind == "nil" then return omit_nil and "" or "nil" end
        if kind == "literal" then return literal(value.value) end
        if kind == "file" then return "file handle" end
        if kind == "union" or kind == "alt" then
            local types = {}
            for _, alternative in ipairs(value.alternatives) do
                local text = type_text(kind == "alt" and alternative[2] or alternative, omit_nil)
                if text ~= "" then types[#types + 1] = text end
            end
            return table.concat(types, "|")
        end
        if kind == "map" then return "table<" .. type_text(value.key) .. ", " .. type_text(value.value) .. ">" end
        if kind == "function" then return table.concat(call_signatures(value, ""), " | ") end
        if kind == "table" then
            local declared, parts = fields(value), {}
            if #declared == 1 and declared[1].arity == "*" and #sorted_keys(declared) == 1 then
                local text = type_text(declared[1][2])
                return (text:find("|", 1, true) and ("(" .. text .. ")") or text) .. "[]"
            end
            for _, key in ipairs(sorted_keys(declared)) do
                local item = declared[key]
                if type(key) == "number" then
                    parts[#parts + 1] = "[" .. key .. ((item.arity == "*" or item.arity == "+") and "..." or "") .. "]: " .. type_text(item[2])
                else
                    parts[#parts + 1] = key .. (optional(item) and "?" or "") .. ": " .. type_text(item, true)
                end
            end
            return "{ " .. table.concat(parts, ", ") .. " }"
        end
        return kind
    end
    local function rows(title, entries, prefix)
        if #entries == 0 then return end
        prefix = prefix or ""
        local width = 0
        for _, row in ipairs(entries) do width = math.max(width, #row[1]) end
        output:write({ "\n", prefix, { bold = true, title }, ":\n" })
        local indent = prefix .. string.rep(" ", width + 4)
        for _, row in ipairs(entries) do
            local text, utility = row[2] or "", row[3]
            if utility ~= nil then
                output:write({ prefix, "  ", { bold = true, row[1] },
                    ":", { dim = true, " ", utility }, "\n" })
                if text ~= "" then
                    local description_indent = prefix .. "    "
                    output:write({ description_indent, text:gsub("\n", "\n" .. description_indent), "\n" })
                end
            else
                output:write({ prefix, "  ", { bold = true, row[1] }, string.rep(" ", width - #row[1] + 2),
                    text:gsub("\n", "\n" .. indent), "\n" })
            end
        end
    end
    if not name then
        output:write({ bold = true, "Lua API\n\n" })
        output:write({ description(api.schema), "\n" })
        local functions, tables = {}, {}
        for _, key in ipairs(sorted_keys(api.schema.fields)) do
            local value = api.schema.fields[key]
            local list = resolve(value).type == "function" and functions or tables
            list[#list + 1] = { key, (description(value) or ""):match("^[^\n]*") }
        end
        rows("Functions", functions)
        rows("Runtime tables", tables)
        rows("Configuration types", { { "Tasks", description(api.definitions.Tasks):match("^[^\n]*") } })
        output:flush()
        return
    end
    local path = {}
    for part in (name .. "."):gmatch("(.-)%.") do path[#path + 1] = part end
    local value = api.schema.fields[path[1]] or api.definitions[path[1]]
    if not value then
        local available = sorted_keys(api.schema.fields)
        for key in pairs(api.definitions) do available[#available + 1] = key end
        table.sort(available)
        error({ message = "unknown API entry " .. literal(path[1])
            .. "\nAvailable entries: " .. table.concat(available, ", "), exit_code = 2 })
    end
    for i = 2, #path do
        local parent = table.concat(path, ".", 1, i - 1)
        local shape = resolve(value)
        if shape.type ~= "table" then
            error({ message = "API entry " .. literal(parent) .. " has no declared members", exit_code = 2 })
        end
        local declared = fields(shape)
        value = declared[path[i]]
        if not value then
            local available = {}
            for _, key in ipairs(sorted_keys(declared)) do if type(key) == "string" then available[#available + 1] = key end end
            error({ message = "unknown API member " .. literal(table.concat(path, ".", 1, i))
                .. "\nAvailable members of " .. parent .. ": " .. table.concat(available, ", "), exit_code = 2 })
        end
    end
    local function field_rows(declared)
        local result = {}
        for _, key in ipairs(sorted_keys(declared)) do
            local item, label, notes = declared[key], key, nil
            if type(key) == "number" then
                local arity = item.arity or "1"
                label = "[" .. key .. ((arity == "*" or arity == "+") and "..." or "") .. "] " .. item[1]
                    .. (arity == "?" and "?" or "")
                notes = arity == "*" and "Zero or more values." or arity == "+" and "One or more values." or nil
                item = item[2]
            else label = label .. (optional(item) and "?" or "") end
            local text, default = description(item), property(item, "default")
            if default ~= nil then text = (text and (text .. " ") or "") .. "Default: " .. literal(default) .. "." end
            if notes then text = (text and (text .. " ") or "") .. notes end
            result[#result + 1] = { label, text or "", type_text(item, true) }
        end
        return result
    end
    local function show(label, declared, prefix)
        prefix = prefix or ""
        local body_indent = prefix == "" and "" or prefix .. "  "
        local item = resolve(declared)
        if item.type == "function" then
            for _, text in ipairs(call_signatures(item, label)) do
                output:write({ prefix, { bold = true, label }, " ", { dim = true, text:sub(#label + 1) }, "\n" })
            end
        else
            local declaration = ""
            if item.type ~= "table" then
                declaration = { dim = true, " ", type_text(item) }
            elseif item.extends then
                declaration = { dim = true, " (extends ", item.extends.name, ")" }
            end
            output:write({ prefix, { bold = true, label },
                declaration, "\n" })
        end
        local text = description(declared)
        if text then
            output:write({ prefix == "" and "\n" or "", text:gsub("[^\n]+", body_indent .. "%0"), "\n" })
        end
        if declared.type == "ref" and declared.description and item.description and item.description ~= text then
            output:write({ "\n", item.description:gsub("[^\n]+", body_indent .. "%0"), "\n" })
        end
        if item.type == "table" then rows("Fields", field_rows(item.fields), body_indent) end
        if item.type == "function" then
            local overloads, described = {}, false
            for i, signature in ipairs(item.signatures) do
                local entries = field_rows(fields(signature.params))
                overloads[i] = entries
                for _, row in ipairs(entries) do if row[2] ~= "" then described = true end end
            end
            if described then
                for i, entries in ipairs(overloads) do
                    local title = #item.signatures == 1 and "Arguments" or "Arguments (overload " .. i .. ")"
                    if #entries == 0 then
                        output:write({ "\n", body_indent, { bold = true, title }, ":\n",
                            body_indent, "  No arguments.\n" })
                    else
                        rows(title, entries, body_indent)
                    end
                end
            end
        end
        local examples = property(declared, "examples")
        if examples then
            output:write({ "\n", body_indent, { bold = true, "Examples:" }, "\n\n",
                examples:gsub("[^\n]+", body_indent .. "  %0"), "\n" })
        end
    end
    show(name, value)
    local referenced, seen = {}, { [name] = true }
    local root = value
    while root.type == "ref" do
        seen[root.name] = true
        root = api.definitions[root.name]
    end
    local function collect(item)
        if item.type == "ref" then
            if seen[item.name] then return end
            seen[item.name] = true
            referenced[item.name] = api.definitions[item.name]
            collect(referenced[item.name])
        elseif item.type == "table" then
            if item.extends then collect(item.extends) end
            for key, field in pairs(item.fields) do
                collect(type(key) == "number" and field[2] or field)
            end
        elseif item.type == "function" then
            for _, signature in ipairs(item.signatures) do
                collect(signature.params)
                collect(signature.returns)
            end
        elseif item.type == "map" then
            collect(item.key)
            collect(item.value)
        elseif item.type == "union" or item.type == "alt" then
            for _, alternative in ipairs(item.alternatives) do
                collect(item.type == "alt" and alternative[2] or alternative)
            end
        end
    end
    collect(root)
    local names = sorted_keys(referenced)
    if #names > 0 then
        output:write({ "\n", { bold = true, "Referenced types:" }, "\n" })
        for _, type_name in ipairs(names) do
            output:write("\n")
            show(type_name, referenced[type_name], "  ")
        end
    end
    output:flush()
end

return api

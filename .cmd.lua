local root = host.project_dir
local windows = host.os == "windows"
local suffix = windows and ".exe" or ""
local ninja = plugin(
    "https://raw.githubusercontent.com/dotcmdhq/plugins/de05a2fd460bce2c4b37134f805ba3f06ce01204/ninja.lua",
    "b48a925d29fd5944df4cb29cb9f098cd7f55f1a42fd3319ae4c838adb2978e0a") {
    version = "1.13.2",
    sha256 = {
        linux = {
            x64 = "5749cbc4e668273514150a80e387a957f933c6ed3f5f11e03fb30955e2bbead6",
            arm64 = "fd2cacc8050a7f12a16a2e48f9e06fca5c14fc4c2bee2babb67b58be17a607fc",
        },
        macos = {
            x64 = "c99048673aa765960a99cf10c6ddb9f1fad506099ff0a0e137ad8960a88f321b",
            arm64 = "c99048673aa765960a99cf10c6ddb9f1fad506099ff0a0e137ad8960a88f321b",
        },
        windows = {
            x64 = "07fc8261b42b20e71d1720b39068c2e14ffcee6396b76fb7a795fb460b78dc65",
            arm64 = "e52f0bdef9dfb1003229dbd6508a508c4073fd017247002adc66e5e806cb0391",
        },
    },
}

local function build(mode)
    mode = mode or "release"
    local output = root .. "/target/" .. mode
    local env = {}

    -- Supply the build tools.

    local cmake_config = {
        version = "4.4.3",
        sha256 = {
            linux = {
                x64 = "d6c83076c575bc00b823522ac974bda66d0af05d6ddc30e739c12385cf32c6cc",
                arm64 = "2efc974dbd63b4444c0e8494b92f2e80c2d7e635b4b80eac2916985ddd8f72a6",
            },
            macos = {
                x64 = "217a8c7bef7b70e8f9dc3748e625b92b19732b3eb26f6d99f23ef3f2768a8665",
                arm64 = "217a8c7bef7b70e8f9dc3748e625b92b19732b3eb26f6d99f23ef3f2768a8665",
            },
            windows = {
                x64 = "4d52ebab7193a698651639ed80d8d04fd903358843572cf44c7fd234cb7c26ab",
                arm64 = "7b410ddd00e24c7250eec7452da2348a4a70437aa87e9cda0a20d6a85662fcff",
            },
        },
        name = {
            linux = { x64 = "linux-x86_64", arm64 = "linux-aarch64" },
            macos = { x64 = "macos10.10-universal", arm64 = "macos10.10-universal" },
            windows = { x64 = "windows-x86_64", arm64 = "windows-arm64" },
        },
    }
    local cmake_name = "cmake-" .. cmake_config.version .. "-" .. cmake_config.name[host.os][host.arch]
    local cmake_dir = fetch {
        url = "https://github.com/Kitware/CMake/releases/download/v" .. cmake_config.version
            .. "/" .. cmake_name .. (windows and ".zip" or ".tar.gz"),
        sha256 = cmake_config.sha256[host.os][host.arch],
        prepare = function(input, output)
            extract { path = input, to = output, strip_components = 1 }
        end,
    }
    local cmake = cmake_dir .. (host.os == "macos" and "/CMake.app/Contents/bin/cmake" or "/bin/cmake" .. suffix)
    local args = {
        cmake,
        "-S",
        windows and root:gsub("\\", "/") or root,
        "-B",
        windows and output:gsub("\\", "/") or output,
        "-G",
        "Ninja",
        "-DCMAKE_MAKE_PROGRAM=" .. (windows and ninja:gsub("\\", "/") or ninja),
        "-DCMAKE_BUILD_TYPE=" .. (mode == "debug" and "Debug" or "MinSizeRel"),
        "-DDOTCMD_VERSION=" .. (os.getenv("DOTCMD_VERSION") or "dev"),
        cwd = root,
        env = env,
    }

    -- Supply the compiler. CMake uses Apple's installed toolchain on macOS.

    local arch = host.arch == "x64" and "x86_64" or "aarch64"
    if host.os == "linux" then
        local zig_config = {
            version = "0.16.0",
            sha256 = {
                x64 = "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00",
                arm64 = "ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17",
            },
        }
        local name = "zig-" .. arch .. "-linux-" .. zig_config.version
        local toolchain = fetch {
            url = "https://ziglang.org/download/" .. zig_config.version .. "/" .. name .. ".tar.xz",
            sha256 = zig_config.sha256[host.arch],
            prepare = function(input, output)
                extract { path = input, to = output, strip_components = 1 }
            end,
        }
        env.ZIG_GLOBAL_CACHE_DIR = host.cache_dir .. "/zig"
        env.ZIG_LOCAL_CACHE_DIR = output .. "/zig"
        args[#args + 1] = "-DCMAKE_TOOLCHAIN_FILE=" .. root .. "/cmake/zig.cmake"
        args[#args + 1] = "-DDOTCMD_ZIG=" .. toolchain .. "/zig"
        args[#args + 1] = "-DDOTCMD_ZIG_TARGET=" .. arch .. "-linux-musl"
    elseif windows then
        local mingw_config = {
            version = "20251216",
            sha256 = {
                x64 = "2d96a4b758f7f8deaec5065833fe025aa53cfc5f704d0524002510984da0ccf4",
                arm64 = "60c06bd255feb2ef1eb6fce7ee6b307d8f78ee6639660f49861c7c10a8a86164",
            },
        }
        local name = "llvm-mingw-" .. mingw_config.version .. "-ucrt-" .. arch
        local toolchain = fetch {
            url = "https://github.com/mstorsjo/llvm-mingw/releases/download/"
                .. mingw_config.version .. "/" .. name .. ".zip",
            sha256 = mingw_config.sha256[host.arch],
            prepare = function(input, output)
                extract { path = input, to = output, strip_components = 1 }
            end,
        }
        args[#args + 1] = "-DCMAKE_C_COMPILER=" ..
            toolchain:gsub("\\", "/") .. "/bin/" .. arch .. "-w64-mingw32-clang.exe"
        args[#args + 1] = "-DCMAKE_CXX_COMPILER=" ..
            toolchain:gsub("\\", "/") .. "/bin/" .. arch .. "-w64-mingw32-clang++.exe"
        args[#args + 1] = "-DCMAKE_RC_COMPILER=" ..
            toolchain:gsub("\\", "/") .. "/bin/" .. arch .. "-w64-mingw32-windres.exe"
    end

    -- Configure and build locally; CMake owns dependencies and incremental builds.

    exec(args)
    exec { cmake, "--build", output, "--parallel", "4", cwd = root, env = env }
    return cmake
end

-- GitHub transport shared by both kinds of version source. Resolve credentials
-- lazily, once per invocation; ordinary builds and --help do not look them up.
local github_token, github_auth_resolved
local function github_headers(accept)
    if not github_auth_resolved then
        for _, name in ipairs({ "GH_TOKEN", "GITHUB_TOKEN" }) do
            local value = os.getenv(name)
            if value and value ~= "" then
                github_token = value; break
            end
        end
        if not github_token then
            local ok, result = pcall(exec, {
                "gh",
                "auth",
                "token",
                "--hostname",
                "github.com",
                stdin = "discard",
                stdout = "capture",
                stderr = "capture",
                env = { GH_PROMPT_DISABLED = "1", GH_NO_UPDATE_NOTIFIER = "1" },
            })
            if ok then github_token = result.stdout:match("%S+") end
        end
        github_auth_resolved = true
    end
    local headers = {
        Accept = accept or "application/vnd.github+json",
        ["X-GitHub-Api-Version"] = "2022-11-28",
    }
    if github_token then headers.Authorization = "Bearer " .. github_token end
    return headers
end

local function github(path, accept)
    local response = http {
        url = "https://api.github.com/" .. path,
        headers = github_headers(accept),
    }
    if accept then return response.body end
    return json.decode(response.body)
end

local function github_asset_hashes(release, names, max_download_bytes)
    assert(max_download_bytes >= 0, "--max-download-mb must not be negative")
    local assets, hashes, missing, download_size = {}, {}, {}, 0
    for _, asset in ipairs(release.assets) do assets[asset.name] = asset end
    for _, name in ipairs(names) do
        local asset = assert(assets[name], "GitHub release has no asset named " .. name)
        local digest = asset.digest and asset.digest:match("^sha256:(%x+)$")
        if digest then
            hashes[name] = digest
        elseif not missing[name] then
            missing[name] = true
            download_size = download_size + asset.size
        end
    end
    assert(download_size <= max_download_bytes,
        ("Assets without SHA-256 digests total %.3f MB (%d bytes); "
            .. "exceeds --max-download-mb=%.0f (%d bytes)")
        :format(download_size / 1000000, download_size,
            max_download_bytes / 1000000, max_download_bytes))

    local temp_dir = host.cache_dir .. "/versions"
    fs.mkdir(temp_dir)
    for _, name in ipairs(names) do
        if missing[name] then
            local asset = assets[name]
            local temp = temp_dir .. "/.tmp-" .. ("%016x%016x"):format(math.random(0), math.random(0))
            local cleanup <close> = setmetatable({}, {
                __close = function() fs.remove(temp) end,
            })
            http {
                url = asset.url,
                headers = github_headers("application/octet-stream"),
                to = temp,
            }
            hashes[name] = sha256 { path = temp }
            missing[name] = nil
        end
    end
    return hashes
end

local function url_encode(value)
    return (value:gsub("[^%w%-%._~]", function(character)
        return ("%%%02X"):format(character:byte())
    end))
end

local function github_pages(path)
    local result, page = {}, 1
    local separator = path:find("?", 1, true) and "&" or "?"
    while true do
        local items = github(path .. separator .. "per_page=100&page=" .. page)
        for _, item in ipairs(items) do result[#result + 1] = item end
        if #items < 100 then return result end
        page = page + 1
    end
end

-- Sources return records with version, identity, date, description and url.
-- Source-specific fields are available to the caller's Lua-output callback.
local function github_releases(repo, prefix)
    prefix = prefix or ""
    local path = "repos/" .. repo .. "/releases"
    local function record(release)
        return {
            version = release.tag_name:sub(#prefix + 1),
            identity = release.tag_name:sub(#prefix + 1),
            date = release.published_at,
            description = release.name or release.tag_name,
            url = release.html_url,
            release = release,
        }
    end
    return {
        url = "https://github.com/" .. repo .. "/releases",
        list = function()
            local result = {}
            for _, release in ipairs(github_pages(path)) do
                if not release.draft and release.tag_name:sub(1, #prefix) == prefix then
                    result[#result + 1] = record(release)
                end
            end
            return result
        end,
        get = function(version)
            if version == "latest" then return record(github(path .. "/latest")) end
            if version:sub(1, #prefix) ~= prefix then version = prefix .. version end
            return record(github(path .. "/tags/" .. url_encode(version)))
        end,
    }
end

local function github_file(repo, file, branch)
    local path = "repos/" .. repo
    local encoded_file = file:gsub("[^/]+", url_encode)
    local history = path .. "/commits?sha=" .. url_encode(branch) .. "&path=" .. url_encode(file)
    local function record(commit)
        return {
            version = commit.sha,
            date = commit.commit.committer.date,
            description = commit.commit.message:match("[^\n]+"),
            url = commit.html_url,
        }
    end
    return {
        url = "https://github.com/" .. repo .. "/commits/" .. url_encode(branch) .. "/" .. encoded_file,
        list = function()
            local result = {}
            for _, commit in ipairs(github_pages(history)) do result[#result + 1] = record(commit) end
            return result
        end,
        get = function(ref)
            local commit
            if ref == "latest" then
                commit = assert(github(history .. "&per_page=1")[1], "No history for " .. file)
            else
                commit = github(path .. "/commits/" .. url_encode(ref))
            end
            local result = record(commit)
            local bytes = github(path .. "/contents/" .. encoded_file .. "?ref=" .. commit.sha,
                "application/vnd.github.raw+json")
            result.sha256 = sha256 { bytes = bytes }
            result.identity = result.sha256
            result.download_url = "https://raw.githubusercontent.com/" .. repo .. "/" .. commit.sha
                .. "/" .. encoded_file
            return result
        end,
    }
end

local function versions(source, current, show, show_opts)
    local show_command = {
        description = "Print replacement Lua for a version (default: latest)",
        args = { {
            "version",
            type = "string",
            arity = "?",
            default = "latest",
            description = "Version, file commit/tag/branch, or latest"
        } },
    }
    if show_opts then
        show_command.opts = show_opts
        show_command.run = function(opts, version) return show(source.get(version), opts) end
    else
        show_command.run = function(version) return show(source.get(version)) end
    end
    return {
        description = "Show version source and current/latest status",
        run = function()
            local latest = source.get("latest")
            return table.concat({
                source.url,
                "Current: " .. current.version,
                "Latest:  " .. latest.version,
                current.identity == latest.identity and "Up to date" or "Update available",
            }, "\n")
        end,
        commands = {
            list = {
                description = "List available versions with descriptions and links",
                args = {},
                run = function()
                    local lines = {}
                    for _, item in ipairs(source.list()) do
                        lines[#lines + 1] = item.version
                            .. (item.version == current.version and " (current)" or "")
                            .. "  " .. item.date .. "  " .. item.description
                        lines[#lines + 1] = "  " .. item.url
                    end
                    return table.concat(lines, "\n")
                end,
            },
            show = show_command,
        },
    }
end

---@type dotcmd.Commands
return {
    ninja = {
        description = "Inspect Ninja releases on GitHub",
        commands = {
            versions = versions(github_releases("ninja-build/ninja", "v"),
                -- Prototype input; a real plugin already has its configured version.
                { version = "1.13.2", identity = "1.13.2" },
                function(item, opts)
                    local assets, names = {}, {}
                    for _, asset in ipairs(item.release.assets) do assets[asset.name] = true end
                    for _, name in ipairs({ "ninja-linux.zip", "ninja-linux-aarch64.zip",
                        "ninja-mac.zip", "ninja-win.zip", "ninja-winarm64.zip" }) do
                        if assets[name] then names[#names + 1] = name end
                    end
                    assert(#names > 0, "GitHub release has no supported Ninja assets")
                    local hashes = github_asset_hashes(item.release, names,
                        opts.max_download_mb * 1000000)
                    local result = { version = item.version, sha256 = {} }
                    if hashes["ninja-linux.zip"] then
                        result.sha256.linux = { x64 = hashes["ninja-linux.zip"] }
                        if hashes["ninja-linux-aarch64.zip"] then
                            result.sha256.linux.arm64 = hashes["ninja-linux-aarch64.zip"]
                        end
                    end
                    if hashes["ninja-mac.zip"] then
                        result.sha256.macos = {
                            x64 = hashes["ninja-mac.zip"], arm64 = hashes["ninja-mac.zip"],
                        }
                    end
                    if hashes["ninja-win.zip"] then
                        result.sha256.windows = { x64 = hashes["ninja-win.zip"] }
                        if hashes["ninja-winarm64.zip"] then
                            result.sha256.windows.arm64 = hashes["ninja-winarm64.zip"]
                        end
                    end
                    return result
                end,
                {
                    max_download_mb = {
                        type = "integer",
                        default = 100,
                        description = "Maximum total MB to download when GitHub provides no SHA-256 digest"
                    },
                }),
            plugin = {
                description = "Inspect revisions of the Ninja plugin",
                commands = {
                    versions = versions(github_file("dotcmdhq/plugins", "ninja.lua", "main"),
                        {
                            -- Prototype input until plugin self-identity is settled.
                            version = "a66620bb164770f910a76792f3d5c5307ccd8f74",
                            identity = "6b060dd5fda87e5e33853f5811cada2cbf2e80dde91055d96d2423baae8fe35a",
                        },
                        function(item)
                            return ("%q,\n%q,"):format(item.download_url, item.sha256)
                        end),
                },
            },
        },
    },
    build = {
        description = [[Build dotcmd

Downloads the required build tools and builds into target/<mode>.
]],
        args = { {
            "mode",
            arity = "?",
            type = { "debug", "release" },
            default = "release",
            description = "Build mode"
        } },
        run = function(mode)
            build(mode)
        end,
    },
    ["local"] = {
        description = "Build and run the local dotcmd executable",
        run = function(...)
            build()
            exec { root .. "/target/release/dotcmd" .. suffix,
                "--launcher", root .. "/.cmd", ... }
        end,
    },
    test = {
        description = "Build and test .cmd in fixture projects",
        args = {},
        run = function()
            local cmake = build()
            exec { cmake, "--build", root .. "/target/release", "--target", "test",
                cwd = root, env = { CTEST_OUTPUT_ON_FAILURE = "1" } }
        end,
    },
}

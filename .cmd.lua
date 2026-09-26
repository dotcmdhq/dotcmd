local root = host.project_dir
local windows = host.os == "windows"
local suffix = windows and ".exe" or ""
local ninja = plugin(
    "https://raw.githubusercontent.com/dotcmdhq/plugins/a66620bb164770f910a76792f3d5c5307ccd8f74/ninja.lua",
    "6b060dd5fda87e5e33853f5811cada2cbf2e80dde91055d96d2423baae8fe35a",
    {
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
)

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
        cmake, "-S", windows and root:gsub("\\", "/") or root,
        "-B", windows and output:gsub("\\", "/") or output, "-G", "Ninja",
        "-DCMAKE_MAKE_PROGRAM=" .. (windows and ninja:gsub("\\", "/") or ninja),
        "-DCMAKE_BUILD_TYPE=" .. (mode == "debug" and "Debug" or "MinSizeRel"),
        "-DDOTCMD_VERSION=" .. (os.getenv("DOTCMD_VERSION") or "dev"),
        cwd = root, env = env,
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
        args[#args + 1] = "-DCMAKE_C_COMPILER=" .. toolchain:gsub("\\", "/") .. "/bin/" .. arch .. "-w64-mingw32-clang.exe"
        args[#args + 1] = "-DCMAKE_CXX_COMPILER=" .. toolchain:gsub("\\", "/") .. "/bin/" .. arch .. "-w64-mingw32-clang++.exe"
        args[#args + 1] = "-DCMAKE_RC_COMPILER=" .. toolchain:gsub("\\", "/") .. "/bin/" .. arch .. "-w64-mingw32-windres.exe"
    end

    -- Configure and build locally; CMake owns dependencies and incremental builds.

    exec(args)
    exec { cmake, "--build", output, "--parallel", "4", cwd = root, env = env }
    return cmake
end

local function ninja_github(path)
    local response = http {
        url = "https://api.github.com/repos/ninja-build/ninja" .. path,
        headers = {
            Accept = "application/vnd.github+json",
            ["X-GitHub-Api-Version"] = "2022-11-28",
        },
    }
    return json.decode(response.body)
end

---@type dotcmd.Commands
return {
    ninja = {
        description = "Inspect Ninja releases on GitHub",
        commands = {
            versions = {
                description = "List published Ninja release versions",
                args = {},
                run = function()
                    local releases = ninja_github("/releases?per_page=100")
                    for _, release in ipairs(releases) do
                        local version = release.tag_name:match("^v(.+)$")
                        if version then print(version) end
                    end
                end,
            },
            config = {
                description = "Print the plugin configuration for a Ninja release",
                args = { { "version", description = "Ninja release version" } },
                run = function(input)
                    local version = input:match("^v?([%w._+-]+)$")
                    assert(version, "invalid Ninja release version")
                    local release = ninja_github("/releases/tags/v" .. version)
                    local hashes = {}
                    for _, asset in ipairs(release.assets) do
                        local sha256 = asset.digest and asset.digest:match("^sha256:(%x+)$")
                        if sha256 then hashes[asset.name] = sha256 end
                    end
                    local function hash(name)
                        return assert(hashes[name],
                            "GitHub provides no SHA-256 digest for " .. name .. " in Ninja " .. version)
                    end
                    local linux_x64 = hash("ninja-linux.zip")
                    local linux_arm64 = hash("ninja-linux-aarch64.zip")
                    local macos = hash("ninja-mac.zip")
                    local windows_x64 = hash("ninja-win.zip")
                    local windows_arm64 = hash("ninja-winarm64.zip")

                    return {
                        version = version,
                        sha256 = {
                            linux = { x64 = linux_x64, arm64 = linux_arm64 },
                            macos = { x64 = macos, arm64 = macos },
                            windows = { x64 = windows_x64, arm64 = windows_arm64 },
                        },
                    }
                end,
            },
        },
    },
    build = {
        description = [[Build dotcmd

Downloads the required build tools and builds into target/<mode>.
]],
        args = { { "mode", arity = "?", type = { "debug", "release" }, default = "release",
            description = "Build mode" } },
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

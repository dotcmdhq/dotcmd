---@type dotcmd.Env|_G
local _ENV = _ENV

local root = host.project_dir
local windows = host.os == 'windows'
local suffix = windows and '.exe' or ''

local function build(mode)
    mode = mode or 'release'
    local platform = host.os .. '-' .. host.arch
    local output = root .. '/target/' .. mode
    local env = {}

    -- Supply the build tools.

    local cmake_config = {
        version = '4.4.3',
        ['linux-x64'] = {
            name = 'linux-x86_64',
            sha256 = 'd6c83076c575bc00b823522ac974bda66d0af05d6ddc30e739c12385cf32c6cc'
        },
        ['linux-arm64'] = {
            name = 'linux-aarch64',
            sha256 = '2efc974dbd63b4444c0e8494b92f2e80c2d7e635b4b80eac2916985ddd8f72a6'
        },
        ['macos-x64'] = {
            name = 'macos10.10-universal',
            sha256 = '217a8c7bef7b70e8f9dc3748e625b92b19732b3eb26f6d99f23ef3f2768a8665'
        },
        ['macos-arm64'] = {
            name = 'macos10.10-universal',
            sha256 = '217a8c7bef7b70e8f9dc3748e625b92b19732b3eb26f6d99f23ef3f2768a8665'
        },
        ['windows-x64'] = {
            name = 'windows-x86_64',
            sha256 = '4d52ebab7193a698651639ed80d8d04fd903358843572cf44c7fd234cb7c26ab'
        },
        ['windows-arm64'] = {
            name = 'windows-arm64',
            sha256 = '7b410ddd00e24c7250eec7452da2348a4a70437aa87e9cda0a20d6a85662fcff'
        },
    }
    local cmake_name = 'cmake-' .. cmake_config.version .. '-' .. cmake_config[platform].name
    local cmake_dir = cached {
        url = 'https://github.com/Kitware/CMake/releases/download/v' .. cmake_config.version
            .. '/' .. cmake_name .. (windows and '.zip' or '.tar.gz'),
        sha256 = cmake_config[platform].sha256, extract = { strip_components = 1 },
    }
    local cmake = cmake_dir .. (host.os == 'macos' and '/CMake.app/Contents/bin/cmake' or '/bin/cmake' .. suffix)
    local ninja_config = {
        version = '1.13.2',
        ['linux-x64'] = {
            name = 'linux',
            sha256 = '5749cbc4e668273514150a80e387a957f933c6ed3f5f11e03fb30955e2bbead6'
        },
        ['linux-arm64'] = {
            name = 'linux-aarch64',
            sha256 = 'fd2cacc8050a7f12a16a2e48f9e06fca5c14fc4c2bee2babb67b58be17a607fc'
        },
        ['macos-x64'] = {
            name = 'mac',
            sha256 = 'c99048673aa765960a99cf10c6ddb9f1fad506099ff0a0e137ad8960a88f321b'
        },
        ['macos-arm64'] = {
            name = 'mac',
            sha256 = 'c99048673aa765960a99cf10c6ddb9f1fad506099ff0a0e137ad8960a88f321b'
        },
        ['windows-x64'] = {
            name = 'win',
            sha256 = '07fc8261b42b20e71d1720b39068c2e14ffcee6396b76fb7a795fb460b78dc65'
        },
        ['windows-arm64'] = {
            name = 'winarm64',
            sha256 = 'e52f0bdef9dfb1003229dbd6508a508c4073fd017247002adc66e5e806cb0391'
        },
    }
    local ninja_dir = cached {
        url = 'https://github.com/ninja-build/ninja/releases/download/v' .. ninja_config.version
            .. '/ninja-' .. ninja_config[platform].name .. '.zip',
        sha256 = ninja_config[platform].sha256, extract = true,
    }
    local ninja = ninja_dir .. '/ninja' .. suffix
    local args = {
        cmake, '-S', root, '-B', output, '-G', 'Ninja',
        '-DCMAKE_MAKE_PROGRAM=' .. ninja,
        '-DCMAKE_BUILD_TYPE=' .. (mode == 'debug' and 'Debug' or 'MinSizeRel'),
        '-DDOTCMD_VERSION=' .. (os.getenv('DOTCMD_VERSION') or 'dev'),
        cwd = root, env = env, check = true,
    }

    -- Supply the compiler. CMake uses Apple's installed toolchain on macOS.

    local arch = host.arch == 'x64' and 'x86_64' or 'aarch64'
    if host.os == 'linux' then
        local zig_config = {
            version = '0.16.0',
            sha256 = {
                x64 = '70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00',
                arm64 = 'ea4b09bfb22ec6f6c6ceac57ab63efb6b46e17ab08d21f69f3a48b38e1534f17',
            },
        }
        local name = 'zig-' .. arch .. '-linux-' .. zig_config.version
        local toolchain = cached {
            url = 'https://ziglang.org/download/' .. zig_config.version .. '/' .. name .. '.tar.xz',
            sha256 = zig_config.sha256[host.arch], extract = { strip_components = 1 },
        }
        env.ZIG_GLOBAL_CACHE_DIR = host.cache_dir .. '/zig'
        env.ZIG_LOCAL_CACHE_DIR = output .. '/zig'
        args[#args + 1] = '-DCMAKE_TOOLCHAIN_FILE=' .. root .. '/cmake/zig.cmake'
        args[#args + 1] = '-DDOTCMD_ZIG=' .. toolchain .. '/zig'
        args[#args + 1] = '-DDOTCMD_ZIG_TARGET=' .. arch .. '-linux-musl'
    elseif windows then
        local mingw_config = {
            version = '20251216',
            sha256 = {
                x64 = '2d96a4b758f7f8deaec5065833fe025aa53cfc5f704d0524002510984da0ccf4',
                arm64 = '60c06bd255feb2ef1eb6fce7ee6b307d8f78ee6639660f49861c7c10a8a86164',
            },
        }
        local name = 'llvm-mingw-' .. mingw_config.version .. '-ucrt-' .. arch
        local toolchain = cached {
            url = 'https://github.com/mstorsjo/llvm-mingw/releases/download/'
                .. mingw_config.version .. '/' .. name .. '.zip',
            sha256 = mingw_config.sha256[host.arch], extract = { strip_components = 1 },
        }
        args[#args + 1] = '-DCMAKE_C_COMPILER=' .. toolchain .. '/bin/' .. arch .. '-w64-mingw32-clang.exe'
        args[#args + 1] = '-DCMAKE_CXX_COMPILER=' .. toolchain .. '/bin/' .. arch .. '-w64-mingw32-clang++.exe'
        args[#args + 1] = '-DCMAKE_RC_COMPILER=' .. toolchain .. '/bin/' .. arch .. '-w64-mingw32-windres.exe'
    end

    -- Configure and build locally; CMake owns dependencies and incremental builds.

    if windows then
        for i = 2, #args do args[i] = args[i]:gsub('\\', '/') end
    end
    exec(args)
    exec { cmake, '--build', output, '--parallel', '4', cwd = root, env = env, check = true }
    return cmake
end

return {
    build = {
        description = 'Build dotcmd (release by default; --debug for debug)',
        run = function(mode)
            assert(mode == nil or mode == '--debug', 'Usage: .cmd build [--debug]')
            build(mode and 'debug' or 'release')
        end,
    },
    ['local'] = {
        description = 'Build and run the local dotcmd executable',
        run = function(...)
            build()
            return exec(root .. '/target/release/dotcmd' .. suffix, '--launcher', root .. '/.cmd', ...).code
        end,
    },
    test = {
        description = 'Build and test .cmd in fixture projects',
        run = function()
            local cmake = build()
            return exec { cmake, '--build', root .. '/target/release', '--target', 'test',
                cwd = root, env = { CTEST_OUTPUT_ON_FAILURE = '1' } }.code
        end,
    },
}

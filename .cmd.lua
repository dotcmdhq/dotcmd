---@type dotcmd.Env|_G
local _ENV = _ENV

local root = host.project_dir
local windows = host.os == 'windows'
local suffix = windows and '.exe' or ''
local binary = root .. '/target/release/dotcmd' .. suffix

local function read(path)
    local file <close> = assert(io.open(path, 'rb'))
    return assert(file:read('a'))
end

local function write(path, bytes)
    local file <close> = assert(io.open(path, 'wb'))
    assert(file:write(bytes))
end

local function append(to, ...)
    for _, values in ipairs({ ... }) do
        for _, value in ipairs(values) do to[#to + 1] = value end
    end
    return to
end

local function files(directory)
    local paths = {}
    for name in fs.list(directory) do
        local path = directory .. '/' .. name
        if fs.stat(path).type == 'directory' then
            append(paths, files(path))
        else
            paths[#paths + 1] = path
        end
    end
    table.sort(paths)
    return paths
end

local function build(mode)
    -- Select the compiler and platform options.

    mode = mode or 'release'
    local version = os.getenv('DOTCMD_VERSION') or 'dev'
    local platform = host.os .. '-' .. host.arch
    local arch = host.arch == 'x64' and 'x86_64' or 'aarch64'
    local cache = host.cache_dir
    local env = {}

    local cc, windres, sdk
    local cmake_options = { '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=MinSizeRel',
        '-DCMAKE_C_FLAGS=-ffunction-sections -fdata-sections', '-DBUILD_SHARED_LIBS=OFF', '-DBUILD_TESTING=OFF' }
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
            sha256 = zig_config.sha256[host.arch],
            extract = { strip_components = 1 },
        }
        local zig = toolchain .. '/zig'
        env.ZIG_GLOBAL_CACHE_DIR = cache .. '/zig'
        env.ZIG_LOCAL_CACHE_DIR = cache .. '/zig-local'
        cc = { zig, 'cc', '-target', arch .. '-linux-musl', '-mcpu=baseline' }
        append(cmake_options, { '-DCMAKE_C_COMPILER=' .. table.concat(cc, ';'),
            '-DCMAKE_ASM_COMPILER=' .. table.concat(cc, ';'), '-DCMAKE_AR=' .. zig,
            '-DCMAKE_C_ARCHIVE_CREATE=<CMAKE_AR> ar qc <TARGET> <LINK_FLAGS> <OBJECTS>',
            '-DCMAKE_C_ARCHIVE_APPEND=<CMAKE_AR> ar q <TARGET> <LINK_FLAGS> <OBJECTS>',
            '-DCMAKE_C_ARCHIVE_FINISH=<CMAKE_AR> ar s <TARGET>',
            '-DCMAKE_TRY_COMPILE_PLATFORM_VARIABLES=CMAKE_C_ARCHIVE_CREATE;CMAKE_C_ARCHIVE_APPEND;CMAKE_C_ARCHIVE_FINISH',
            '-DCMAKE_EXE_LINKER_FLAGS=-static' })
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
            sha256 = mingw_config.sha256[host.arch],
            extract = { strip_components = 1 },
        }
        cc = { toolchain .. '/bin/' .. arch .. '-w64-mingw32-clang.exe' }
        windres = toolchain .. '/bin/' .. arch .. '-w64-mingw32-windres.exe'
        append(cmake_options, { '-DCMAKE_C_COMPILER=' .. cc[1], '-DCMAKE_RC_COMPILER=' .. windres,
            '-DCMAKE_EXE_LINKER_FLAGS=-static' })
    else
        local macos_min_version = '11.0'
        sdk = exec { 'xcrun', '--sdk', 'macosx', '--show-sdk-path',
            cwd = root, env = env, check = true, stdout = 'capture' }.stdout:gsub('%s+$', '')
        local compiler = exec { 'xcrun', '--sdk', 'macosx', '--find', 'clang',
            cwd = root, env = env, check = true, stdout = 'capture' }.stdout:gsub('%s+$', '')
        cc = { compiler, '-isysroot', sdk, '-mmacosx-version-min=' .. macos_min_version }
        append(cmake_options, { '-DCMAKE_C_COMPILER=' .. compiler, '-DCMAKE_OSX_SYSROOT=' .. sdk,
            '-DCMAKE_OSX_DEPLOYMENT_TARGET=' .. macos_min_version })
    end
    local compiler_id = exec(append({ cwd = root, env = env, check = true, stdout = 'capture' }, cc, { '--version' }))
        .stdout:gsub('%s+$', '')
    if sdk then
        local sdk_version = exec { 'xcrun', '--sdk', 'macosx', '--show-sdk-version',
            cwd = root, env = env, check = true, stdout = 'capture' }.stdout
        compiler_id = compiler_id .. sdk .. sdk_version:gsub('%s+$', '')
    end

    -- Skip builds whose inputs have not changed.

    local inputs = { platform, compiler_id, cache, sha256 { path = root .. '/.cmd.lua' } }
    local dependency_key = sha256(table.concat(inputs, '\0'))
    append(inputs, { mode, version, sha256 { path = root .. '/THIRD_PARTY.txt' } })
    local sources = files(root .. '/src')
    for _, path in ipairs(sources) do append(inputs, { path, sha256 { path = path } }) end
    local fingerprint = sha256(table.concat(inputs, '\0'))
    local output = root .. '/target/' .. mode
    local executable = output .. '/dotcmd' .. suffix
    local stamp = output .. '/inputs.sha256'
    if fs.stat(executable) and fs.stat(stamp) and read(stamp) == fingerprint then
        print('Up to date: ' .. executable)
        return
    end

    -- Download the source archives, verifying each fresh download once.

    local lua_config = {
        version = '5.5.1',
        sha256 = '1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce',
    }
    local lua = cached {
        url = 'https://www.lua.org/ftp/lua-' .. lua_config.version .. '.tar.gz',
        sha256 = lua_config.sha256, extract = { strip_components = 1 },
    }
    local curl_config = {
        version = '8.22.0',
        sha256 = 'f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7',
    }
    local curl = cached {
        url = 'https://github.com/curl/curl/releases/download/curl-' .. curl_config.version:gsub('%.', '_')
            .. '/curl-' .. curl_config.version .. '.tar.xz',
        sha256 = curl_config.sha256, extract = { strip_components = 1 },
    }
    local tls
    if not windows then
        local libressl_config = {
            version = '4.3.2',
            sha256 = 'edf01aee24c65d69e6a9efcb9d44bcda682ff9d4f3bbbd95e794e1dfa90847b5',
        }
        tls = cached {
            url = 'https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-' .. libressl_config.version .. '.tar.gz',
            sha256 = libressl_config.sha256, extract = { strip_components = 1 },
        }
    end
    local libarchive_config = {
        version = '3.8.9',
        sha256 = 'f5a6539059cf5e597dbeda37bfa4874b1e8dea063c8d93bf85a2b44af90a5bd4',
    }
    local archive = cached {
        url = 'https://github.com/libarchive/libarchive/releases/download/v' .. libarchive_config.version
            .. '/libarchive-' .. libarchive_config.version .. '.tar.gz',
        sha256 = libarchive_config.sha256, extract = { strip_components = 1 },
    }

    -- Build native dependencies privately, then publish the completed directory.

    local dependencies = cache .. '/build/' .. dependency_key
    if not fs.stat(dependencies) then
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
        fs.make_executable(ninja)
        append(cmake_options, { '-DCMAKE_MAKE_PROGRAM=' .. ninja })
        local zlib_config = {
            version = '1.3.2',
            sha256 = 'bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16',
        }
        local zlib = cached {
            url = 'https://zlib.net/fossils/zlib-' .. zlib_config.version .. '.tar.gz',
            sha256 = zlib_config.sha256, extract = { strip_components = 1 },
        }
        local xz_config = {
            version = '5.8.4',
            sha256 = '0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9',
        }
        local xz = cached {
            url = 'https://github.com/tukaani-project/xz/releases/download/v' .. xz_config.version
                .. '/xz-' .. xz_config.version .. '.tar.gz',
            sha256 = xz_config.sha256, extract = { strip_components = 1 },
        }

        fs.mkdir(cache .. '/build')
        local work = cache .. '/build/.tmp-' .. ('%016x'):format(math.random(0))
        fs.mkdir(work)
        local cleanup <close> = setmetatable({}, { __close = function() fs.remove(work, { recursive = true }) end })
        local function configure(src, dest, options)
            local args = append({
                cmake,
                '-S',
                src,
                '-B',
                work .. '/' .. dest,
                cwd = root,
                env = env,
                check = true
            }, cmake_options, options)
            -- CMake writes these paths into scripts, where backslashes become escapes.
            if windows then
                for i = 2, #args do args[i] = args[i]:gsub('\\', '/') end
            end
            exec(args)
        end
        local function make(dir, targets)
            exec(append({
                cmake,
                '--build',
                work .. '/' .. dir,
                '--parallel',
                '4',
                cwd = root,
                env = env,
                check = true
            }, targets or {}))
        end

        -- HTTPS: LibreSSL on Unix; the Windows certificate store through Schannel.

        if tls then
            configure(tls, 'tls',
                { '-DLIBRESSL_APPS=OFF', '-DLIBRESSL_TESTS=OFF', '-DLIBRESSL_SKIP_INSTALL=ON', '-DOPENSSLDIR=/etc/ssl' })
            make('tls', { '--target', 'ssl', 'crypto' })
        end
        local http_options = {
            '-DBUILD_STATIC_LIBS=ON', '-DBUILD_CURL_EXE=OFF', '-DBUILD_EXAMPLES=OFF',
            '-DBUILD_LIBCURL_DOCS=OFF', '-DBUILD_MISC_DOCS=OFF', '-DENABLE_CURL_MANUAL=OFF',
            '-DCURL_DISABLE_INSTALL=ON', '-DHTTP_ONLY=ON', '-DCURL_USE_PKGCONFIG=OFF',
            '-DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON', '-DCURL_DISABLE_OPENSSL_AUTO_LOAD_CONFIG=ON',
            '-DCURL_ZLIB=OFF', '-DCURL_BROTLI=OFF', '-DCURL_ZSTD=OFF', '-DUSE_NGHTTP2=OFF',
            '-DUSE_LIBIDN2=OFF', '-DCURL_USE_LIBPSL=OFF', '-DCURL_USE_LIBSSH2=OFF',
        }
        if windows then
            append(http_options, { '-DCURL_USE_SCHANNEL=ON', '-DCURL_USE_OPENSSL=OFF' })
        else
            append(http_options,
                { '-DCURL_USE_OPENSSL=ON', '-DOPENSSL_USE_STATIC_LIBS=ON', '-DOPENSSL_INCLUDE_DIR=' .. tls .. '/include',
                    '-DOPENSSL_SSL_LIBRARY=' .. work .. '/tls/ssl/libssl.a', '-DOPENSSL_CRYPTO_LIBRARY=' ..
                work .. '/tls/crypto/libcrypto.a' })
            if sdk then append(http_options,
                    { '-DUSE_APPLE_SECTRUST=ON', '-DCURL_CA_BUNDLE=none', '-DCURL_CA_PATH=none' }) end
        end
        configure(curl, 'curl', http_options)
        make('curl', { '--target', 'libcurl_static' })

        -- Archives: tar/zip with gzip/xz, without extra libraries or command-line tools.

        append(cmake_options, { '-DCMAKE_INSTALL_PREFIX=' .. work .. '/install', '-DCMAKE_INSTALL_LIBDIR=lib' })
        configure(zlib, 'zlib', { '-DZLIB_BUILD_SHARED=OFF', '-DZLIB_BUILD_TESTING=OFF' })
        make('zlib')
        exec { cmake, '--install', work .. '/zlib', cwd = root, env = env, check = true }
        configure(xz, 'xz',
            { '-DXZ_TOOL_XZ=OFF', '-DXZ_TOOL_XZDEC=OFF', '-DXZ_TOOL_LZMADEC=OFF', '-DXZ_TOOL_LZMAINFO=OFF',
                '-DXZ_DOC=OFF', '-DXZ_NLS=OFF', '-DXZ_TOOL_SCRIPTS=OFF' })
        make('xz', { '--target', 'liblzma' })
        exec { cmake, '--install', work .. '/xz', cwd = root, env = env, check = true }
        local archive_options = {
            '-DENABLE_ZLIB=ON', '-DENABLE_LZMA=ON', '-DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON',
            '-DPOSIX_REGEX_LIB=NONE', -- dotcmd selects archive entries itself.
            '-DZLIB_INCLUDE_DIR=' .. work .. '/install/include',
            '-DZLIB_LIBRARY=' .. work .. '/install/lib/' .. (windows and 'libzs.a' or 'libz.a'),
            '-DLIBLZMA_INCLUDE_DIR=' .. work .. '/install/include',
            '-DLIBLZMA_LIBRARY=' .. work .. '/install/lib/liblzma.a',
        }
        for _, feature in ipairs({ 'MBEDTLS', 'NETTLE', 'OPENSSL', 'LIBB2', 'LZ4', 'LZO', 'ZSTD', 'BZip2',
            'LIBXML2', 'EXPAT', 'WIN32_XMLLITE', 'PCREPOSIX', 'PCRE2POSIX', 'LIBGCC', 'CNG', 'TAR', 'CPIO',
            'CAT', 'UNZIP', 'XATTR', 'ACL', 'ICONV', 'TEST', 'INSTALL' }) do
            archive_options[#archive_options + 1] = '-DENABLE_' .. feature .. '=OFF'
        end
        configure(archive, 'archive', archive_options)
        make('archive', { '--target', 'archive_static' })
        fs.rename(work, dependencies, { if_exists = 'skip' })
    end

    -- Generate the embedded Lua, license text, and build metadata.

    print('Building ' .. platform .. ' (' .. mode .. ')')
    fs.mkdir(output)
    local work = output .. '/.tmp-' .. ('%016x'):format(math.random(0))
    fs.mkdir(work .. '/obj'); fs.mkdir(work .. '/generated')
    local cleanup <close> = setmetatable({}, { __close = function() fs.remove(work, { recursive = true }) end })
    local generated = work .. '/generated'
    write(generated .. '/build_config.h', ('#define DOTCMD_VERSION %q\n#define DOTCMD_BUILD %q\n'):format(version, mode))
    local function embed(path, symbol)
        local bytes, values = read(path), {}
        for i = 1, #bytes do
            values[i] = ('0x%02x,%s'):format(bytes:byte(i), i % 16 == 0 and '\n' or '')
        end
        write(generated .. '/' .. symbol .. '.h', '/* Generated; do not edit. */\nstatic const unsigned char '
            .. symbol .. '[] = {\n' .. table.concat(values) .. '\n};\n')
    end
    embed(root .. '/src/main.lua', 'main_lua')
    embed(root .. '/THIRD_PARTY.txt', 'licenses')

    -- Compile Lua and the C++ sources.

    local common = { mode == 'release' and '-Oz' or '-O0', '-g', '-ffunction-sections', '-fdata-sections' }
    local objects = {}
    for _, path in ipairs(files(lua .. '/src')) do
        local name = path:match('/([^/]+)%.c$')
        if name and name ~= 'lua' and name ~= 'luac' and name ~= 'onelua' then
            local object = work .. '/obj/' .. name .. '.o'
            local args = append({ '-std=c99' }, common, { '-c', path, '-o', object })
            if not windows then args[#args + 1] = '-DLUA_USE_POSIX' end
            exec(append({ cwd = root, env = env, check = true }, cc, args))
            objects[#objects + 1] = object
        end
    end
    for _, path in ipairs(sources) do
        local name = path:match('/([^/]+)%.cpp$')
        if name then
            local object = work .. '/obj/' .. name .. '.o'
            local args = append(
                { '-x', 'c++', '-std=c++11', '-fno-exceptions', '-fno-rtti', '-Wall', '-Wextra', '-Werror',
                    '-DCURL_STATICLIB', '-DLIBARCHIVE_STATIC', '-I' .. lua .. '/src', '-I' .. generated,
                    '-I' .. curl .. '/include', '-I' .. archive .. '/libarchive' }, common, { '-c', path, '-o', object })
            if tls then args[#args + 1] = '-I' .. tls .. '/include' end
            exec(append({ cwd = root, env = env, check = true }, cc, args))
            objects[#objects + 1] = object
        end
    end
    -- Link the executable, then publish it and its input fingerprint.

    append(objects, { dependencies .. '/curl/lib/libcurl.a' })
    if tls then append(objects, { dependencies .. '/tls/ssl/libssl.a', dependencies .. '/tls/crypto/libcrypto.a' }) end
    append(objects, { dependencies .. '/archive/libarchive/libarchive.a', dependencies .. '/install/lib/liblzma.a',
        dependencies .. '/install/lib/' .. (windows and 'libzs.a' or 'libz.a') })
    if windows then
        exec { windres, '-I', root .. '/src', '-i', root .. '/src/windows.rc',
            '-o', work .. '/obj/windows.o', '-O', 'coff', cwd = root, env = env, check = true }
        append(objects,
            { work .. '/obj/windows.o', '-municode', '-lws2_32', '-lcrypt32', '-lsecur32', '-lbcrypt', '-ladvapi32',
                '-liphlpapi' })
    end
    if sdk then
        append(objects,
            { '-Wl,-dead_strip', '-framework', 'Security', '-framework', 'CoreFoundation', '-framework', 'CoreServices',
                '-framework', 'SystemConfiguration' })
        if mode == 'release' then objects[#objects + 1] = '-Wl,-x' end
    else
        append(objects, { '-static', '-Wl,--gc-sections' })
        if mode == 'release' then objects[#objects + 1] = '-s' end
    end
    if not windows then objects[#objects + 1] = '-lm' end
    exec(append({ cwd = root, env = env, check = true }, cc, objects, { '-o', work .. '/dotcmd' .. suffix }))
    fs.rename(work .. '/dotcmd' .. suffix, executable, { if_exists = 'replace' })
    write(stamp, fingerprint)
    print(executable)
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
            return exec(binary, '--launcher', root .. '/.cmd', ...).code
        end,
    },
    test = {
        description = 'Build once and test .cmd in fixture projects',
        run = function()
            build()
            local output = root .. '/target/release/'
            write(output .. '.cmd', read(root .. '/.cmd'))
            write(output .. '.cmd.lua', ('return {test = assert(loadfile(%q))()}\n'):format(root .. '/test/run.lua'))
            return exec(binary, '--launcher', output .. '.cmd', 'test', root).code
        end,
    },
}

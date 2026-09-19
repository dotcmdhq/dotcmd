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
    mode = mode or 'release'
    local config = {}
    for key, value in read(root .. '/toolchain.env'):gmatch('([A-Z0-9_]+)=([^\r\n]+)') do config[key] = value end
    local version = os.getenv('DOTCMD_VERSION') or 'dev'
    local platform = host.os .. '-' .. host.arch
    local arch = host.arch == 'x64' and 'x86_64' or 'aarch64'
    local cache = host.cache_dir:gsub('\\', '/')
    local env = {}
    local function run(args)
        args.cwd = root; args.env = env; args.check = true
        return exec(args)
    end
    local function capture(args)
        args.stdout = 'capture'
        local _, out = run(args)
        return (out:gsub('%s+$', ''))
    end
    local function package(url, key, strip)
        local path = cached { url = url, sha256 = config[key .. '_SHA256'], extract = { strip_components = strip or 1 } }
        return (path:gsub('\\', '/'))
    end

    local cc, windres, sdk, compiler_id
    local cmake_options = { '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=MinSizeRel',
        '-DCMAKE_C_FLAGS=-ffunction-sections -fdata-sections', '-DBUILD_SHARED_LIBS=OFF', '-DBUILD_TESTING=OFF' }
    if host.os == 'linux' then
        local name = 'zig-' .. arch .. '-linux-' .. config.ZIG_VERSION
        local zig = package('https://ziglang.org/download/' .. config.ZIG_VERSION .. '/' .. name .. '.tar.xz',
            'ZIG_' .. host.arch:upper()) .. '/zig'
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
        local name = 'llvm-mingw-' .. config.LLVM_MINGW_VERSION .. '-ucrt-' .. arch
        local toolchain = package('https://github.com/mstorsjo/llvm-mingw/releases/download/'
            .. config.LLVM_MINGW_VERSION .. '/' .. name .. '.zip', 'MINGW_' .. host.arch:upper())
        cc = { toolchain .. '/bin/' .. arch .. '-w64-mingw32-clang.exe' }
        windres = toolchain .. '/bin/' .. arch .. '-w64-mingw32-windres.exe'
        append(cmake_options, { '-DCMAKE_C_COMPILER=' .. cc[1], '-DCMAKE_RC_COMPILER=' .. windres,
            '-DCMAKE_EXE_LINKER_FLAGS=-static' })
    else
        sdk = capture { 'xcrun', '--sdk', 'macosx', '--show-sdk-path' }
        local compiler = capture { 'xcrun', '--sdk', 'macosx', '--find', 'clang' }
        cc = { compiler, '-isysroot', sdk, '-mmacosx-version-min=' .. config.MACOS_MIN_VERSION }
        append(cmake_options, { '-DCMAKE_C_COMPILER=' .. compiler, '-DCMAKE_OSX_SYSROOT=' .. sdk,
            '-DCMAKE_OSX_DEPLOYMENT_TARGET=' .. config.MACOS_MIN_VERSION })
    end
    compiler_id = capture(append({}, cc, { '--version' }))
    if sdk then compiler_id = compiler_id .. sdk .. capture { 'xcrun', '--sdk', 'macosx', '--show-sdk-version' } end
    local function compile(args) run(append({}, cc, args)) end

    local inputs = { platform, compiler_id, cache }
    for _, path in ipairs({ '.cmd.lua', 'toolchain.env', 'curl.cmake', 'archive.cmake' }) do
        inputs[#inputs + 1] = sha256 { path = root .. '/' .. path }
    end
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

    local lua = package('https://www.lua.org/ftp/lua-' .. config.LUA_VERSION .. '.tar.gz', 'LUA')
    local curl = package('https://github.com/curl/curl/releases/download/curl-' .. config.CURL_VERSION:gsub('%.', '_')
        .. '/curl-' .. config.CURL_VERSION .. '.tar.xz', 'CURL')
    local tls
    if not windows then
        tls = package('https://cdn.openbsd.org/pub/OpenBSD/LibreSSL/libressl-' .. config.LIBRESSL_VERSION .. '.tar.gz',
            'LIBRESSL')
    end
    local archive = package('https://github.com/libarchive/libarchive/releases/download/v' .. config.LIBARCHIVE_VERSION
        .. '/libarchive-' .. config.LIBARCHIVE_VERSION .. '.tar.gz', 'LIBARCHIVE')

    -- Build native dependencies privately, then publish the completed directory.
    local dependencies = cache .. '/build/' .. dependency_key
    if not fs.stat(dependencies) then
        local tools = ({
            ['linux-x64'] = { cmake = 'linux-x86_64', ninja = 'linux' },
            ['linux-arm64'] = { cmake = 'linux-aarch64', ninja = 'linux-aarch64' },
            ['macos-x64'] = { cmake = 'macos10.10-universal', ninja = 'mac' },
            ['macos-arm64'] = { cmake = 'macos10.10-universal', ninja = 'mac' },
            ['windows-x64'] = { cmake = 'windows-x86_64', ninja = 'win' },
            ['windows-arm64'] = { cmake = 'windows-arm64', ninja = 'winarm64' },
        })[platform]
        local key = host.os == 'macos' and 'MACOS' or host.os:upper() .. '_' .. host.arch:upper()
        local cmake_name = 'cmake-' .. config.CMAKE_VERSION .. '-' .. tools.cmake
        local cmake = package('https://github.com/Kitware/CMake/releases/download/v' .. config.CMAKE_VERSION
                .. '/' .. cmake_name .. (windows and '.zip' or '.tar.gz'), 'CMAKE_' .. key)
            .. (host.os == 'macos' and '/CMake.app/Contents/bin/cmake' or '/bin/cmake' .. suffix)
        local ninja = package('https://github.com/ninja-build/ninja/releases/download/v' .. config.NINJA_VERSION
            .. '/ninja-' .. tools.ninja .. '.zip', 'NINJA_' .. key, 0) .. '/ninja' .. suffix
        fs.make_executable(ninja)
        append(cmake_options, { '-DCMAKE_MAKE_PROGRAM=' .. ninja })
        local zlib = package('https://zlib.net/fossils/zlib-' .. config.ZLIB_VERSION .. '.tar.gz', 'ZLIB')
        local xz = package('https://github.com/tukaani-project/xz/releases/download/v' .. config.XZ_VERSION
            .. '/xz-' .. config.XZ_VERSION .. '.tar.gz', 'XZ')

        fs.mkdir(cache .. '/build')
        local work = cache .. '/build/.tmp-' .. ('%016x'):format(math.random(0))
        fs.mkdir(work)
        local cleanup <close> = setmetatable({}, { __close = function() fs.remove(work, { recursive = true }) end })
        local function configure(src, dest, options)
            run(append({ cmake, '-S', src, '-B', work .. '/' .. dest }, cmake_options, options or {}))
        end
        local function make(dir, targets)
            run(append({ cmake, '--build', work .. '/' .. dir, '--parallel', '4' }, targets or {}))
        end
        if tls then
            configure(tls, 'tls',
                { '-DLIBRESSL_APPS=OFF', '-DLIBRESSL_TESTS=OFF', '-DLIBRESSL_SKIP_INSTALL=ON', '-DOPENSSLDIR=/etc/ssl' })
            make('tls', { '--target', 'ssl', 'crypto' })
        end
        local http_options = { '-C', root .. '/curl.cmake' }
        if windows then
            append(http_options, { '-DCURL_USE_SCHANNEL=ON', '-DCURL_USE_OPENSSL=OFF' })
        else
            append(http_options,
                { '-DCURL_USE_OPENSSL=ON', '-DOPENSSL_USE_STATIC_LIBS=ON', '-DOPENSSL_INCLUDE_DIR=' .. tls .. '/include',
                    '-DOPENSSL_SSL_LIBRARY=' .. work .. '/tls/ssl/libssl.a', '-DOPENSSL_CRYPTO_LIBRARY=' ..
                work .. '/tls/crypto/libcrypto.a' })
            if sdk then append(http_options, { '-DUSE_APPLE_SECTRUST=ON', '-DCURL_CA_BUNDLE=none', '-DCURL_CA_PATH=none' }) end
        end
        configure(curl, 'curl', http_options)
        make('curl', { '--target', 'libcurl_static' })
        append(cmake_options, { '-DCMAKE_INSTALL_PREFIX=' .. work .. '/install', '-DCMAKE_INSTALL_LIBDIR=lib' })
        configure(zlib, 'zlib', { '-DZLIB_BUILD_SHARED=OFF', '-DZLIB_BUILD_TESTING=OFF' })
        make('zlib'); run { cmake, '--install', work .. '/zlib' }
        configure(xz, 'xz',
            { '-DXZ_TOOL_XZ=OFF', '-DXZ_TOOL_XZDEC=OFF', '-DXZ_TOOL_LZMADEC=OFF', '-DXZ_TOOL_LZMAINFO=OFF',
                '-DXZ_DOC=OFF', '-DXZ_NLS=OFF', '-DXZ_TOOL_SCRIPTS=OFF' })
        make('xz', { '--target', 'liblzma' }); run { cmake, '--install', work .. '/xz' }
        configure(archive, 'archive',
            { '-C', root .. '/archive.cmake', '-DZLIB_INCLUDE_DIR=' .. work .. '/install/include',
                '-DZLIB_LIBRARY=' .. work .. '/install/lib/' .. (windows and 'libzs.a' or 'libz.a'),
                '-DLIBLZMA_INCLUDE_DIR=' .. work .. '/install/include', '-DLIBLZMA_LIBRARY=' ..
            work .. '/install/lib/liblzma.a' })
        make('archive', { '--target', 'archive_static' })
        fs.rename(work, dependencies, { if_exists = 'skip' })
    end

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
    local common = { mode == 'release' and '-Oz' or '-O0', '-g', '-ffunction-sections', '-fdata-sections' }
    local objects = {}
    for _, path in ipairs(files(lua .. '/src')) do
        local name = path:match('/([^/]+)%.c$')
        if name and name ~= 'lua' and name ~= 'luac' and name ~= 'onelua' then
            local object = work .. '/obj/' .. name .. '.o'
            local args = append({ '-std=c99' }, common, { '-c', path, '-o', object })
            if not windows then args[#args + 1] = '-DLUA_USE_POSIX' end
            compile(args); objects[#objects + 1] = object
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
            compile(args); objects[#objects + 1] = object
        end
    end
    append(objects, { dependencies .. '/curl/lib/libcurl.a' })
    if tls then append(objects, { dependencies .. '/tls/ssl/libssl.a', dependencies .. '/tls/crypto/libcrypto.a' }) end
    append(objects, { dependencies .. '/archive/libarchive/libarchive.a', dependencies .. '/install/lib/liblzma.a',
        dependencies .. '/install/lib/' .. (windows and 'libzs.a' or 'libz.a') })
    if windows then
        run { windres, '-I', root .. '/src', '-i', root .. '/src/windows.rc', '-o', work .. '/obj/windows.o', '-O', 'coff' }
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
    compile(append(objects, { '-o', work .. '/dotcmd' .. suffix }))
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
            return exec(binary, '--launcher', root .. '/.cmd', ...)
        end,
    },
    test = {
        description = 'Build once and test .cmd in fixture projects',
        run = function()
            build()
            local output = root .. '/target/release/'
            write(output .. '.cmd', read(root .. '/.cmd'))
            write(output .. '.cmd.lua', ('return {test = assert(loadfile(%q))()}\n'):format(root .. '/test/run.lua'))
            return exec(binary, '--launcher', output .. '.cmd', 'test', root)
        end,
    },
}

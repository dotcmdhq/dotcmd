$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Root = $PSScriptRoot
Set-Location $Root
$Config = @{}
Get-Content (Join-Path $Root 'toolchain.env') | ForEach-Object {
    if ($_ -match '^([A-Z0-9_]+)=(.+)$') { $Config[$Matches[1]] = $Matches[2] }
}
$Version = if ($env:DOTCMD_VERSION) { $env:DOTCMD_VERSION } else { 'dev' }
$Mode = 'debug'
if ($args.Count -eq 1 -and $args[0] -eq '--release') { $Mode = 'release' }
elseif ($args.Count -ne 0) { throw 'Usage: .\build.ps1 [--release]' }
$Cache = Join-Path $Root '.cache'
$Out = Join-Path $Root "target/$Mode"
$Downloads = Join-Path $Cache 'downloads'
New-Item -ItemType Directory -Force $Downloads, $Out | Out-Null
$LockPath = Join-Path $Cache 'build.lock'
try { New-Item -ItemType Directory $LockPath -ErrorAction Stop | Out-Null }
catch { throw 'Another build is active. Remove .cache/build.lock only if a previous build was interrupted.' }

function Download($Url, $Path, $Expected) {
    if (!(Test-Path $Path) -or (Get-FileHash $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected) {
        & curl.exe --fail --location --retry 3 $Url -o "$Path.tmp"
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $Url" }
        if ((Get-FileHash "$Path.tmp" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected) {
            Remove-Item "$Path.tmp"
            throw "Checksum mismatch: $Url"
        }
        Move-Item -Force "$Path.tmp" $Path
    }
}
function Extract($Archive, $Directory, $Marker) {
    if (!(Test-Path (Join-Path $Directory $Marker))) {
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$Directory.tmp"
        New-Item -ItemType Directory -Force "$Directory.tmp" | Out-Null
        & tar.exe -xf $Archive --strip-components=1 -C "$Directory.tmp"
        if ($LASTEXITCODE -ne 0 -or !(Test-Path (Join-Path "$Directory.tmp" $Marker))) {
            throw "Extraction failed: $Archive"
        }
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $Directory
        Move-Item "$Directory.tmp" $Directory
    }
}
function Compile([string[]]$Flags) {
    & $script:Compiler @Flags
    if ($LASTEXITCODE -ne 0) { throw "Compiler failed with exit code $LASTEXITCODE" }
}

try {
    $Machine = $env:PROCESSOR_ARCHITEW6432
    if (!$Machine) { $Machine = $env:PROCESSOR_ARCHITECTURE }
    switch ($Machine) {
        'AMD64' { $Arch = 'x64'; $Triple = 'x86_64'; $Hash = $Config.MINGW_X64_SHA256 }
        'ARM64' { $Arch = 'arm64'; $Triple = 'aarch64'; $Hash = $Config.MINGW_ARM64_SHA256 }
        default { throw "Unsupported Windows architecture: $Machine" }
    }
    $Name = "llvm-mingw-$($Config.LLVM_MINGW_VERSION)-ucrt-$Triple"
    $Archive = Join-Path $Downloads "$Name.zip"
    $Toolchain = Join-Path $Cache "toolchains/$Name"
    Download "https://github.com/mstorsjo/llvm-mingw/releases/download/$($Config.LLVM_MINGW_VERSION)/$Name.zip" $Archive $Hash
    Extract $Archive $Toolchain "bin/$Triple-w64-mingw32-clang.exe"
    $script:Compiler = Join-Path $Toolchain "bin/$Triple-w64-mingw32-clang.exe"
    $CompilerVersion = (& $script:Compiler --version) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $CompilerVersion -notmatch ('clang version ' + [regex]::Escape($Config.CLANG_VERSION) + '(\s|$)')) {
        throw "Unexpected compiler version: $CompilerVersion"
    }
    $Lua = Join-Path $Cache "deps/lua-$($Config.LUA_VERSION)"
    $LuaArchive = Join-Path $Downloads "lua-$($Config.LUA_VERSION).tar.gz"
    Download "https://www.lua.org/ftp/lua-$($Config.LUA_VERSION).tar.gz" $LuaArchive $Config.LUA_SHA256
    Extract $LuaArchive $Lua 'src/lua.h'

    $CmakeHash = $Config["CMAKE_WINDOWS_$($Arch.ToUpperInvariant())_SHA256"]
    $CmakeArch = if ($Arch -eq 'arm64') { 'arm64' } else { 'x86_64' }
    $CmakeName = "cmake-$($Config.CMAKE_VERSION)-windows-$CmakeArch"
    $CmakeDir = Join-Path $Cache "toolchains/$CmakeName"
    Download "https://github.com/Kitware/CMake/releases/download/v$($Config.CMAKE_VERSION)/$CmakeName.zip" "$Downloads/$CmakeName.zip" $CmakeHash
    Extract "$Downloads/$CmakeName.zip" $CmakeDir 'bin/cmake.exe'
    $Cmake = Join-Path $CmakeDir 'bin/cmake.exe'
    $NinjaPlatform = if ($Arch -eq 'arm64') { 'winarm64' } else { 'win' }
    $NinjaDir = Join-Path $Cache "toolchains/ninja-$($Config.NINJA_VERSION)"
    $NinjaArchive = "$Downloads/ninja-$NinjaPlatform-$($Config.NINJA_VERSION).zip"
    Download "https://github.com/ninja-build/ninja/releases/download/v$($Config.NINJA_VERSION)/ninja-$NinjaPlatform.zip" $NinjaArchive $Config["NINJA_WINDOWS_$($Arch.ToUpperInvariant())_SHA256"]
    if (!(Test-Path "$NinjaDir/ninja.exe")) {
        New-Item -ItemType Directory -Force $NinjaDir | Out-Null
        & $Cmake -E chdir $NinjaDir $Cmake -E tar xf $NinjaArchive
        if ($LASTEXITCODE -ne 0) { throw 'Extracting Ninja failed' }
    }
    $Curl = Join-Path $Cache "deps/curl-$($Config.CURL_VERSION)"
    $CurlArchive = "$Downloads/curl-$($Config.CURL_VERSION).tar.xz"
    $CurlTag = $Config.CURL_VERSION.Replace('.', '_')
    Download "https://github.com/curl/curl/releases/download/curl-$CurlTag/curl-$($Config.CURL_VERSION).tar.xz" $CurlArchive $Config.CURL_SHA256
    Extract $CurlArchive $Curl 'include/curl/curl.h'
    $DependencyInputs = @($CompilerVersion, $Arch) + @(Get-FileHash toolchain.env, curl.cmake, build.ps1 -Algorithm SHA256 | ForEach-Object Hash)
    $DependencyHasher = [System.Security.Cryptography.SHA256]::Create()
    try { $DependencyKey = [BitConverter]::ToString($DependencyHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes(($DependencyInputs -join "`n")))).Replace('-', '').ToLowerInvariant() }
    finally { $DependencyHasher.Dispose() }
    $Http = Join-Path $Cache "deps/http-windows-$Arch-$DependencyKey"
    if (!(Test-Path "$Http/complete")) {
        & $Cmake -S $Curl -B $Http -C "$Root/curl.cmake" -G Ninja `
            "-DCMAKE_MAKE_PROGRAM=$NinjaDir/ninja.exe" "-DCMAKE_C_COMPILER=$script:Compiler" `
            "-DCMAKE_RC_COMPILER=$($Toolchain.Replace('\', '/'))/bin/$Triple-w64-mingw32-windres.exe" `
            '-DCMAKE_BUILD_TYPE=MinSizeRel' '-DCMAKE_C_FLAGS=-ffunction-sections -fdata-sections' `
            '-DCMAKE_EXE_LINKER_FLAGS=-static' '-DCURL_USE_SCHANNEL=ON' '-DCURL_USE_OPENSSL=OFF'
        if ($LASTEXITCODE -ne 0) { throw 'Configuring libcurl failed' }
        & $Cmake --build $Http --target libcurl_static --parallel 4
        if ($LASTEXITCODE -ne 0) { throw 'Building libcurl failed' }
        New-Item -ItemType File "$Http/complete" | Out-Null
    }

    $ArchiveSource = Join-Path $Cache "deps/libarchive-$($Config.LIBARCHIVE_VERSION)"
    $ZlibSource = Join-Path $Cache "deps/zlib-$($Config.ZLIB_VERSION)"
    $XzSource = Join-Path $Cache "deps/xz-$($Config.XZ_VERSION)"
    Download "https://github.com/libarchive/libarchive/releases/download/v$($Config.LIBARCHIVE_VERSION)/libarchive-$($Config.LIBARCHIVE_VERSION).tar.gz" "$Downloads/libarchive-$($Config.LIBARCHIVE_VERSION).tar.gz" $Config.LIBARCHIVE_SHA256
    Extract "$Downloads/libarchive-$($Config.LIBARCHIVE_VERSION).tar.gz" $ArchiveSource 'libarchive/archive.h'
    Download "https://zlib.net/fossils/zlib-$($Config.ZLIB_VERSION).tar.gz" "$Downloads/zlib-$($Config.ZLIB_VERSION).tar.gz" $Config.ZLIB_SHA256
    Extract "$Downloads/zlib-$($Config.ZLIB_VERSION).tar.gz" $ZlibSource 'zlib.h'
    Download "https://github.com/tukaani-project/xz/releases/download/v$($Config.XZ_VERSION)/xz-$($Config.XZ_VERSION).tar.gz" "$Downloads/xz-$($Config.XZ_VERSION).tar.gz" $Config.XZ_SHA256
    Extract "$Downloads/xz-$($Config.XZ_VERSION).tar.gz" $XzSource 'src/liblzma/api/lzma.h'
    $ArchiveKey = "$DependencyKey-$((Get-FileHash archive.cmake -Algorithm SHA256).Hash.ToLowerInvariant())"
    $ArchiveBuild = Join-Path $Cache "deps/archive-windows-$Arch-$ArchiveKey"
    if (!(Test-Path "$ArchiveBuild/complete")) {
        $CmakeArgs = @('-G', 'Ninja', "-DCMAKE_MAKE_PROGRAM=$NinjaDir/ninja.exe", "-DCMAKE_C_COMPILER=$script:Compiler",
            "-DCMAKE_RC_COMPILER=$($Toolchain.Replace('\', '/'))/bin/$Triple-w64-mingw32-windres.exe",
            '-DCMAKE_BUILD_TYPE=MinSizeRel', '-DCMAKE_C_FLAGS=-ffunction-sections -fdata-sections',
            '-DBUILD_SHARED_LIBS=OFF', '-DBUILD_TESTING=OFF', '-DCMAKE_EXE_LINKER_FLAGS=-static',
            "-DCMAKE_INSTALL_PREFIX=$ArchiveBuild/install", '-DCMAKE_INSTALL_LIBDIR=lib')
        & $Cmake -S $ZlibSource -B "$ArchiveBuild/zlib" @CmakeArgs -DZLIB_BUILD_SHARED=OFF -DZLIB_BUILD_TESTING=OFF
        if ($LASTEXITCODE -ne 0) { throw 'Configuring zlib failed' }
        & $Cmake --build "$ArchiveBuild/zlib" --parallel 4
        if ($LASTEXITCODE -ne 0) { throw 'Building zlib failed' }
        & $Cmake --install "$ArchiveBuild/zlib"
        if ($LASTEXITCODE -ne 0) { throw 'Installing cached zlib failed' }
        & $Cmake -S $XzSource -B "$ArchiveBuild/xz" @CmakeArgs -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF -DXZ_DOC=OFF -DXZ_NLS=OFF -DXZ_TOOL_SCRIPTS=OFF
        if ($LASTEXITCODE -ne 0) { throw 'Configuring liblzma failed' }
        & $Cmake --build "$ArchiveBuild/xz" --target liblzma --parallel 4
        if ($LASTEXITCODE -ne 0) { throw 'Building liblzma failed' }
        & $Cmake --install "$ArchiveBuild/xz"
        if ($LASTEXITCODE -ne 0) { throw 'Installing cached liblzma failed' }
        & $Cmake -S $ArchiveSource -B "$ArchiveBuild/libarchive" -C "$Root/archive.cmake" @CmakeArgs `
            "-DZLIB_INCLUDE_DIR=$ArchiveBuild/install/include" "-DZLIB_LIBRARY=$ArchiveBuild/install/lib/libzs.a" `
            "-DLIBLZMA_INCLUDE_DIR=$ArchiveBuild/install/include" "-DLIBLZMA_LIBRARY=$ArchiveBuild/install/lib/liblzma.a"
        if ($LASTEXITCODE -ne 0) { throw 'Configuring libarchive failed' }
        & $Cmake --build "$ArchiveBuild/libarchive" --target archive_static --parallel 4
        if ($LASTEXITCODE -ne 0) { throw 'Building libarchive failed' }
        New-Item -ItemType File "$ArchiveBuild/complete" | Out-Null
    }

    $Inputs = @("$Mode windows $Arch", $CompilerVersion, $Version)
    $Files = @(Get-Item build.ps1, toolchain.env, curl.cmake, archive.cmake, embed.c, THIRD_PARTY.txt) + @(Get-ChildItem src -File -Recurse | Sort-Object FullName)
    foreach ($File in $Files) {
        $Inputs += $File.FullName.Substring($Root.Length)
        $Inputs += (Get-FileHash $File.FullName -Algorithm SHA256).Hash
    }
    $Hasher = [System.Security.Cryptography.SHA256]::Create()
    try { $Fingerprint = [BitConverter]::ToString($Hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes(($Inputs -join "`n")))) }
    finally { $Hasher.Dispose() }
    $Stamp = Join-Path $Out 'inputs.sha256'
    $Exe = Join-Path $Out 'dotcmd.exe'
    if ((Test-Path $Exe) -and (Test-Path $Stamp) -and (Get-Content $Stamp -Raw).Trim() -eq $Fingerprint) {
        Write-Output "Up to date: $Exe"
        exit 0
    }
    Write-Output "Building windows-$Arch ($Mode)"
    $ObjectsDir = Join-Path $Out 'obj'
    $Generated = Join-Path $Out 'generated'
    New-Item -ItemType Directory -Force $ObjectsDir, $Generated | Out-Null
    $Embed = Join-Path $Out 'embed.exe'
    Compile @('-std=c99', '-O2', '-static', 'embed.c', '-o', $Embed)
    & $Embed 'src/main.lua' "$Generated/main_lua.h" 'main_lua'
    if ($LASTEXITCODE -ne 0) { throw 'Embedding main.lua failed' }
    & $Embed 'THIRD_PARTY.txt' "$Generated/licenses.h" 'licenses'
    if ($LASTEXITCODE -ne 0) { throw 'Embedding licenses failed' }
    $Opt = if ($Mode -eq 'release') { '-Oz' } else { '-O0' }
    $Common = @($Opt, '-g', '-ffunction-sections', '-fdata-sections')
    $Objects = @()
    foreach ($Source in (Get-ChildItem "$Lua/src/*.c" | Sort-Object Name)) {
        if ($Source.Name -in @('lua.c', 'luac.c', 'onelua.c')) { continue }
        $Object = Join-Path $ObjectsDir ($Source.BaseName + '.o')
        Compile (@('-std=c99') + $Common + @('-c', $Source.FullName, '-o', $Object))
        $Objects += $Object
    }
    @("#define DOTCMD_VERSION ""$Version""", "#define DOTCMD_BUILD ""$Mode""") | Set-Content -Encoding ASCII (Join-Path $Generated 'build_config.h')
    foreach ($Source in (Get-ChildItem 'src/*.cpp' | Sort-Object Name)) {
        $Object = Join-Path $ObjectsDir ($Source.BaseName + '.o')
        Compile (@('-x', 'c++', '-std=c++11', '-fno-exceptions', '-fno-rtti', '-Wall', '-Wextra', '-Werror', '-DCURL_STATICLIB', '-DLIBARCHIVE_STATIC', "-I$Lua/src", "-I$Generated", "-I$Curl/include", "-I$ArchiveSource/libarchive") + $Common + @('-c', $Source.FullName, '-o', $Object))
        $Objects += $Object
    }
    & "$Toolchain/bin/$Triple-w64-mingw32-windres.exe" -I src -i src/windows.rc -o "$ObjectsDir/windows.o" -O coff
    if ($LASTEXITCODE -ne 0) { throw 'Compiling Windows manifest failed' }
    $Link = $Objects + @("$ObjectsDir/windows.o", "$Http/lib/libcurl.a", '-static', '-municode', '-Wl,--gc-sections', '-lws2_32', '-lcrypt32', '-lsecur32', '-lbcrypt', '-ladvapi32', '-liphlpapi')
    $Link += @("$ArchiveBuild/libarchive/libarchive/libarchive.a", "$ArchiveBuild/install/lib/liblzma.a", "$ArchiveBuild/install/lib/libzs.a")
    if ($Mode -eq 'release') { $Link += '-s' }
    Compile ($Link + @('-o', "$Exe.tmp"))
    Move-Item -Force "$Exe.tmp" $Exe
    Set-Content -Encoding ASCII $Stamp $Fingerprint
    Write-Output $Exe
} finally {
    Remove-Item $LockPath
}

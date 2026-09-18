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

    $Inputs = @("$Mode windows $Arch", $CompilerVersion, $Version)
    $Files = @(Get-Item build.ps1, toolchain.env, embed.c, THIRD_PARTY.txt) + @(Get-ChildItem src -File -Recurse | Sort-Object FullName)
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
    $MainObject = Join-Path $ObjectsDir 'main.o'
    @("#define DOTCMD_VERSION ""$Version""", "#define DOTCMD_BUILD ""$Mode""") | Set-Content -Encoding ASCII (Join-Path $Generated 'build_config.h')
    Compile (@('-x', 'c++', '-std=c++11', '-fno-exceptions', '-fno-rtti', '-Wall', '-Wextra', '-Werror', "-I$Lua/src", "-I$Generated") + $Common + @('-c', 'src/main.cpp', '-o', $MainObject))
    $Link = $Objects + @($MainObject, '-static', '-municode', '-Wl,--gc-sections')
    if ($Mode -eq 'release') { $Link += '-s' }
    Compile ($Link + @('-o', "$Exe.tmp"))
    Move-Item -Force "$Exe.tmp" $Exe
    Set-Content -Encoding ASCII $Stamp $Fingerprint
    Write-Output $Exe
} finally {
    Remove-Item $LockPath
}

:; version=0.1.69
:; sha_linux_x64=adba3898eeaabafbad7e101fdba4cf5a476bbccb4731953e347f6f6e2bb14b1f
:; sha_linux_arm64=277a492fce4e5d1e9fa48dfdb470f921ebcad72ab17c11f0df9b8f17ae42e3f8
:; sha_macos_x64=2d39ed11f2883506e913c592d18648413cd94eb9dc0dfe258c7cefdd4f1858ef
:; sha_macos_arm64=a918b26fe41acfc1aca76bb070401f612218d2174b284215b0931e2f7124d869
:; sha_windows_x64=9d3505c94a956ff6b5318c4f5e84e137e1d4cd844d5e6d4f8401df78c502d6dc
:; sha_windows_arm64=0da177738824bf154a5fc0b1ceae772e3a206fecab3468e5775d8217e769000e
:; set -eu
:; platform=$(uname -sm)
:; case "$platform" in Linux\ *) os=linux;; Darwin\ *) os=macos;; *) echo 'dotcmd: unsupported OS' >&2; exit 1;; esac
:; case "${platform#* }" in x86_64|amd64) arch=x64;; arm64|aarch64) arch=arm64;; *) echo 'dotcmd: unsupported CPU architecture' >&2; exit 1;; esac
:; cache=${DOTCMD_CACHE_DIR:-}
:; case "$cache" in /*) ;; '') case "$os" in linux) case "${XDG_CACHE_HOME:-}" in /*) cache="$XDG_CACHE_HOME/dotcmd";; *) cache="${HOME:?dotcmd: HOME is not set}/.cache/dotcmd";; esac;; macos) cache="${HOME:?dotcmd: HOME is not set}/Library/Caches/dotcmd";; esac;; *) echo 'dotcmd: DOTCMD_CACHE_DIR must be an absolute path' >&2; exit 1;; esac
:; cache="$cache/$version/$os-$arch"
:; binary="$cache/dotcmd"
:; if [ -x "$binary" ]; then exec "$binary" --launcher "$0" "$@"; fi
:; case "$os-$arch" in linux-x64) expected=$sha_linux_x64;; linux-arm64) expected=$sha_linux_arm64;; macos-x64) expected=$sha_macos_x64;; macos-arm64) expected=$sha_macos_arm64;; esac
:; case "$os" in linux) sha_tool=sha256sum;; macos) sha_tool=shasum;; esac
:; sha_path=$(command -v "$sha_tool" || true)
:; if [ -z "$sha_path" ] && [ -x "/usr/bin/$sha_tool" ]; then sha_path="/usr/bin/$sha_tool"; fi
:; if [ -z "$sha_path" ]; then echo "dotcmd: $sha_tool is required for SHA-256 verification." >&2; exit 127; fi
:; verify_sha() { case "$os" in linux) actual=$("$sha_path" < "$1") || return;; macos) actual=$("$sha_path" -a 256 < "$1") || return;; esac; if [ "${actual%% *}" != "$expected" ]; then echo "dotcmd: SHA-256 mismatch: $1" >&2; return 1; fi; }
:; curl_path=$(command -v curl || true)
:; if [ -z "$curl_path" ] && [ -x /usr/bin/curl ]; then curl_path=/usr/bin/curl; fi
:; if [ -z "$curl_path" ]; then wget_path=$(command -v wget || true); if [ -z "$wget_path" ] && [ -x /usr/bin/wget ]; then wget_path=/usr/bin/wget; fi; if [ -z "$wget_path" ]; then echo 'dotcmd: curl or wget is required to download dotcmd.' >&2; exit 127; fi; fi
:; mkdir -p "$cache"
:; tmp=$(mktemp "$cache/.download.XXXXXX")
:; trap 'rm -f "$tmp"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
:; url="https://github.com/dotcmdhq/dotcmd/releases/download/$version/dotcmd-$os-$arch"
:; if [ -n "$curl_path" ]; then "$curl_path" --fail --location --retry 3 --silent --show-error "$url" -o "$tmp"; else "$wget_path" -O "$tmp" "$url"; fi
:; verify_sha "$tmp"
:; chmod +x "$tmp"
:; mv -f "$tmp" "$binary"
:; trap - EXIT INT TERM
:; exec "$binary" --launcher "$0" "$@"
@echo off
setlocal EnableExtensions DisableDelayedExpansion
set /p "dotcmd_header="<"%~f0"
set "version=%dotcmd_header:~11%"
set "machine=%PROCESSOR_ARCHITEW6432%"
if not defined machine set "machine=%PROCESSOR_ARCHITECTURE%"
set "arch="
if /i "%machine%"=="AMD64" set "arch=x64"
if /i "%machine%"=="ARM64" set "arch=arm64"
if not defined arch goto unsupported
set "cache_root=%DOTCMD_CACHE_DIR%"
if defined cache_root goto custom_cache
set "cache_root=%LOCALAPPDATA%"
if not defined cache_root if defined USERPROFILE set "cache_root=%USERPROFILE%\AppData\Local"
if not defined cache_root goto missing_cache
set "cache_root=%cache_root%\dotcmd\Cache"
goto cache_ready
:custom_cache
if "%cache_root:~1,2%"==":\" goto cache_ready
if "%cache_root:~1,2%"==":/" goto cache_ready
if "%cache_root:~0,2%"=="\\" goto cache_ready
if "%cache_root:~0,2%"=="//" goto cache_ready
echo dotcmd: DOTCMD_CACHE_DIR must be an absolute path >&2
exit /b 1
:cache_ready
set "cache=%cache_root%\%version%\windows-%arch%"
set "binary=%cache%\dotcmd.exe"
if exist "%binary%" goto run
set "dotcmd_expected_sha="
for /f "tokens=2 delims==" %%H in ('findstr /b /c:":; sha_windows_%arch%=" "%~f0"') do set "dotcmd_expected_sha=%%H"
set "dotcmd_url=https://github.com/dotcmdhq/dotcmd/releases/download/%version%/dotcmd-windows-%arch%.exe"
for %%P in (powershell.exe) do set "powershell_path=%%~$PATH:P"
if not defined powershell_path if defined SystemRoot if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "powershell_path=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not defined powershell_path goto curl_fallback
setlocal
set "PSModulePath="
"%powershell_path%" -NoLogo -NoProfile -NonInteractive -Command "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'; $tmp = Join-Path $env:cache ('.download-' + [Guid]::NewGuid() + '.exe'); try { [void][IO.Directory]::CreateDirectory($env:cache); Invoke-WebRequest -UseBasicParsing -Uri $env:dotcmd_url -OutFile $tmp; if ((Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash -ne $env:dotcmd_expected_sha) { throw 'SHA-256 mismatch' }; Move-Item -LiteralPath $tmp -Destination $env:binary -Force } catch { [Console]::Error.WriteLine('dotcmd: ' + $_.Exception.Message); exit 1 } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }; exit 0"
if errorlevel 1 exit /b 1
endlocal
:run
"%binary%" --launcher "%~f0" %* & call exit /b %%errorlevel%%
:unsupported
echo dotcmd: unsupported CPU architecture >&2
exit /b 1
:missing_cache
echo dotcmd: neither LOCALAPPDATA nor USERPROFILE is set >&2
exit /b 1
:curl_fallback
for %%P in (curl.exe certutil.exe) do if "%%~$PATH:P"=="" (echo dotcmd: Windows PowerShell or both curl.exe and certutil.exe are required. >&2 & exit /b 127)
set "tmp=%binary%.%RANDOM%%RANDOM%.tmp"
curl.exe --create-dirs --fail --location --retry 3 --silent --show-error "%dotcmd_url%" -o "%tmp%" || (del /q "%tmp%" 2>nul & exit /b 1)
certutil.exe -hashfile "%tmp%" SHA256 | findstr /i /l /x /c:"%dotcmd_expected_sha%" >nul || (del /q "%tmp%" 2>nul & echo dotcmd: SHA-256 verification failed >&2 & exit /b 1)
move /y "%tmp%" "%binary%" >nul || (del /q "%tmp%" 2>nul & exit /b 1)
goto run

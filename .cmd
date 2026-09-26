:; version=0.1.67
:; sha_linux_x64=1f8a0e33ba7b2f42862ed75a9fbb07f5be409cd5fcb564e627f94db6388f5a4b
:; sha_linux_arm64=c30ffd78f2558a69ca75dec7e39f81e7db1b2f07b3a9980fd13be5c84dcca800
:; sha_macos_x64=d136faa30b71703d95c8aafb3cf273dc2317fef2ff5c642269f4f92c73fce46a
:; sha_macos_arm64=7b7f936921f2272fac02ff9f9fc8171a66eb2549bf11ba0562dd11bda98d6016
:; sha_windows_x64=da9e7f6750a54440258fec43ebdc9f50aec7096f563b2419973cbdf4d2a2e9bc
:; sha_windows_arm64=8731af6f70759e7d68ef48050a1e7d9c04a7a45dc86c19cffe4323e6b7cb1db5
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
for /f "tokens=2 delims==" %%V in ('findstr /b /c:":; version=" "%~f0"') do set "version=%%V"
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

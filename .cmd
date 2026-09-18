:; version=0.1.5
:; set -eu
:; case "$(uname -s)" in Linux) os=linux;; Darwin) os=macos;; *) echo 'dotcmd: unsupported OS' >&2; exit 1;; esac
:; case "$(uname -m)" in x86_64|amd64) arch=x64;; arm64|aarch64) arch=arm64;; *) echo 'dotcmd: unsupported CPU architecture' >&2; exit 1;; esac
:; case "$os" in linux) case "${XDG_CACHE_HOME:-}" in /*) cache="$XDG_CACHE_HOME/dotcmd";; *) cache="${HOME:?dotcmd: HOME is not set}/.cache/dotcmd";; esac;; macos) cache="${HOME:?dotcmd: HOME is not set}/Library/Caches/dotcmd";; esac
:; cache="$cache/$version/$os-$arch"
:; binary="$cache/dotcmd"
:; if [ ! -x "$binary" ]; then mkdir -p "$cache"; tmp=$(mktemp -d "$cache/.download.XXXXXX"); trap 'rm -rf "$tmp"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; curl --fail --location --retry 3 --silent --show-error "https://github.com/vlaaad/dotcmd/releases/download/$version/dotcmd-$os-$arch" -o "$tmp/dotcmd"; chmod +x "$tmp/dotcmd"; mv -f "$tmp/dotcmd" "$binary"; rmdir "$tmp"; trap - EXIT INT TERM; fi
:; exec "$binary" "$@"
@echo off
setlocal EnableExtensions DisableDelayedExpansion
for /f "tokens=2 delims==" %%V in ('findstr /b /c:":; version=" "%~f0"') do set "version=%%V"
set "machine=%PROCESSOR_ARCHITEW6432%"
if not defined machine set "machine=%PROCESSOR_ARCHITECTURE%"
set "arch="
if /i "%machine%"=="AMD64" set "arch=x64"
if /i "%machine%"=="ARM64" set "arch=arm64"
if not defined arch goto unsupported
if not defined LOCALAPPDATA goto missing_cache
set "cache=%LOCALAPPDATA%\dotcmd\Cache\%version%\windows-%arch%"
set "binary=%cache%\dotcmd.exe"
if exist "%binary%" goto run
if not exist "%cache%" mkdir "%cache%"
if not exist "%cache%" exit /b 1
:temporary
set "tmp=%cache%\.download-%RANDOM%-%RANDOM%.exe"
if exist "%tmp%" goto temporary
curl.exe --fail --location --retry 3 --silent --show-error "https://github.com/vlaaad/dotcmd/releases/download/%version%/dotcmd-windows-%arch%.exe" -o "%tmp%"
if errorlevel 1 goto download_failed
move /y "%tmp%" "%binary%" >nul
if errorlevel 1 goto download_failed
:run
"%binary%" %*
exit /b %errorlevel%
:download_failed
if exist "%tmp%" del /q "%tmp%"
exit /b 1
:unsupported
echo dotcmd: unsupported CPU architecture >&2
exit /b 1
:missing_cache
echo dotcmd: LOCALAPPDATA is not set >&2
exit /b 1

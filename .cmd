:; if [ "$#" -eq 0 ]; then printf '%s\n' 'dotcmd: sh'; exit 0; fi; exec "$@"
@echo off
setlocal
if "%~1"=="" (
    echo dotcmd: cmd
    exit /b 0
)
%*
exit /b %errorlevel%

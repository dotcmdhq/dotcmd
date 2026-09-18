#!/bin/sh
set -eu

output=$(./.cmd)
printf '%s\n' "$output"
test "$output" = 'dotcmd: sh'

code=0
./.cmd python3 tests/probe.py "two words" plain || code=$?
test "$code" -eq 37
printf '%s\n' 'exit code: 37 (OK)'

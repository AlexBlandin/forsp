@echo off
setlocal

set CFLAGS=-std=c11 -Wall -Werror -O2 -g
set LDFLAGS=

zig cc %CFLAGS% -o forsp.exe forsp.c -target x86_64-windows-gnu %LDFLAGS%
endlocal

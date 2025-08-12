@echo off
setlocal

set CFLAGS=-std=c11 -Wall -Werror -Wextra -Wpedantic -Wformat=2 -Wno-unused-parameter -Wshadow -Wwrite-strings -Wstrict-prototypes -Wold-style-definition -Wredundant-decls -Wnested-externs -Wmissing-include-dirs -O2 -g
set LDFLAGS=

zig cc %CFLAGS% -o forsp forsp.c %LDFLAGS%
endlocal

#!/bin/sh
# Builds srsmgr.exe with MinGW-w64 (Linux or MSYS2):
#   sudo apt install gcc-mingw-w64-x86-64     (Debian/Ubuntu)
#   pacman -S mingw-w64-x86_64-gcc            (MSYS2)
# Output: ../srsmgr.exe (copied next to the Steadier State scripts)
set -e
cd "$(dirname "$0")"
CC=${CC:-x86_64-w64-mingw32-gcc}
WINDRES=${WINDRES:-x86_64-w64-mingw32-windres}
$WINDRES srsmgr.rc -O coff -o srsmgr_res.o
$CC -O2 -Wall -Wextra -Wno-missing-field-initializers -municode -mwindows -static -s \
    -o srsmgr.exe srsmgr.c srsmgr_res.o \
    -lcomctl32 -ladvapi32 -lshell32 -luser32 -lgdi32
rm -f srsmgr_res.o
mv srsmgr.exe ../srsmgr.exe
ls -l ../srsmgr.exe

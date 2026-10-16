#!/bin/bash
# Self-test suite: builds the engine + a test binary of the app, then runs `Lantern --self-test` on real binaries.
set -uo pipefail
cd "$(dirname "$0")/.."
[ -f engine/CMakeLists.txt ] || { echo "engine/ is empty — run: git submodule update --init"; exit 1; }
cmake -S engine -B build-engine -G Ninja -DCMAKE_BUILD_TYPE=Release -DEREBUS_STATIC_CAPSTONE=ON >/dev/null
cmake --build build-engine --target erebus >/dev/null
mkdir -p build-test
swiftc -O -swift-version 5 app/Sources/*.swift -o build-test/Lantern -framework Cocoa || exit 1
export LANTERN_ENGINE="$PWD/build-engine/erebus"

clang -O1 -o build-test/hello_arm64 engine/tests/hello.c
clang -O1 -arch x86_64 -o build-test/hello_x64 engine/tests/hello.c
python3 engine/tests/mkelf.py build-test/tiny.elf

fail=0
run() {  # file [--arch X]
  echo "== $*"
  out=$(./build-test/Lantern --self-test "$@" 2>&1); rc=$?
  echo "$out" | grep -E "FAIL|passed|failed" ; [ $rc = 0 ] || fail=1
}
run build-test/hello_arm64
run build-test/hello_x64 --arch x86_64
run build-test/tiny.elf
[ -f /bin/ls ] && run /bin/ls --arch arm64e
[ -f /usr/bin/curl ] && run /usr/bin/curl --arch arm64
[ -d /System/Applications/Calculator.app ] && run /System/Applications/Calculator.app --arch arm64e
exit $fail

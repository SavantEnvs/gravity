#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) The TEST build first, with upstream's own Makefile and NORMAL flags (no sanitizer, no -gdwarf-3).
#    The runners are stashed under build/oracle (build/ is gitignored upstream) and `make clean` then
#    clears the in-tree objects so the sanitized build below starts from nothing.
env -u CFLAGS -u LDFLAGS make clean >/dev/null
env -u CFLAGS -u LDFLAGS make -j"$MAYHEM_JOBS" CC="$CC $COVERAGE_FLAGS" gravity jsontest
mkdir -p build/oracle
cp gravity jsontest build/oracle/
env -u CFLAGS -u LDFLAGS make clean >/dev/null

# 2) The sanitized + DWARF-3 + SanCov-instrumented library, then the fuzz binaries. The library gets
#    -fsanitize=fuzzer-no-link so the fuzzed code itself carries coverage instrumentation.
SAN="build/san"
rm -rf "$SAN"; mkdir -p "$SAN/obj"
INCLUDES="-Isrc/compiler -Isrc/runtime -Isrc/shared -Isrc/utils -Isrc/optionals"
LIBFLAGS="-std=gnu99 -fgnu89-inline -fPIC -DBUILD_GRAVITY_API -O1 $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
find src/compiler src/runtime src/shared src/utils src/optionals -name '*.c' | sort | \
    xargs -P "$MAYHEM_JOBS" -I{} sh -c 'o="$1/obj/$(basename "$2" .c).o"; '"$CC"' $3 $4 -c "$2" -o "$o"' _ "$SAN" {} "$LIBFLAGS" "$INCLUDES"
rm -f "$SAN/libgravity.a"
ar rcs "$SAN/libgravity.a" "$SAN"/obj/*.o

# lsan_off: leaks are not the bug class we fuzz for (see the port rules); link into every fuzz binary.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.c -o "$SAN/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$SAN/standalone_main.o"

LINK="$SAN/libgravity.a $SAN/lsan_off.o -lm -lrt"

# the CLI (`gravity <file.gravity>`): a file-input target
$CC -std=gnu99 -fgnu89-inline -DBUILD_GRAVITY_API -O1 $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS $INCLUDES \
    src/cli/gravity.c $LINK -o /mayhem/gravity

for h in fuzz_compile fuzz_load; do
    $CC -std=gnu99 -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $INCLUDES \
        "mayhem/$h.c" $LINK -o "/mayhem/$h"
    $CC -std=gnu99 -O1 $SANITIZER_FLAGS $DEBUG_FLAGS $INCLUDES \
        "mayhem/$h.c" "$SAN/standalone_main.o" $LINK -o "/mayhem/$h-standalone"
done

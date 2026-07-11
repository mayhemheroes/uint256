#!/usr/bin/env bash
#
# uint256/mayhem/build.sh — build holiman/uint256's OSS-Fuzz Go fuzz targets as sanitized
# libFuzzer binaries, REPLICATING OSS-Fuzz's compile_go_fuzzer for native testing.F harnesses.
#
# OSS-Fuzz targets (uint256/oss-fuzz.sh) — 5 native `func FuzzX(f *testing.F)` harnesses defined in
# the uint256 package's *_test.go files. Upstream's build uses holiman/gofuzz-shim invoked with an
# explicit FILE LIST per target (e.g. `-f unary_test.go,shared_test.go`) because the harness shares
# helpers across several *_test.go files. We use go-118-fuzz-build (the proven mayhemheroes Go
# pattern); both decode the libFuzzer byte buffer into the harness's typed args via go-fuzz-headers,
# then link with libFuzzer.
#
#   FuzzUnaryOperations    f.Fuzz(func(t, x0..x3 uint64))                 [unary_test.go]    -> fuzzUnary
#   FuzzBinaryOperations   f.Fuzz(func(t, x0..x3, y0..y3 uint64))         [binary_test.go]   -> fuzzBinary
#   FuzzCompareOperations  f.Fuzz(func(t, x0..x3, y0..y3 uint64))         [binary_test.go]   -> fuzzCompare
#   FuzzTernaryOperations  f.Fuzz(func(t, x0..x3,y0..y3,z0..z3 uint64))   [ternary_test.go]  -> fuzzTernary
#   FuzzSetString          f.Fuzz(func(t, data []byte))                   [conversion_fuzz]  -> fuzzSetString
#
# These are DIFFERENTIAL oracles: every uint256 op is checked against math/big, and FuzzSetString
# checks SetFromDecimal parsing against big.Int.SetString. A divergence t.Fatal -> libFuzzer crash.
#
# go-118-fuzz-build limitation + our fix
# --------------------------------------
# go-118-fuzz-build finds the target Fuzz func in a NON-test package file, renames that file to
# `<f>_fuzz.go` and builds the package as a NORMAL (non-test) build. It does NOT pull the rest of
# the package's *_test.go files in, so helpers that live in OTHER test files (shared_test.go etc.)
# go undefined. We therefore build each target in an isolated temp dir that contains:
#   * every non-test package .go file (the real library)
#   * the harness's own test file + the shared helper test file(s) it needs, COPIED to plain .go
#     names (so they are ordinary package files) with their Test*/Benchmark*/Example* functions
#     stripped (those reference helpers in yet-more test files, e.g. hex2Bytes; the Fuzz func and
#     the differential helpers it uses do not). go-118-fuzz-build then rewrites `testing` -> its
#     shim across these files exactly as it does for any package file.
# This mirrors upstream gofuzz-shim's `-f <file-list>` semantics with an additive, build-time-only
# transform that never touches the committed sources.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]). Keep ASan as the Go-fuzz
# sanitizer regardless of base default. An explicit empty --build-arg SANITIZER_FLAGS= disables it.
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4+ and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper, CGO bridge) are forced to DWARF3.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

# Go env: toolchain + caches are under /opt/toolchains (pinned by Dockerfile ENV).
# Ensure PATH includes the toolchain bin dirs for standalone invocations.
export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:$PATH"

cd "$SRC"
go version

# go-118-fuzz-build rewrites the test sources and needs the AdamKorcz testing shim as a module dep.
# Add module deps WITHOUT a trailing `go mod tidy` (tidy prunes the shim because nothing imports it
# until the builder generates the entrypoint). Order: tidy first, then `go get` the shim.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# strip_test_funcs <src.go> <dst.go>
#   Copy a gofmt-formatted Go file, dropping top-level Test*/Benchmark*/Example* functions (whose
#   closing brace sits at column 0). Keeps Fuzz* funcs, helper funcs, types and var blocks.
strip_test_funcs() {
  awk '
    /^func (Test|Benchmark|Example)[A-Z_(]/ { skip=1 }
    skip==1 { if ($0=="}") { skip=0 }; next }
    { print }
  ' "$1" > "$2"
}

# build_native <FuzzFunc> <out-binary> <helper_test_file...>
#   Build one target in an isolated temp dir (real library + stripped harness/helper test files).
build_native() {
  local func="$1" out="$2"; shift 2
  local helpers=("$@")
  local wd; wd="$(mktemp -d "$SRC/mayhem-build/${out}.XXXXXX")"

  # Real (non-test) library sources.
  for g in "$SRC"/*.go; do
    case "$g" in *_test.go) continue;; esac
    cp "$g" "$wd/"
  done
  # Module metadata so the temp dir is the same module (github.com/holiman/uint256).
  cp "$SRC/go.mod" "$wd/" 2>/dev/null || true
  cp "$SRC/go.sum" "$wd/" 2>/dev/null || true

  # Harness + helper test files -> plain .go (NOT *_test.go, so the non-test build sees them),
  # with Test/Benchmark/Example stripped.
  for h in "${helpers[@]}"; do
    local base="${h%_test.go}"           # unary_test.go -> unary
    strip_test_funcs "$SRC/$h" "$wd/mayhem_${base}.go"
  done

  echo "=== building $out ($func, go-118-fuzz-build) ==="
  ( cd "$wd" && go-118-fuzz-build -o "$SRC/mayhem-build/${out}.a" -func "$func" github.com/holiman/uint256 )
  # Link: $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3 (< 4 gate).
  $CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/${out}.a" -o "/mayhem/${out}"
  echo "built /mayhem/${out}"
}

build_native FuzzUnaryOperations   fuzzUnary     unary_test.go   shared_test.go
build_native FuzzBinaryOperations  fuzzBinary    binary_test.go  shared_test.go
build_native FuzzCompareOperations fuzzCompare   binary_test.go  shared_test.go
build_native FuzzTernaryOperations fuzzTernary   ternary_test.go shared_test.go
build_native FuzzSetString         fuzzSetString conversion_fuzz_test.go shared_test.go

echo "build.sh complete:"
ls -la /mayhem/fuzzUnary /mayhem/fuzzBinary /mayhem/fuzzCompare /mayhem/fuzzTernary /mayhem/fuzzSetString 2>&1 || true

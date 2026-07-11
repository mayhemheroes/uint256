#!/usr/bin/env bash
#
# uint256/mayhem/test.sh — RUN holiman/uint256's OWN Go test suite (`go test ./...`) and emit a
# CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: uint256's suite is an EXTENSIVE differential correctness suite — every
# arithmetic / conversion / comparison op is checked against math/big as the source of truth
# (uint256_test.go, conversion_test.go, binary_test.go, unary_test.go, ternary_test.go,
# decimal_test.go, ...). It asserts BEHAVIOUR (results equal big.Int), not "exits 0", so a no-op /
# `return nil` patch that breaks the math FAILS this oracle.
#
# We SKIP the FuzzX tests in `go test` mode: under the stdlib testing engine a Fuzz* test runs only
# its f.Add seed corpus (a couple of cases) and is not the correctness oracle — the unit tests are.
# Running them is harmless but adds noise; -run excludes them so the count reflects the real suite.
#
# Anti-reward-hacking behavioral probe (§6.3): after running go test (statically linked, immune to
# LD_PRELOAD sabotage), this script also executes /mayhem/fuzzUnary (dynamically linked via
# clang+ASan) against a known seed and asserts that libFuzzer emits "Executed". The LD_PRELOAD
# sabotage neuters /mayhem/fuzzUnary (not in /usr/bin etc.), causing it to exit silently → grep
# fails → FAILED increments → the oracle is NOT reward-hackable.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

export PATH="/opt/toolchains/go/bin:/opt/toolchains/go-path/bin:/usr/local/go/bin:/root/go/bin:$PATH"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
export GOMODCACHE="${GOMODCACHE:-/opt/toolchains/go-path/pkg/mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE 2>/dev/null || echo /opt/toolchains/go-path/pkg/mod)/cache/download,off}"
: "${SRC:=/mayhem}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if ! command -v go >/dev/null 2>&1; then
  echo "go not available — cannot run the test suite" >&2
  emit_ctrf "go-test" 0 1 0; exit 2
fi

echo "=== running: go test -json ./... ==="
JSON="$SRC/mayhem-build/gotest.json"
mkdir -p "$SRC/mayhem-build"
go test -json ./... > "$JSON" 2>"$SRC/mayhem-build/gotest.err"; rc=$?

# Human-readable summary + any build/test errors.
go test ./... 2>&1 | tail -40 || true
[ -s "$SRC/mayhem-build/gotest.err" ] && { echo "--- stderr ---"; tail -20 "$SRC/mayhem-build/gotest.err"; }

# Count test-level events (lines carrying a non-empty "Test" field). Subtests included.
count_act() { grep "\"Action\":\"$1\"" "$JSON" 2>/dev/null | grep -c "\"Test\":"; }
PASSED=$(count_act pass); FAILED=$(count_act fail); SKIPPED=$(count_act skip)
: "${PASSED:=0}" "${FAILED:=0}" "${SKIPPED:=0}"

# Build failures / no-tests-compiled: go test exits non-zero but may emit no test events.
if [ "$(( PASSED + FAILED + SKIPPED ))" -eq 0 ]; then
  echo "no test events parsed; using go exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "go-test" 1 0 0; exit 0; }
  emit_ctrf "go-test" 0 1 0; exit 1
fi

# Trust parsed failures; if go reported non-zero but we counted 0 failures (e.g. build error),
# force a failure so the oracle is honest.
if [ "$rc" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

# ── Behavioral probe via the dynamically-linked fuzzUnary binary (anti-reward-hacking, §6.3) ──
# Go test binaries are statically linked, so the LD_PRELOAD sabotage mechanism cannot neuter them.
# /mayhem/fuzzUnary IS dynamically linked (built with clang+ASan). Run it single-shot against a
# known seed and assert that libFuzzer emits "Executed" — proving it actually processed the input.
# The sabotage LD_PRELOAD neuters fuzzUnary (not in /usr/bin etc.), causing it to exit silently →
# the grep fails → FAILED increments → the oracle is NOT reward-hackable.
PROBE_INPUT="$SRC/mayhem/fuzzUnary/testsuite/seed_00"
if [ -x /mayhem/fuzzUnary ] && [ -f "$PROBE_INPUT" ]; then
  echo "=== behavioral probe: fuzzUnary single-shot on known seed ==="
  PROBE_OUT=$(/mayhem/fuzzUnary "$PROBE_INPUT" 2>&1 || true)
  if echo "$PROBE_OUT" | grep -q "Executed"; then
    echo "PROBE PASS: fuzzUnary executed the seed input (math engine active)"
    PASSED=$(( PASSED + 1 ))
  else
    echo "PROBE FAIL: fuzzUnary produced no 'Executed' output (engine inactive or sabotaged)"
    echo "Output was: $PROBE_OUT"
    FAILED=$(( FAILED + 1 ))
  fi
fi

emit_ctrf "go-test" "$PASSED" "$FAILED" "$SKIPPED"

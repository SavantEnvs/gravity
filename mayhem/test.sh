#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"
TMPDIR_T="$(mktemp -d)"; trap 'rm -rf "$TMPDIR_T"' EXIT

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

# EDIT: RUN the test runner that mayhem/build.sh produced, then map its output to counts.
#   ctest:        (cd build-tests && ctest) ; parse "<P> tests passed, <F> failed out of <T>"
#   gtest binary: ./build-tests/<prog> ; parse "[==========] N ... ran." / "[  PASSED  ] P" / "[ SKIPPED ] S"
#   make/minunit: ./out/<runner> ; parse its pass/fail/total
# Do NOT compile here — if the runner is absent, fail (build.sh should have produced it).

# build.sh left the NORMALLY-built (unsanitized) CLI and bounds test here.
GRAVITY="$SRC/build/oracle/gravity"
JSONTEST="$SRC/build/oracle/jsontest"
for b in "$GRAVITY" "$JSONTEST"; do
  [ -x "$b" ] || { echo "missing $b — mayhem/build.sh should have produced it" >&2; emit_ctrf "gravity" 0 1 0; exit 1; }
done

passed=0; failed=0
ok()  { passed=$((passed + 1)); }
bad() { failed=$((failed + 1)); echo "FAIL: $1" >&2; }

# expect_eq <name> <expected> <actual>
expect_eq() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected [$2], got [$3]"; fi; }

# 1) The project's own unit suite (one .gravity file per case, each checks an expected value or error).
#    Parse its summary line rather than trusting the exit code.
out="$("$GRAVITY" -t test/unittest 2>&1)"
n_tests="$(printf '%s\n' "$out" | sed -n 's/^Total Tests: \([0-9]*\)$/\1/p')"
n_succ="$(printf '%s\n' "$out" | sed -n 's/^Total Successes: \([0-9]*\)$/\1/p')"
n_fail="$(printf '%s\n' "$out" | sed -n 's/^Total Failures: \([0-9]*\)$/\1/p')"
if [ -z "$n_tests" ] || [ -z "$n_succ" ] || [ -z "$n_fail" ] || [ "$n_tests" -lt 300 ]; then
  bad "unit suite did not report a plausible summary (tests=[$n_tests])"
else
  passed=$((passed + n_succ)); failed=$((failed + n_fail))
  [ "$n_succ" -eq "$n_tests" ] || [ "$n_fail" -gt 0 ] || bad "unit suite: $n_succ of $n_tests succeeded"
fi

# 2) The upstream JSON scanner bounds tests (C API).
out="$("$JSONTEST" 2>&1)"
checks="$(printf '%s\n' "$out" | sed -n 's/^Checks run successfully: \([0-9]*\)\/\([0-9]*\)\. 0 failed$/\1 \2/p')"
set -- $checks
if [ "$#" -eq 2 ] && [ "$1" -eq "$2" ] && [ "$2" -ge 50 ]; then ok; else bad "jsontest summary: [$out]"; fi

# 3) Known-answer probes through the CLI: source -> RESULT value.
expect_eq "inline arithmetic" "RESULT: (INT) 42" \
  "$("$GRAVITY" -i 'return 6*7' | sed -n 's/^\(RESULT: (INT) 42\) (in.*/\1/p')"

cat > "$TMPDIR_T/kat1.gravity" <<'GRV'
class Counter {
    var value = 5;
    func next() { return func() { return value + 2; }; }
}
func main() {
    var c = Counter();
    var l = [1, 2, 3, 4];
    var m = ["a": 10, "b": 20];
    var s = "gravity";
    return c.next()() * 100 + l.count * 10 + m["b"] - s.length;
}
GRV
# 7*100 + 4*10 + 20 - 7 = 753
expect_eq "class/closure/list/map/string" "RESULT: (INT) 753" \
  "$("$GRAVITY" "$TMPDIR_T/kat1.gravity" | sed -n 's/^\(RESULT: (INT) [0-9-]*\) (in.*/\1/p')"

cat > "$TMPDIR_T/kat2.gravity" <<'GRV'
func fib(n) { if (n < 2) return n; return fib(n-1) + fib(n-2); }
func main() { return fib(15); }
GRV
expect_eq "recursion" "RESULT: (INT) 610" \
  "$("$GRAVITY" "$TMPDIR_T/kat2.gravity" | sed -n 's/^\(RESULT: (INT) [0-9-]*\) (in.*/\1/p')"

cat > "$TMPDIR_T/kat3.gravity" <<'GRV'
func main() { return "ab" + "cd"; }
GRV
expect_eq "string concat" "RESULT: (STRING) abcd" \
  "$("$GRAVITY" "$TMPDIR_T/kat3.gravity" | sed -n 's/^\(RESULT: (STRING) [a-z]*\) (0x.*/\1/p')"

# a syntax error is reported with its position
expect_eq "syntax error report" "SYNTAX ERROR on 0 (1,14): " \
  "$(printf 'func main() { var = ; }' > "$TMPDIR_T/bad.gravity"; "$GRAVITY" "$TMPDIR_T/bad.gravity" | sed -n 's/^\(SYNTAX ERROR on 0 ([0-9]*,[0-9]*): \).*/\1/p' | head -1)"

# 4) Compile to the JSON executable, check its shape, execute it through the loader (-c then -x).
"$GRAVITY" -c "$TMPDIR_T/kat1.gravity" -o "$TMPDIR_T/kat1.json" >/dev/null
expect_eq "serialized entry point" '{"$moduleinit":{"type":"function","identifier":"$moduleinit"' \
  "$(head -c 60 "$TMPDIR_T/kat1.json")"
expect_eq "run serialized executable" "RESULT: (INT) 753" \
  "$("$GRAVITY" -x "$TMPDIR_T/kat1.json" | sed -n 's/^\(RESULT: (INT) [0-9-]*\) (in.*/\1/p')"

# 5) Malformed executables are rejected as load errors (upstream's test/loadbuffer fixtures).
n_json=0
for f in test/loadbuffer/*.json; do
  n_json=$((n_json + 1))
  out="$(timeout 10 "$GRAVITY" -x "$f" 2>&1)"; rc=$?
  if [ "$rc" -lt 128 ] && [ "${out#*Error while loading compile file}" != "$out" ]; then ok; else bad "$f not rejected cleanly (rc=$rc): $out"; fi
done
[ "$n_json" -ge 8 ] || bad "only $n_json loadbuffer fixtures found"

emit_ctrf "gravity-cli" "$passed" "$failed" 0

#!/usr/bin/env bash
# xlsynth-bin smoke test.
#
#   tests/run_smoke_test.sh [PKG_DIR]
#
# PKG_DIR  root of an unpacked or installed xlsynth-bin (the directory holding
#          bin/, lib/, share/). Defaults to the package this script lives in,
#          if it lives in one.
#
# Called by scripts/build.sh during a repack (where it is the only thing
# standing between a mangled repack and a published release), and runnable by
# hand against an installed package:
#
#   tests/run_smoke_test.sh "$(ivpm path xlsynth-bin)"
#
# There is no version check: every upstream tool prints `redacted` for
# --version (docs/plan.md, Finding 3). The checksum verification in build.sh is
# what ties these bits to a tag.
#
# What it checks, in the order a failure is most likely:
#   1. all 12 tools exist and start
#   2. the DSLX tools find the bundled stdlib through their wrappers -- run
#      from a scratch directory, because upstream's default stdlib path is
#      relative to the CWD and would pass by accident inside an XLS checkout
#   3. a user's own --dslx_stdlib_path still beats the wrapper's
#   4. the real pipeline: DSLX tests -> IR -> opt -> Verilog, and the optimizer
#      is proven equivalent to its input (an opt_main that emitted garbage
#      would otherwise pass)
#   5. quickcheck proof, and the formatter is a fixed point
#   6. libxls loads and answers a C-API call
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pkg="${1:-}"
if [ -z "$pkg" ]; then
    [ -x "$here/../bin/typecheck_main" ] || {
        echo "usage: $0 PKG_DIR" >&2; exit 2; }
    pkg="$here/.."
fi
pkg="$(cd "$pkg" && pwd)"
bin="$pkg/bin"

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

TOOLS="
block_to_verilog_main
check_ir_equivalence_main
codegen_main
delay_info_main
dslx_fmt
dslx_interpreter_main
dslx_ls
highlight_main
ir_converter_main
opt_main
prove_quickcheck_main
typecheck_main
"

# Explicit template: portable across GNU and BSD mktemp.
work="$(mktemp -d "${TMPDIR:-/tmp}/xlsynth-smoke.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cp "$here/smoke.x" "$work/smoke.x"
# Everything below runs from here, never from the repo or the package.
cd "$work"

echo "xlsynth-bin smoke test (pkg=$pkg)"

# --- 1: every tool starts ---------------------------------------------------
count=0
for t in $TOOLS; do
    [ -x "$bin/$t" ] || fail "$t missing or not executable in $bin"
    # --helpfull, not --version: the version is always `redacted`, and
    # --helpfull exercises the wrapper path for the wrapped tools too. Judge it
    # by its output: every absl tool exits 1 after printing help, by design.
    help="$("$bin/$t" --helpfull 2>&1 || true)"
    printf '%s\n' "$help" | grep -q "Flags from" \
        || fail "$t did not start (no --helpfull output): $(printf '%s\n' "$help" | head -3)"
    count=$((count + 1))
done
[ "$count" -eq 12 ] || fail "expected 12 tools, checked $count"
ok "$count tools start"

# --- 2: the stdlib is found with no flags at all ----------------------------
"$bin/typecheck_main" smoke.x >/dev/null 2>tc.err \
    || fail "typecheck_main could not typecheck smoke.x (import std;): $(cat tc.err)"
ok "typecheck_main resolves \`import std;\` from an unrelated directory"

# --- 3: a user's flag overrides the wrapper's -------------------------------
if "$bin/typecheck_main" --dslx_stdlib_path="$work/no-such-stdlib" smoke.x >/dev/null 2>override.err; then
    fail "typecheck_main ignored an explicit --dslx_stdlib_path; the wrapper's flag must lose"
fi
# Failing is not enough; it must have failed looking in the user's directory.
grep -q "no-such-stdlib" override.err \
    || fail "typecheck_main failed, but not on the user's stdlib path: $(head -3 override.err)"
ok "an explicit --dslx_stdlib_path overrides the bundled one"

# --- 4: DSLX -> IR -> opt -> Verilog ----------------------------------------
"$bin/dslx_interpreter_main" smoke.x > interp.out 2>&1 \
    || fail "dslx_interpreter_main: $(cat interp.out)"
grep -q "1 test(s) ran; 0 failed" interp.out \
    || fail "dslx_interpreter_main did not run the unit test: $(cat interp.out)"
ok "dslx_interpreter_main passes the #[test]"

"$bin/ir_converter_main" --top=add_sat smoke.x > smoke.ir \
    || fail "ir_converter_main exited non-zero"
grep -q "^package smoke" smoke.ir || fail "ir_converter_main produced no IR package"
"$bin/opt_main" smoke.ir > smoke.opt.ir || fail "opt_main exited non-zero"
[ -s smoke.opt.ir ] || fail "opt_main produced an empty file"
"$bin/codegen_main" --generator=combinational --delay_model=unit smoke.opt.ir > smoke.v \
    || fail "codegen_main exited non-zero"
grep -q "^module __smoke__add_sat" smoke.v || fail "codegen_main emitted no add_sat module"
ok "ir_converter_main -> opt_main -> codegen_main emits Verilog"

"$bin/check_ir_equivalence_main" smoke.ir smoke.opt.ir > equiv.out 2>&1 \
    || fail "check_ir_equivalence_main: $(cat equiv.out)"
grep -q "Verified equivalent" equiv.out \
    || fail "optimized IR not proven equivalent: $(cat equiv.out)"
ok "check_ir_equivalence_main proves opt_main's output equivalent"

# --- 5: quickcheck proof, formatter -----------------------------------------
"$bin/prove_quickcheck_main" smoke.x > qc.out 2>&1 \
    || fail "prove_quickcheck_main: $(cat qc.out)"
grep -q "0 failed" qc.out || fail "prove_quickcheck_main did not prove the quickcheck: $(cat qc.out)"
ok "prove_quickcheck_main proves the #[quickcheck]"

"$bin/dslx_fmt" smoke.x > fmt.x || fail "dslx_fmt exited non-zero"
diff -u smoke.x fmt.x || fail "dslx_fmt is not a fixed point on tests/smoke.x"
ok "dslx_fmt round-trips smoke.x unchanged"

# --- 6: libxls --------------------------------------------------------------
# A real C-API call, not just a dlopen: a DSO that loads but whose exports were
# mangled by the repack would pass a load-only check. The expected answer is
# the same name codegen_main gave the module above.
dso="$pkg/lib/libxls.so"
[ -e "$dso" ] || fail "missing $dso"
python3 - "$dso" <<'PY' || fail "libxls failed its C-API check"
import ctypes, sys
lib = ctypes.CDLL(sys.argv[1])
f = lib.xls_mangle_dslx_name
f.restype = ctypes.c_bool
f.argtypes = [ctypes.c_char_p, ctypes.c_char_p,
              ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_void_p)]
err, out = ctypes.c_void_p(), ctypes.c_void_p()
if not f(b"smoke", b"add_sat", ctypes.byref(err), ctypes.byref(out)):
    sys.exit("xls_mangle_dslx_name failed: %r" % ctypes.string_at(err.value))
got = ctypes.string_at(out.value)
if got != b"__smoke__add_sat":
    sys.exit("xls_mangle_dslx_name returned %r" % got)
PY
ok "libxls loads and answers xls_mangle_dslx_name"

echo "SMOKE PASS"

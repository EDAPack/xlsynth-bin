"""Unit tests for scripts/xlsynth-behavior-diff.py.

Pure-function tests over captured `--helpfull` / stdlib / `nm` text; nothing
here runs a binary or touches the network, so they hold on any host. The
fixtures are real output shapes from the v0.59.0 binaries and stdlib, trimmed.
"""

import importlib.util
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "xlsynth-behavior-diff.py"


def _load():
    spec = importlib.util.spec_from_file_location("behavior_diff", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    sys.modules["behavior_diff"] = mod
    spec.loader.exec_module(mod)
    return mod


bd = _load()


# --------------------------------------------------------------------------- #
# --helpfull
# --------------------------------------------------------------------------- #
HELP_OLD = """\
codegen_main:
Generates Verilog RTL from a given IR file.

  Flags from external/abseil-cpp+/absl/flags/parse.cc:
    --flagfile (comma-separated list of files to load flags from); default: ;

  Flags from xls/common/logging/log_flags.cc:
    --logtostderr (log messages go to stderr instead of logfiles);
      default: false;

  Flags from xls/tools/codegen_flags.cc:
    --generator (The generator to use when emitting the device function. Valid
      values: pipeline, combinational.); default: "pipeline";
    --use_system_verilog (If true, emit SystemVerilog otherwise emit Verilog.);
      default: false;
"""

HELP_NEW = """\
codegen_main:
Generates Verilog RTL from a given IR file.

  Flags from external/abseil-cpp+/absl/flags/parse.cc:
    --flagfile (comma-separated list of files to load flags from); default: ;
    --brand_new_absl_flag (noise); default: ;

  Flags from xls/common/logging/log_flags.cc:
    --logtostderr (log messages go to stderr instead of logfiles);
      default: false;

  Flags from xls/tools/codegen_flags.cc:
    --generator (The generator to use when emitting the device function. Valid
      values: pipeline, combinational.); default: "combinational";
    --emit_sv_types (Emit SV types.); default: true;
"""


def test_parse_flags_keeps_only_xls_sources():
    parsed = bd.parse_flags(HELP_OLD)
    assert set(parsed) == {"xls/common/logging/log_flags.cc", "xls/tools/codegen_flags.cc"}
    assert parsed["xls/tools/codegen_flags.cc"]["generator"] == '"pipeline"'


def test_parse_flags_default_on_continuation_line():
    parsed = bd.parse_flags(HELP_OLD)
    assert parsed["xls/common/logging/log_flags.cc"]["logtostderr"] == "false"
    assert parsed["xls/tools/codegen_flags.cc"]["use_system_verilog"] == "false"


def _diff(old_by_tool, new_by_tool):
    of, ou = bd.merge_flag_sources(old_by_tool)
    nf, nu = bd.merge_flag_sources(new_by_tool)
    return bd.diff_flags(of, nf, ou, nu)


def test_diff_flags_added_removed_redefaulted_and_no_absl_noise():
    changes = _diff({"codegen_main": bd.parse_flags(HELP_OLD)},
                    {"codegen_main": bd.parse_flags(HELP_NEW)})
    assert "`codegen_main`: new flag `--emit_sv_types`" in changes
    assert "`codegen_main`: flag `--use_system_verilog` removed" in changes
    assert ('`codegen_main`: `--generator` default `"pipeline"` → `"combinational"`'
            in changes)
    assert not any("absl" in c for c in changes)
    assert len(changes) == 3


def test_shared_flag_source_reported_once_with_tool_count():
    old_src = {"xls/common/logging/log_flags.cc": {"logtostderr": "false"}}
    new_src = {"xls/common/logging/log_flags.cc": {"logtostderr": "true"}}
    tools = ["a_main", "b_main", "c_main", "d_main", "e_main"]
    changes = _diff({t: old_src for t in tools}, {t: new_src for t in tools})
    assert changes == ["5 tools: `--logtostderr` default `false` → `true`"]


def test_flag_moving_between_source_files_is_not_reported():
    old = {"opt_main": {"xls/tools/opt_flags.cc": {"top": '""'}}}
    new = {"opt_main": {"xls/tools/common_flags.cc": {"top": '""'}}}
    assert _diff(old, new) == []


def test_identical_flags_diff_empty():
    parsed = {"codegen_main": bd.parse_flags(HELP_NEW)}
    assert _diff(parsed, parsed) == []


# --------------------------------------------------------------------------- #
# DSLX stdlib
# --------------------------------------------------------------------------- #
STD_OLD = """\
// Copyright header. pub fn not_real() -- inside a comment.
import std;

pub struct APFloat<EXP_SZ: u32, FRACTION_SZ: u32> {
    sign: bits[1],  // Sign bit.
    bexp: bits[EXP_SZ],
}

impl APFloat<EXP_SZ, FRACTION_SZ> {
    const EXP_SIZE = EXP_SZ;
    pub fn is_zero(self) -> bool { self.bexp == bits[EXP_SZ]:0 }
}

pub type BF16 = APFloat<u32:8, u32:7>;
pub const F64_EXP_SZ = u32:11;  // Exponent bits

pub fn signed_max_value<N: u32, N_MINUS_ONE: u32 = {N - 1}>() -> sN[N] {
    ((sN[N]:1 << N_MINUS_ONE) - 1) as sN[N]
}

pub fn abs<EXP_SZ: u32, FRACTION_SZ: u32>
    (x: APFloat<EXP_SZ, FRACTION_SZ>) -> APFloat<EXP_SZ, FRACTION_SZ> {
    trace_fmt!("abs {}", x);
    APFloat { sign: u1:0, ..x }
}

fn private_helper(x: u8) -> u8 { x }

pub fn gone(x: u8) -> u8 { x }
"""


def test_parse_module_finds_every_public_kind():
    api = bd.parse_module(STD_OLD)
    assert set(api) == {"APFloat", "APFloat::is_zero", "BF16", "F64_EXP_SZ",
                        "signed_max_value", "abs", "gone"}
    assert api["APFloat"][0] == "struct"
    assert api["BF16"] == ("type", "pub type BF16=APFloat<u32:8,u32:7>;")
    assert api["F64_EXP_SZ"] == ("const", "pub const F64_EXP_SZ=u32:11;")


def test_parse_module_signature_stops_at_body_despite_braced_generics():
    api = bd.parse_module(STD_OLD)
    assert api["signed_max_value"][1] == \
        "pub fn signed_max_value<N:u32,N_MINUS_ONE:u32={N - 1}>()->sN[N]"
    # Multi-line signature; the body (with a format string holding braces)
    # does not leak in.
    assert api["abs"][1] == ("pub fn abs<EXP_SZ:u32,FRACTION_SZ:u32>"
                             "(x:APFloat<EXP_SZ,FRACTION_SZ>)->APFloat<EXP_SZ,FRACTION_SZ>")


def test_reformatting_is_not_a_change():
    reflowed = STD_OLD.replace(
        "pub fn gone(x: u8) -> u8 { x }",
        "pub fn gone(\n    x: u8,\n) -> u8 {\n    x\n}")
    assert bd.parse_module(reflowed) == bd.parse_module(STD_OLD)


def test_diff_stdlib():
    std_new = (STD_OLD
               .replace("pub fn gone(x: u8) -> u8 { x }\n", "")
               .replace("bexp: bits[EXP_SZ],", "bexp: bits[EXP_SZ],\n    fraction: bits[FRACTION_SZ],")
               + "\npub fn fresh(x: u8) -> u8 { x }\n")
    old = {"apfloat": bd.parse_module(STD_OLD), "dropped": {}}
    new = {"apfloat": bd.parse_module(std_new), "added_mod": {"f": ("fn", "pub fn f()")}}
    changes = bd.diff_stdlib(old, new)
    assert "new module `added_mod` (1 public items)" in changes
    assert "module `dropped` removed" in changes
    assert "`apfloat::fresh` added (fn)" in changes
    assert "`apfloat::gone` removed" in changes
    assert any(c.startswith("`apfloat::APFloat` changed:") and "fraction" in c
               for c in changes)
    assert len(changes) == 5


# --------------------------------------------------------------------------- #
# libxls symbols
# --------------------------------------------------------------------------- #
NM = """\
00000000046a1f10 T xls_aot_compile_function
00000000046a2000 T xls_mangle_dslx_name
00000000046a3000 T _ZN3xls8internal6HelperEv
0000000000000000 U malloc
00000000046a4000 W xls_weak_one
"""


def test_parse_nm_keeps_defined_xls_symbols_only():
    assert bd.parse_nm(NM) == {"xls_aot_compile_function", "xls_mangle_dslx_name",
                               "xls_weak_one"}


def test_diff_symbols():
    old = bd.parse_nm(NM)
    new = (old - {"xls_weak_one"}) | {"xls_new_api"}
    assert bd.diff_symbols(old, new) == [
        "new C-API function `xls_new_api`",
        "C-API function `xls_weak_one` removed",
    ]


# --------------------------------------------------------------------------- #
# Rendering
# --------------------------------------------------------------------------- #
def _surface(tools=("opt_main",), flags=None, stdlib=None, symbols=None):
    per_tool = flags if flags is not None else {}
    return {"tools": set(tools), "flags": bd.merge_flag_sources(per_tool),
            "stdlib": stdlib if stdlib is not None else {},
            "symbols": symbols if symbols is not None else {"xls_a"}}


def test_no_changes_is_said_explicitly():
    s = _surface()
    sections, notes = bd.build_sections(s, s)
    out = bd.render(sections, notes, "v0.58.0")
    assert "## Behavior changes" in out
    assert "No tool, command-line-flag, DSLX-stdlib or C-API changes" in out
    assert "`v0.58.0`" in out


def test_render_groups_sections_and_reports_new_tool():
    old = _surface(tools=("opt_main",))
    new = _surface(tools=("opt_main", "new_main"), symbols={"xls_a", "xls_b"})
    sections, notes = bd.build_sections(old, new)
    out = bd.render(sections, notes, "")
    assert "**Tools**" in out and "- new tool `new_main`" in out
    assert "**libxls C API**" in out and "`xls_b`" in out
    assert "**Command-line flags**" not in out


def test_missing_symbols_produce_a_note_not_a_crash():
    old = _surface()
    new = _surface()
    new["symbols"] = None
    sections, notes = bd.build_sections(old, new)
    assert any("not compared" in n for n in notes)

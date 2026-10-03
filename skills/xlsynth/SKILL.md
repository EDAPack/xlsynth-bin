---
name: xlsynth
description: XLS / xlsynth high-level synthesis toolchain — compiles DSLX (a Rust-like hardware DSL) through XLS IR and an optimizer into combinational or pipelined Verilog/SystemVerilog, with a DSLX interpreter, formal equivalence and quickcheck proving, a formatter and a language server. Use when writing or testing DSLX, converting DSLX to IR, optimizing IR, generating RTL from DSLX/IR, proving an optimization or a property, or linking against libxls (xlsynth-crate). Installed from the xlsynth-bin package.
license: Apache-2.0
version: "1.0.0"
---

# xlsynth — Agent Skill

## When to use this skill
- The user writes hardware in **DSLX** (`.x` files) and wants it
  typechecked, tested, formatted, or turned into **Verilog**.
- The user has **XLS IR** (`.ir`) and wants it optimized, scheduled into a
  pipeline, or emitted as RTL.
- The user wants to **prove** something: that optimized IR equals the
  original (`check_ir_equivalence_main`), or that a DSLX `#[quickcheck]`
  property holds for *all* inputs (`prove_quickcheck_main`).
- The user builds Rust against **xlsynth-crate** and wants it to use the
  installed libxls instead of downloading one.

Do **not** reach for xlsynth when:
- The user wants to simulate or lint existing SystemVerilog. Use
  `verilator`, `iverilog` or `verible`. XLS *emits* Verilog and does not read it.
- The user wants logic synthesis to gates. That's `yosys`. XLS stops at RTL.

## Core mental model

One pipeline, with every stage available as its own tool and every
intermediate kept as a readable text file:

```
 .x ──typecheck_main──► (types OK)
 .x ──dslx_interpreter_main──► runs #[test]s
 .x ──ir_converter_main──► .ir ──opt_main──► .opt.ir ──codegen_main──► .v/.sv
                                  └──check_ir_equivalence_main──┘ (.ir ≡ .opt.ir?)
 .x ──prove_quickcheck_main──► SMT proof of #[quickcheck] properties
```

Consequences worth knowing up front:

1. **Names get mangled.** DSLX function `add_sat` in `smoke.x` becomes IR
   function `__smoke__add_sat`, and the Verilog module gets the same name
   unless you pass `--module_name`. Pass `--top=<dslx name>` to
   `ir_converter_main`. Downstream tools see the mangled name.
2. **Combinational vs pipeline is a codegen choice**, not a source choice.
   The same `.opt.ir` gives either one. A pipeline needs a delay model plus
   `--pipeline_stages` and/or `--clock_period_ps`.
3. **Every tool prints `redacted` for `--version`.** The installed release's
   `manifest.json` (or the xlsynth-bin release tag) is the version.

## The stdlib, and why some tools are wrappers

DSLX's `import std;` (and `apfloat`, `float32`, …) is resolved against
`--dslx_stdlib_path`, whose upstream default is a path **relative to the
current directory**. In xlsynth-bin, five tools are small wrappers in
`bin/` that pass the bundled stdlib: `typecheck_main`, `dslx_interpreter_main`,
`ir_converter_main`, `prove_quickcheck_main`, and `dslx_ls` (whose flag is
spelled `--stdlib_path`). So `import std;` just works.

- An explicit `--dslx_stdlib_path=…` still overrides it (the last flag wins).
- Your *own* modules are found through `--dslx_path=dir1:dir2`, not through
  the stdlib path.
- The bundled stdlib is also at `$DSLX_STDLIB_PATH`.

## Quick start

```sh
typecheck_main design.x                       # types only
dslx_interpreter_main design.x                # run every #[test]
dslx_interpreter_main --test_filter='add_.*' design.x

ir_converter_main --top=add_sat design.x > design.ir
opt_main design.ir > design.opt.ir
check_ir_equivalence_main design.ir design.opt.ir   # "Verified equivalent"

# combinational RTL to stdout
codegen_main --generator=combinational --delay_model=unit design.opt.ir

# 2-stage pipeline, SystemVerilog, synchronous reset, named module
codegen_main --generator=pipeline --delay_model=unit --pipeline_stages=2 \
    --reset=rst --use_system_verilog --module_name=add_sat_pipe \
    --output_verilog_path=add_sat_pipe.sv \
    --output_signature_path=add_sat_pipe.sig.textproto design.opt.ir

prove_quickcheck_main design.x                # prove all #[quickcheck]s
dslx_fmt -i design.x                          # format in place
dslx_fmt --error_on_changes design.x          # CI gate
```

## Tool reference

| Tool | Input → output | Flags that matter |
|---|---|---|
| `typecheck_main` | `.x` → type info | `--dslx_path` |
| `dslx_interpreter_main` | `.x` → test results | `--test_filter`, `--compare=jit\|interpreter`, `--warnings_as_errors` |
| `ir_converter_main` | `.x` → `.ir` (stdout) | `--top`, `--output_file`, `--package_name`, `--convert_tests` |
| `opt_main` | `.ir` → `.ir` (stdout) | `--top`, `--passes`, `--skip_passes` |
| `codegen_main` | `.ir` → Verilog | `--generator=combinational\|pipeline`, `--delay_model`, `--pipeline_stages`, `--clock_period_ps`, `--clock_margin_percent`, `--module_name`, `--use_system_verilog`, `--reset`, `--reset_active_low`, `--reset_asynchronous`, `--flop_inputs`, `--flop_outputs`, `--output_verilog_path`, `--output_signature_path`, `--output_schedule_path` |
| `block_to_verilog_main` | block IR → Verilog | `--output_verilog_path` |
| `delay_info_main` | `.ir` → critical path | `--delay_model`, `--top`, `--schedule_path` |
| `check_ir_equivalence_main` | two `.ir` → proof | `--top` (strongly recommended with several functions) |
| `prove_quickcheck_main` | `.x` → proof or counterexample | `--test_filter`, `--solver_num_threads` |
| `dslx_fmt` | `.x` → formatted `.x` | `-i`, `--error_on_changes` |
| `dslx_ls` | LSP over stdio | `--dslx_path` |
| `highlight_main` | `.x` → ANSI-colored text | — |

Delay models built in: **`unit`** (every op costs 1 ps, which is portable and
good for structure), **`asap7`** and **`sky130`** (characterized processes).
`--clock_period_ps` is only meaningful with a characterized model.

## Traps

- **Always pass `--top` to `ir_converter_main`.** Without it every function
  is converted and none is marked `top`, so `opt_main` fails with
  `Top entity not set for package`. With it, the IR carries a `top fn` and
  every downstream tool picks it up. To re-target IR that already exists,
  pass `--top=__mod__fn` (the mangled name) to `opt_main` / `codegen_main`.
- **`#[quickcheck]` is skipped by the interpreter** unless the JIT is in use,
  and the interpreter says so (`SKIPPING QUICKCHECKS`). Don't read a green
  interpreter run as "properties hold". Use `prove_quickcheck_main` for that.
- **Warnings are errors by default** in several tools
  (`--warnings_as_errors=true`). Unused bindings and similar fail the run.
  Fix them, or narrowly `--disable_warnings=<name>`.
- **`dslx_fmt` doesn't resolve imports**, so it has no stdlib flag. That's
  expected.

## Using libxls from Rust (xlsynth-crate)

xlsynth-bin's `export.envrc` (loaded through direnv) exports `XLS_DSO_PATH`
(`lib/libxls.so`; on macOS a symlink to `libxls.dylib`) and
`DSLX_STDLIB_PATH`. When **both** are set, xlsynth-crate's build script links
against them instead of downloading libxls.

**The versions must match.** Each xlsynth-crate release pins one xlsynth tag
(`RELEASE_LIB_VERSION_TAG` in `xlsynth-sys/build.rs`). Use the xlsynth-bin
release with that same tag. A mismatched libxls may link and then misbehave.
If you can't match them, `unset XLS_DSO_PATH DSLX_STDLIB_PATH` for the cargo
build and let the crate download its own.

For C/C++ ahead-of-time compiled code: `lib/libxls_aot_runtime.a`, with link
requirements in `share/xlsynth/libxls_aot_runtime_link.toml` and sources in
`share/xlsynth/xls-aot-runtime-source.tar.gz`.

See `references/dslx-primer.md` for DSLX syntax.

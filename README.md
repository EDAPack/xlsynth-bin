# xlsynth-bin

[xlsynth](https://github.com/xlsynth/xlsynth), the xlsynth distribution of
Google's [XLS](https://google.github.io/xls/) high-level synthesis toolchain,
packaged for [edapack](https://dvkit.org/edapack/).

DSLX in, Verilog out: twelve tools, plus the libxls C-API library and the
DSLX standard library.

```
typecheck_main         dslx_interpreter_main   ir_converter_main   opt_main
codegen_main           block_to_verilog_main   delay_info_main
check_ir_equivalence_main   prove_quickcheck_main
dslx_fmt               dslx_ls                 highlight_main
```

## This package repacks; it does not build

xlsynth already publishes prebuilt binaries for the platforms it supports.
Building XLS ourselves means Bazel plus LLVM, hours per build, and a libxls
that would no longer be the one xlsynth-crate was tested against. CI instead
downloads upstream's release assets, verifies each against upstream's own
`.sha256`, lays them out as a package, injects the edapack consumer contract,
smoke-tests, and publishes. The whole repack is `scripts/build.sh`.

Upstream ships ~20 loose files per platform, not an archive, so the repack
does more than strip a prefix:

| In the release | Why |
|---|---|
| `bin/` | The 12 tools. Five are 3-line wrappers (below); the real executables are in `libexec/xlsynth/`. |
| `lib/libxls.so` | The C-API library, gunzipped and checksum-verified. On macOS this is a symlink to `libxls.dylib`. |
| `lib/libxls_aot_runtime.a`, `share/xlsynth/` | The AOT runtime, its link requirements and sources. |
| `share/xlsynth/dslx_stdlib/` | The DSLX standard library (`std.x`, `apfloat.x`, …). |
| `ivpm.yaml` | The consumer manifest `ivpm` reads for an installed package. |
| `manifest.json` | The exact upstream tag and commit SHA. This is the only version record: every tool prints `redacted` for `--version`. |
| `skills/` | An Agent Skill covering the whole toolchain. |
| `export.envrc` | Puts `bin/` on `PATH` and exports `DSLX_STDLIB_PATH` and `XLS_DSO_PATH`. ivpm sources it for every installed dependency. |

### Why five tools are wrappers

The tools that resolve DSLX imports default to a stdlib path **relative to the
working directory** (`xls/dslx/stdlib`), so outside an XLS source checkout
`import std;` fails. `typecheck_main`, `dslx_interpreter_main`,
`ir_converter_main`, `prove_quickcheck_main` and `dslx_ls` are wrappers that
pass the bundled stdlib. Your own `--dslx_stdlib_path` still wins, because the
wrapper's flag comes first and absl keeps the last value. `build.sh` checks the
wrapper table against every tool's `--helpfull` on each build, so a renamed
flag or a new DSLX-reading tool fails the build instead of shipping broken.

`docs/plan.md` has the full reasoning.

## Platforms

| Target | Upstream suffix | Smoke-tested in CI |
|---|---|---|
| `linux-x86_64` | `-rocky8` | yes, in `manylinux_2_28` |
| `macos-arm64` | `-arm64` | yes, on macos-14 |

The Linux binaries are dynamically linked against glibc, with no `libstdc++`
dependency. They need **glibc 2.27 or newer**; `build.sh` checks every shipped
file and fails if any needs more than the 2.28 the manifest records. Upstream
also uploads a `-ubuntu2004` build. We ship `-rocky8` because Rocky 8 is the
older glibc base (2.28, against Ubuntu 20.04's 2.31).

**Not available: Linux aarch64, Windows, macOS x86_64.** Upstream doesn't build
them, and this package doesn't build from source. See `docs/plan.md`.

## Releases

One track. CI runs **every Monday** and repacks the newest xlsynth release we
have not already published. A week with no upstream release is a no-op.
Versions and tags are upstream's, verbatim (`v0.59.0`). `latest` always points
at the newest repack.

To pick up a release out of band, run the CI workflow by hand. It takes an
optional `core_ref` (a specific upstream tag) and a `force` flag.

A fix to the *package* rather than to xlsynth ships as a **packaging
revision**. Run the workflow with `core_ref: v0.59.0`, `revision: 1` and a
`revision_note`, and it publishes `v0.59.0.1`: the same upstream binaries,
repackaged, with the note in the release body. The revision is a fourth
component, never a bumped patch, so it can't collide with upstream's own next
release.

### Release notes

xlsynth has no changelog, and every upstream release body reads "Automated
release of vX". The notes here are assembled from what does exist:

- **Upstream changes.** The commits between the upstream release we last
  repacked and this one: cherry-picks of Google XLS pull requests
  (`[XLS PR #5055] build: …`) next to xlsynth's own changes (`dslx: …`). This
  is edapack-common's `release_notes: gh-compare` mode.
- **Behavior changes.** What changes for *you*, diffed out of the two
  releases' artifacts rather than read from the commit log: tools added or
  removed; command-line flags added, removed or re-defaulted (XLS's own flags
  only, grouped by the file that declares them); public DSLX stdlib
  declarations added, removed or changed; and `xls_*` C-API functions added or
  removed. See `scripts/xlsynth-behavior-diff.py`.
- **Assets.** Every tarball with its size and SHA-256.

## Consuming it

```yaml
# ivpm.yaml
package:
  name: my-project
  dep-sets:
  - name: default
    deps:
    - name: xlsynth-bin
      url: https://github.com/edapack/xlsynth-bin
      src: gh-rls
```

`ivpm update` selects the right asset for the host. Through direnv, the
package's `export.envrc` puts `bin/` on `PATH` and exports `DSLX_STDLIB_PATH`
and `XLS_DSO_PATH`.

### With xlsynth-crate (Rust)

When both `XLS_DSO_PATH` and `DSLX_STDLIB_PATH` are set, xlsynth-crate's build
script links against them instead of downloading libxls, so `cargo build` can
work offline. **The versions must match:** each xlsynth-crate release pins one
xlsynth tag (`RELEASE_LIB_VERSION_TAG` in `xlsynth-sys/build.rs`). Install the
xlsynth-bin release with that tag. If you can't, unset both variables for the
cargo build and let the crate download its own.

## Building locally

```sh
ivpm update -a                            # fetches edapack-common into packages/
EC_IMAGE_NAME=linux-x86_64 scripts/build.sh
core_ref=v0.58.0 EC_IMAGE_NAME=linux-x86_64 scripts/build.sh   # a specific tag
```

Targets are `linux-x86_64` and `macos-arm64`. With `EC_IMAGE_NAME` unset, the
host's own target is inferred. Output lands in `dist/` (about 190 MB per
platform), scratch goes in `.build/`, and nothing is written into the source
tree. Any target can be repacked from any host; the smoke test and the
wrapper-table check are skipped when the host cannot execute what it packed.

## Testing

`tests/run_smoke_test.sh` runs inside every repack CI can execute. From a
scratch directory, so a CWD-relative stdlib can't make it pass by accident, it:

- checks that all 12 tools start;
- typechecks a file that does `import std;` with no flags;
- confirms an explicit `--dslx_stdlib_path` overrides the bundled one;
- runs a DSLX `#[test]`;
- takes the design DSLX → IR → optimized IR → Verilog;
- **proves the optimizer's output equivalent to its input**;
- proves a `#[quickcheck]` property;
- checks that `dslx_fmt` round-trips unchanged;
- makes a real libxls C-API call.

```sh
tests/run_smoke_test.sh /path/to/xlsynth-bin      # the package root, not bin/
python3 -m pytest tests -q                        # behavior-diff unit tests
python3 scripts/check-repo.py                     # repo contracts
```

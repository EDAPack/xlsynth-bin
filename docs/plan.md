# xlsynth-bin: research findings and release plan

Status: **Phases 0–3 implemented**, 2026-10-03. A local `linux-x86_64` repack
of v0.59.0 passes end to end. Phase 4 (first published release) has not
happened yet. Modeled on `../verible-bin` (read its `docs/plan.md` first; this
document only records where xlsynth differs).

Decisions taken: **A** wrappers, **B** weekly, **C** ship libxls + AOT runtime.
Building from source was considered and rejected for the two platforms
upstream ships (see Phase 5).

Things implementation turned up that the research below did not predict:

1. **rocky8 and ubuntu2004 are not reliably identical**, so the planned
   "assert the twin matches" check was dropped. v0.59.0 uploaded one build
   twice, but v0.55.0 built them separately and non-reproducibly: same size,
   same NEEDED libs, same GLIBC_2.25 requirement, millions of differing bytes.
   That check would have blocked a good release. We ship rocky8 (Rocky 8 is a
   glibc 2.28 base, Ubuntu 20.04 a 2.31 one), and the all-files glibc floor
   check guards the property that actually matters. Found by repacking
   v0.55.0 for the release-notes test.
2. **Every tool exits 1 after `--helpfull`** (absl's design), so the smoke test
   judges "does it start" by the help text, not the exit code.
3. **`opt_main --list_passes` prints uninitialized memory** among the pass
   names, so the pass list is not in the behavior diff (Finding 5's table).
4. **xlsynth-crate pins one xlsynth tag** (`RELEASE_LIB_VERSION_TAG`), so the
   `XLS_DSO_PATH` override is only valid when versions match. This is now in
   the README and the skill. The crate also needs `DSLX_STDLIB_PATH` to be the
   directory holding `std.x` (what we ship), and turns `XLS_DSO_PATH` into
   `-L <dir> -l xls`. That is why the macOS `lib/libxls.so → libxls.dylib`
   symlink works. libxls has no SONAME, so the path the crate's `-rpath`
   points at is what gets loaded.
5. **`dslx_ls` spells its flag `--stdlib_path`.** The other four DSLX tools
   use `--dslx_stdlib_path`. `dslx_fmt` resolves no imports and takes neither.
6. Measured size: **191 MB** tarball / 518 MB unpacked for `linux-x86_64`.
7. **`gh-compare` mis-rendered windows containing Copybara merges.** Fixed in
   edapack-common `main` (1ba3ea1), **not yet in `@v1`**. v0.55.0→v0.59.0 had
   rendered as seven `PiperOrigin-RevId: 98…` "pull requests". google/xls PRs
   land in xlsynth as Copybara merges whose only body line is a trailer, and
   merge mode "won wholesale". Once those were skipped, xlsynth's 12 own
   squash-merged PRs won instead and hid 76 cherry-picks. The fix: trailer-only
   merges are not PRs; squash mode needs at least half the range; PR numbers
   are qualified with the upstream slug, because a bare `#N` autolinks to the
   package repo (this already affected verible-bin). The window now lists 88
   commit subjects (40 shown). Until `v1` moves, xlsynth-bin's releases still
   use the old script. That only matters from the second release, because
   the first has nothing to compare against.

## The question

[xlsynth/xlsynth](https://github.com/xlsynth/xlsynth) (the xlsynth fork of
Google XLS) already publishes prebuilt binaries. Can `xlsynth-bin` repack
them the way `verible-bin` repacks Verible?

Short answer: **yes, repack, don't build.** Same shape as verible-bin: download
upstream assets in CI, rearrange them, add edapack's metadata, smoke test,
publish. The differences come from upstream's asset shape, which is less
convenient than Verible's (Findings 1, 2 and 4). Release notes take more work
than they did for Verible (Finding 5).

## What upstream ships

Release `v0.59.0`, published 2026-09-26. The release body is the boilerplate
line `Automated release of v0.59.0`. **The assets are loose files, not
archives.** Each has a `.sha256` sidecar.

| Asset pattern | What it is |
|---|---|
| `<tool>-rocky8`, `<tool>-ubuntu2004` | Linux x86_64 ELF executables, 12 tools |
| `<tool>-arm64` | macOS arm64 Mach-O executables, same 12 tools |
| `libxls-{rocky8,ubuntu2004}.so.gz`, `libxls-arm64.dylib.gz` | the libxls C-API shared library (gzipped) |
| `libxls_aot_runtime-<plat>.a` + `libxls_aot_runtime_link-<plat>.toml` | static AOT runtime and its link requirements |
| `dslx_stdlib.tar.gz` | DSLX standard library sources (`xls/dslx/stdlib/*.x`, 12 files) |
| `xls-aot-runtime-source.tar.gz` | AOT runtime sources |
| `libxls-runtime-<plat>.tar.gz` + `-manifest.json` | currently **empty** (45 bytes; `runtime_files: []`) |

The 12 tools: `block_to_verilog_main check_ir_equivalence_main codegen_main
delay_info_main dslx_fmt dslx_interpreter_main dslx_ls highlight_main
ir_converter_main opt_main prove_quickcheck_main typecheck_main`.

Size per platform: about 424 MB of Linux executables plus a 119 MB `libxls.so`,
so a little over 0.5 GB unpacked. Verible's is about 17 MB. The tools are
statically linked against XLS, so the compressed size matters (see Risks).

Cadence: 40 releases between 2025-11-10 and 2026-09-26, roughly 3 a month,
sometimes bursty (v0.58.0 and v0.59.0 came 13 hours apart). Tags are real
semver (`vX.Y.Z`), not Verible-style commit counts.

## Finding 1: only two edapack platforms exist upstream

| edapack target | Upstream suffix | Notes |
|---|---|---|
| `linux-x86_64` | `-rocky8` | `-ubuntu2004` was byte-identical in v0.59.0, but not in v0.55.0 (see correction below) |
| `macos-arm64` | `-arm64` | `arm64` here means **macOS**, not Linux aarch64. Deployment minimum is macOS 11.0 (upstream XLS PR #5055) |

There is **no Linux aarch64, no Windows and no macOS x86_64**. All three would
need a from-source Bazel+LLVM build of XLS, which is far heavier than Verible's
Phase 3. Deferred (Phase 5).

**Correction (implementation):** identical in v0.59.0, but not in v0.55.0,
where upstream built the two separately and the builds are not reproducible.
The build ships `-rocky8` (the older glibc base) and does not cross-check
against `-ubuntu2004`; see item 1 at the top.

## Finding 2: Linux binaries are dynamic, with a glibc 2.27 floor

Unlike Verible, these are not static:

```
dslx_fmt-rocky8: ELF 64-bit LSB pie executable, x86-64, dynamically linked
NEEDED libpthread.so.0 libdl.so.2 libm.so.6 libc.so.6 [+ librt.so.1 for libxls.so]
highest symbol version: GLIBC_2.27 (sampled: dslx_fmt, typecheck_main, libxls.so)
```

No `libstdc++` dependency, so the C++ runtime is linked in statically. That
makes the real floor **glibc 2.27**, which comfortably covers manylinux_2_28.
Doing the repack and smoke test inside `quay.io/pypa/manylinux_2_28_x86_64`
proves the binaries run on that floor. `build.sh` checks the highest GLIBC
version across **every** ELF file it ships, not just the sampled ones, fails if
any exceed 2.28, and records `libc: glibc_2.28` in `platform.json`.

## Finding 3: the DSLX stdlib is not embedded

```
$ typecheck_main t.x          # t.x: `import std;`
ImportError: Could not find DSLX file for import; attempted: [ xls/dslx/stdlib/std.x ...]
    --dslx_stdlib_path (Path to DSLX standard library); default: "xls/dslx/stdlib"
```

The default is a path **relative to the working directory**, which only works
inside an XLS source checkout. So a repack that just puts the 12 tools on
`PATH` gives users DSLX tools that fail on the first `import std;`. The package
has to ship the stdlib and point the tools at it (Decision A).

Also, every tool's `--version` prints `redacted`. The binaries carry no version
stamp, so the smoke test cannot check "is this the version we meant to ship".
`manifest.json` is the only record of that, together with the upstream
checksum verification (Finding 4).

## Finding 4: a consumer contract that's worth more than Verible's

[xlsynth-crate](https://github.com/xlsynth/xlsynth-crate)'s `build.rs` reads
`XLS_DSO_PATH` and `DSLX_STDLIB_PATH`. When both are set, it uses those files
instead of downloading libxls at `cargo build` time. If an installed
`xlsynth-bin` exports both, Rust users of the crate build offline against the
same libxls the CLI tools came from. ivpm supports `value:` env directives
(`ivpm_yaml_reader.py`), so this needs only the consumer manifest:

```yaml
# scripts/release-ivpm.yaml
package:
  name: xlsynth-bin
  env:
  - name: PATH
    path-prepend: "${IVPM_PACKAGES}/xlsynth-bin/bin"
  - name: DSLX_STDLIB_PATH
    value: "${IVPM_PACKAGES}/xlsynth-bin/share/xlsynth/dslx_stdlib"
  - name: XLS_DSO_PATH
    value: "${IVPM_PACKAGES}/xlsynth-bin/lib/libxls.so"   # .dylib on macOS: see Risks
```

To verify in Phase 1: the exact filename xlsynth-crate expects at
`XLS_DSO_PATH`, and whether `DSLX_STDLIB_PATH` names the directory holding
`std.x` or its `xls/dslx/stdlib` grandparent.

ivpm `gh-rls` cannot consume upstream directly in any case. It selects
archives by platform token, and these are loose, gzipped or bare files with a
`rocky8`/`arm64` naming scheme it does not know. So there is no
"no repo at all" alternative here like the one verible-bin considered.

## Finding 5: release notes need building

| Source | Status |
|---|---|
| Changelog file in the tree | none |
| Upstream release body | boilerplate (`Automated release of vX`) on every release |
| Commit history | **useful**. Linear and readable. Two kinds of subject: `[XLS PR #5055] build: raise the macOS deployment minimum to 11.0` (cherry-picks of google/xls PRs) and xlsynth's own `dslx: reject unreachable match patterns ...` |

edapack-common's `release_notes: gh-compare` works today with no changes.
These subjects do not match either PR shape it recognizes (`Merge pull request
#N`, `... (#N)`), so it falls back to **commit subjects**, which is the right
output here. One limit to know about: it shows 40 entries and then
"…and N more". v0.55.0→v0.58.0 was 94 commits. A weekly cadence keeps most
windows well under that.

As with Verible, the more useful section comes from the binaries: what changes
for a *user*. That goes in `scripts/release-notes-hook.sh` plus
`scripts/xlsynth-behavior-diff.py`, which diff this build against the previous
release's `linux-x86_64` tarball:

| Diffed | How | Why a user cares |
|---|---|---|
| Tool set | `ls bin/` | a tool added or removed |
| Command-line flags, per tool | `--helpfull`, keeping only the `Flags from xls/...` groups (dropping absl/LLVM noise) | flags added, removed or re-defaulted. The XLS CLI changes often |
| DSLX stdlib | file list + `pub fn` / `pub struct` / `pub type` signatures per module | DSLX code that imports `std`, `apfloat`, etc. may stop typechecking |
| libxls C API | exported `xls_*` symbols (`nm -D`) | xlsynth-crate / FFI consumers |
| ~~opt pass list~~ | dropped: `--list_passes` output contains uninitialized memory | — |

"No behavior changes detected" is stated explicitly, as in verible-bin.

So the release body becomes:

```
Automated build of xlsynth-bin 0.59.0.
Upstream: https://github.com/xlsynth/xlsynth/releases/tag/v0.59.0

## Upstream changes          <- release-notes.py gh-compare (commit subjects)
## Behavior changes          <- hook: binary diff vs previous release
## Assets                    <- hook: per-platform tarball, size, SHA-256
```

## Release layout

```
xlsynth-bin/
  bin/                     12 tools (or wrappers, Decision A)
  lib/libxls.so|.dylib     gunzipped; checksum verified against upstream's
                           uncompressed .sha256 (both are published)
  lib/libxls_aot_runtime.a
  share/xlsynth/dslx_stdlib/*.x
  share/xlsynth/libxls_aot_runtime_link.toml
  share/xlsynth/xls-aot-runtime-source.tar.gz
  ivpm.yaml  manifest.json  export.envrc  skills/
```

`libxls-runtime-*.tar.gz` is skipped while it is empty. `build.sh` warns if it
ever gains contents, the same way verible-bin warns about an unexpected extra
tool.

## Decisions (taken: A wrappers, B weekly, C ship libxls)

**A. How the tools find the stdlib.** Recommended: **wrappers.** `bin/<tool>`
is a 3-line sh script that runs `libexec/xlsynth/<tool>
--dslx_stdlib_path=<pkg>/share/xlsynth/dslx_stdlib "$@"`, and only for tools
whose `--helpfull` lists that flag (absl rejects unknown flags). The wrapper
passes its flag first, so a user's own `--dslx_stdlib_path` still wins because
absl keeps the last value. The other tools stay as real binaries. Alternative:
no wrappers, export `DSLX_STDLIB_PATH` only, and document the flag. That is
simpler, but `typecheck_main foo.x` fails out of the box.

**B. Cadence.** Recommended: **weekly** (Mondays, gated on "is there an
upstream tag we haven't published?"). Verible went monthly because it releases
several times a week with commit-count versions. xlsynth releases about 3 times
a month with semver bumps that do change behavior, so monthly would leave users
up to 4 minor versions behind. Intermediate upstream releases in a burst are
skipped. The compare window covers them anyway.

**C. Scope of the payload.** Recommended: **ship libxls + AOT runtime**, not
just the CLI. The size cost is about 120 MB. In return, Finding 4's offline
xlsynth-crate build works, and it is the main reason to prefer this package
over curling binaries.

## Plan

### Phase 0: scaffold (mirrors verible-bin)

- `ivpm.yaml`: replace the current dv-flow dev deps with verible-bin's
  `default-dev` (`edapack-common`, `pytest`).
- `build-inputs.yaml`: `core: {name: xlsynth, repo:
  https://github.com/xlsynth/xlsynth, policy: latest-release, release_policy:
  latest-release, release_notes: gh-compare}`. No dependencies, no
  version_probe (`v0.59.0` → `0.59.0`).
- `scripts/release-ivpm.yaml` (Finding 4), `scripts/export.envrc`
  (`PATH_add bin`), `scripts/skill-manifest.yaml`, `.gitignore` edapack tail,
  `README.md`, `LICENSE` (Apache-2.0 to match upstream; also ship upstream's
  LICENSE in the tarball).

### Phase 1: repack (`scripts/build.sh`)

Same skeleton as verible-bin's, with the per-target table changed:

- `linux-x86_64` ← suffix `rocky8`, ext `.so`; `macos-arm64` ← suffix
  `arm64`, ext `.dylib`.
- Download the ~20 assets per target with `curl -f`, plus every `.sha256`.
  **Verify each file against upstream's checksum.** Verible had no sidecars to
  check against; here they exist, so not checking would be a gap.
- Linux only: fetch the `ubuntu2004` `.sha256` files and assert they equal
  `rocky8`'s (Finding 1).
- Gunzip libxls, verify its uncompressed hash, then lay out per *Release
  layout* and create the wrappers (Decision A).
- Expected-tools check: the 12 names must all be present. An extra one logs a
  warning.
- glibc floor check across all ELF files (Finding 2).
- Reuse verible-bin's own `platform.json` writer rather than
  `ec_finalize_release`. Both targets do run natively here, but `image` should
  record where the bits came from (`upstream:<suffix>`), not a build image.
  Then `ec_stage_skills`,
  `ec_copy_envrc`, `ec_stage_release_ivpm`, `ec_emit_manifest`,
  `ec_make_tarball`.
- `tests/run_smoke_test.sh <bin-dir>`, which runs the real flow on a tiny
  fixture and so needs the stdlib:
  1. `typecheck_main` and `dslx_interpreter_main` on `tests/smoke.x` (an adder
     plus a `#[test]`, with `import std;`).
  2. `ir_converter_main` → `opt_main` → `codegen_main --generator=combinational`;
     assert the output contains `module`.
  3. `check_ir_equivalence_main` on unopt vs opt IR, which must report
     equivalent.
  4. `dslx_fmt` round-trip is a no-op on an already-formatted file.
  5. `python3 -c 'ctypes.CDLL(lib/libxls.so)'`, which loads cleanly.
- `scripts/check-repo.py` + `tests/`: static contract checks, same role as in
  verible-bin.
- CI: `.github/workflows/ci.yml` copied from verible-bin with
  `package: xlsynth-bin`, the cron from Decision B, and two targets:
  ```
  {"name":"linux-x86_64","runs-on":"ubuntu-latest","kind":"docker","image":"quay.io/pypa/manylinux_2_28_x86_64"}
  {"name":"macos-arm64","runs-on":"macos-14","kind":"native"}
  ```
  `.forgejo/workflows/ci.yml` copied as-is (its first job is to exist; see the
  verible-bin comments). Keep the `check` job so a push actually exercises
  something.

### Phase 2: release notes

- `scripts/release-notes-hook.sh`: verible-bin's, with the package name,
  diff script and `DIFF_PLATFORM=linux-x86_64` changed.
- `scripts/xlsynth-behavior-diff.py`: the five diffs in Finding 5. Each
  section soft-fails on its own, so one broken probe does not empty the
  whole section.
- `tests/test_behavior_diff.py`: fixture-based unit tests (canned
  `--helpfull` output, stdlib snippets, `nm` output). No binaries needed.
- **Validate on real data before the first publish:** build v0.58.0 and
  v0.59.0 locally (`EC_IMAGE_NAME=linux-x86_64 core_ref=...`), run the diff
  between them, and check that it agrees with the two upstream commits in that
  window (macOS deployment minimum; comparison simplification, which is an opt
  change and probably *not* user-visible in flags). Then repeat over
  v0.55.0→v0.58.0 (94 commits) as the large-window check.

### Phase 3: Agent Skill

`skills/xlsynth/SKILL.md` + `references/`: the DSLX → IR → opt → codegen
pipeline, the flags that matter for each tool, `dslx_ls` for editors,
`check_ir_equivalence_main` / `prove_quickcheck_main` for verification, and the
`XLS_DSO_PATH` / `DSLX_STDLIB_PATH` contract for Rust users. `--strict`
staging, as in verible-bin.

### Phase 4: first release

1. Local dry run on this machine: `EC_IMAGE_NAME=linux-x86_64
   scripts/build.sh`; inspect the tarball, size and manifest.
2. Push. The `check` job must be green on both forges.
3. `workflow_dispatch` with `core_ref` = the newest upstream tag (v0.59.0 or
   later). The first release body shows "first release, nothing to compare
   against" in both sections. That is expected.
4. Install it into a scratch project via ivpm. Confirm `PATH`,
   `DSLX_STDLIB_PATH` and `XLS_DSO_PATH` resolve, and that `typecheck_main`
   handles `import std;` from an arbitrary directory. On macOS, confirm
   Gatekeeper does not block the binaries after an ivpm download.
5. Optional but recommended: run `cargo build` of a trivial xlsynth-crate
   consumer with the env from step 4 and network blocked. That proves
   Finding 4 end to end.
6. Leave the cron enabled. The **second** published release is the first real
   test of the Behavior-changes section. Read it by hand.

### Phase 5: deferred

- Linux aarch64, Windows, macOS x86_64: from-source builds only. Revisit on
  request.
- edapack-common `release-notes.py`: an optional per-repo pattern that would
  render `[XLS PR #N]` as a google/xls link and group "from google/xls" apart
  from "xlsynth-only". Small and generic. Not needed for v1.

## Risks

- **Tarball size.** About 0.5 GB unpacked per platform, so expect roughly
  100–200 MB gzipped. That fits easily under GitHub's 2 GB asset limit, but it
  makes the hook's download of the previous release slow. Measure it in Phase 4
  step 1. If it is painful, have the hook download only `bin/` + `share/` (it
  cannot do partial tar downloads, so the fallback would be a small
  `xlsynth-bin-meta-<ver>.tar.gz` side artifact holding `--helpfull` dumps,
  the stdlib and the `nm` list).
- **`XLS_DSO_PATH` per platform.** One `release-ivpm.yaml` serves both
  platforms, but the extension differs. Either ship a `lib/libxls.so` →
  `.dylib` symlink on macOS, or have `build.sh` render the manifest per
  target. Pick whichever matches what xlsynth-crate expects (Phase 1 check).
- **Upstream asset renames.** `curl -f` turns these into build failures, as in
  verible-bin. That is the intended behavior.
- **Bursty upstream.** Two releases 13 hours apart means a weekly snapshot will
  sometimes skip one. That's intended, and the compare window still lists its
  commits.

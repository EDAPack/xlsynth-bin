#!/usr/bin/env bash
# xlsynth-bin build driver — a REPACK, not a build.
#
# xlsynth already publishes prebuilt binaries for the two platforms it supports
# (docs/plan.md, Finding 1), and building XLS ourselves means Bazel plus LLVM
# for no gain on those platforms. What this script does instead:
#
#   1. download every upstream release asset for $EC_IMAGE_NAME, at the exact
#      tag edapack-common's resolve-inputs.py picked, and verify each against
#      upstream's own .sha256 sidecar,
#   2. lay the loose files out as a package (bin/, libexec/, lib/, share/) --
#      upstream ships no archive at all, just ~20 separate files per platform,
#   3. wrap the tools that read DSLX so they find the bundled stdlib (Finding 3:
#      the binaries default to a path relative to the CWD),
#   4. inject the edapack consumer contract (ivpm.yaml, export.envrc, skills/,
#      manifest.json),
#   5. smoke-test what it can actually execute on this runner,
#   6. emit the tarball + checksum the publish step uploads.
#
# Runs both in CI (via edapack-common's reusable workflow) and locally:
#   EC_IMAGE_NAME=linux-x86_64 scripts/build.sh
# All transient state goes to WORK_DIR; outputs land in OUT_DIR. Nothing is
# written into the source tree.
set -euo pipefail

# --- locate edapack-common --------------------------------------------------
if [ -z "${EC_COMMON:-}" ]; then
    # sibling checkout fallback for plain local runs
    _repo="$(cd "$(dirname "$0")/.." && pwd)"
    for _c in "$_repo/packages/edapack-common" "$_repo/../edapack-common"; do
        if [ -f "$_c/scripts/build-common.sh" ]; then EC_COMMON="$_c"; break; fi
    done
fi
if [ -z "${EC_COMMON:-}" ] || [ ! -f "$EC_COMMON/scripts/build-common.sh" ]; then
    echo "ERROR: edapack-common not found. Set EC_COMMON or place edapack-common beside xlsynth-bin." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$EC_COMMON/scripts/build-common.sh"

: "${EC_PACKAGE:=xlsynth-bin}"
export EC_PACKAGE
# A repack has no top-of-trunk story: an upstream commit without a release has
# no assets to download. Default to the release track rather than inheriting
# build-common's dev default, so a local run resolves the same thing CI does.
: "${EC_TRACK:=release}"
export EC_TRACK
ec_init_dirs
ec_prepare_candidate

# --- target -> upstream asset suffix ----------------------------------------
# EC_IMAGE_NAME is the matrix target name; it is also the platform label in the
# tarball name and the key the publish step merges per-platform manifests on, so
# it must be unique per target.
plat="${EC_IMAGE_NAME:-}"
if [ -z "$plat" ]; then
    case "$(uname -s)" in
        Linux)  plat="linux-$(uname -m | sed 's/^arm64$/aarch64/')" ;;
        Darwin) plat="macos-$(uname -m)" ;;
        *)      ec_die "cannot infer a target from $(uname -s); set EC_IMAGE_NAME" ;;
    esac
    ec_log "EC_IMAGE_NAME unset; inferred target $plat"
fi

upstream_tag="$(ec_core_get ref)"
upstream_repo="$(ec_core_get repo)"
[ -n "$upstream_tag" ] && [ -n "$upstream_repo" ] \
    || ec_die "missing resolved core input (ref/repo) in $CANDIDATE_JSON"

# Upstream names assets <name>-<suffix>. `arm64` is macOS, NOT Linux aarch64 --
# xlsynth ships no Linux aarch64, Windows or Intel-Mac build at all.
#
# Linux has two upstream suffixes, rocky8 and ubuntu2004. We ship rocky8:
# Rocky Linux 8 is a glibc 2.28 base and Ubuntu 20.04 a 2.31 one, so rocky8 is
# the build meant for the older systems, which is what manylinux_2_28 promises.
# They are NOT reliably the same bits -- v0.59.0 uploaded one build twice,
# v0.55.0 built twice, non-reproducibly -- so there is nothing to cross-check;
# the glibc floor check below is what guards the property that matters.
case "$plat" in
    linux-x86_64)   suffix=rocky8; dso_ext=so
                    p_os=linux;   p_arch=x86_64 ;;
    macos-arm64)    suffix=arm64;  dso_ext=dylib
                    p_os=darwin;  p_arch=arm64 ;;
    *) ec_die "unknown target '$plat' (expected linux-x86_64|macos-arm64)" ;;
esac

ec_log "target $plat <- $upstream_repo @ $upstream_tag (suffix $suffix)"

# The 12 executables upstream ships per platform.
XLS_TOOLS="
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

# Tools that resolve DSLX imports, and the flag each one takes for the stdlib
# location. Not uniform: dslx_ls spells it --stdlib_path. These get a wrapper in
# bin/ that passes the bundled stdlib; everything else ships as-is. When the
# runner can execute the target, this table is checked against each tool's own
# --helpfull below, so upstream renaming a flag or adding a DSLX-reading tool
# fails the build rather than shipping a tool that cannot find `std`.
stdlib_flag_for() {
    case "$1" in
        dslx_interpreter_main|ir_converter_main|prove_quickcheck_main|typecheck_main)
            echo dslx_stdlib_path ;;
        dslx_ls)
            echo stdlib_path ;;
        *)  echo "" ;;
    esac
}

# --- download + verify ------------------------------------------------------
dl_dir="$WORK_DIR/download"
rm -rf "$dl_dir"; mkdir -p "$dl_dir"
base_url="${upstream_repo%/}/releases/download/${upstream_tag}"
command -v curl >/dev/null 2>&1 || ec_die "curl is required to repack (not found on PATH)"

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Upstream's sidecars read "<digest>  rocky8-artifacts/<name>": only the first
# field is meaningful.
sidecar_digest() { cut -d' ' -f1 < "$1" | tr -d '[:space:]'; }

# fetch NAME -- download NAME into $dl_dir. --fail so a 404 (upstream dropped a
# platform, or renamed an asset) is a build failure rather than an HTML error
# page repacked into a tarball.
fetch() {
    curl -fsSL --retry 3 --retry-delay 5 -o "$dl_dir/$1" "$base_url/$1" \
        || ec_die "download failed: $base_url/$1"
}

# fetch_verified NAME -- download NAME and NAME.sha256, and check one against
# the other. Upstream publishes a sidecar for every asset; not checking it
# would be the one integrity gap a repack can close for free.
fetch_verified() {
    fetch "$1"
    fetch "$1.sha256"
    local want got
    want="$(sidecar_digest "$dl_dir/$1.sha256")"
    got="$(sha256_of "$dl_dir/$1")"
    [ -n "$want" ] && [ "$want" = "$got" ] \
        || ec_die "checksum mismatch for $1: upstream says '$want', downloaded file is '$got'"
}

dso_gz="libxls-${suffix}.${dso_ext}.gz"
for t in $XLS_TOOLS; do
    fetch_verified "${t}-${suffix}"
done
fetch_verified "$dso_gz"
# Upstream also publishes the digest of the UNcompressed DSO; checked after
# gunzip below.
fetch "libxls-${suffix}.${dso_ext}.sha256"
fetch_verified "libxls_aot_runtime-${suffix}.a"
fetch_verified "libxls_aot_runtime_link-${suffix}.toml"
fetch_verified "dslx_stdlib.tar.gz"
fetch_verified "xls-aot-runtime-source.tar.gz"
ec_log "downloaded and verified $(find "$dl_dir" -type f ! -name '*.sha256' | wc -l | tr -d '[:space:]') assets"

# Upstream's "runtime sidecar" bundle has been empty in every release so far
# (manifest `runtime_files: []`), and it does not exist at all for arm64. If it
# ever gains files, they are presumably needed beside libxls at runtime and this
# repack would be dropping them -- say so rather than ship something incomplete
# unannounced.
if curl -fsSL -o "$dl_dir/runtime-manifest.json" \
        "$base_url/libxls-runtime-${suffix}-manifest.json" 2>/dev/null; then
    n_runtime="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("runtime_files") or []))' \
                    "$dl_dir/runtime-manifest.json" 2>/dev/null || echo "?")"
    [ "$n_runtime" = 0 ] \
        || ec_log "WARNING: libxls-runtime-${suffix} now lists $n_runtime runtime file(s); this repack does not ship them"
fi

# --- lay out the package ----------------------------------------------------
#   bin/<tool>                     real executable, or a wrapper (see below)
#   libexec/xlsynth/<tool>         the real executable behind each wrapper
#   lib/libxls.{so,dylib}          gunzipped; lib/libxls.so on both platforms
#   lib/libxls_aot_runtime.a
#   share/xlsynth/dslx_stdlib/     std.x and friends, prefix stripped
#   share/xlsynth/libxls_aot_runtime_link.toml
#   share/xlsynth/xls-aot-runtime-source.tar.gz
release_root="$WORK_DIR/release/xlsynth-bin"
rm -rf "$release_root"
mkdir -p "$release_root/bin" "$release_root/libexec/xlsynth" "$release_root/lib" \
         "$release_root/share/xlsynth/dslx_stdlib"

for t in $XLS_TOOLS; do
    if [ -n "$(stdlib_flag_for "$t")" ]; then
        dest="$release_root/libexec/xlsynth/$t"
    else
        dest="$release_root/bin/$t"
    fi
    cp "$dl_dir/${t}-${suffix}" "$dest"
    chmod 755 "$dest"
done

gunzip -c "$dl_dir/$dso_gz" > "$release_root/lib/libxls.${dso_ext}"
want="$(sidecar_digest "$dl_dir/libxls-${suffix}.${dso_ext}.sha256")"
got="$(sha256_of "$release_root/lib/libxls.${dso_ext}")"
[ "$want" = "$got" ] || ec_die "uncompressed libxls checksum mismatch: upstream '$want', got '$got'"
chmod 755 "$release_root/lib/libxls.${dso_ext}"
# One export.envrc serves every platform (it points XLS_DSO_PATH at
# lib/libxls.so). xlsynth-crate turns that path into
# `-L lib -l xls`, so on macOS the linker still finds libxls.dylib beside it.
[ "$dso_ext" = so ] || ln -s "libxls.${dso_ext}" "$release_root/lib/libxls.so"

cp "$dl_dir/libxls_aot_runtime-${suffix}.a" "$release_root/lib/libxls_aot_runtime.a"
cp "$dl_dir/libxls_aot_runtime_link-${suffix}.toml" \
   "$release_root/share/xlsynth/libxls_aot_runtime_link.toml"
cp "$dl_dir/xls-aot-runtime-source.tar.gz" "$release_root/share/xlsynth/"

stdlib_unpack="$WORK_DIR/stdlib"
rm -rf "$stdlib_unpack"; mkdir -p "$stdlib_unpack"
tar -C "$stdlib_unpack" -xzf "$dl_dir/dslx_stdlib.tar.gz"
[ -f "$stdlib_unpack/xls/dslx/stdlib/std.x" ] \
    || ec_die "dslx_stdlib.tar.gz no longer holds xls/dslx/stdlib/std.x; upstream changed its layout"
cp -R "$stdlib_unpack/xls/dslx/stdlib/." "$release_root/share/xlsynth/dslx_stdlib/"

cp "$SRC_DIR/LICENSE" "$release_root/LICENSE"

# --- wrappers for the DSLX-reading tools ------------------------------------
# The stdlib flag goes FIRST, so a user's own --dslx_stdlib_path later on the
# command line still wins (absl keeps the last value). POSIX sh, and the
# symlink loop uses plain `readlink` (no -f), so this runs on macOS as is.
for t in $XLS_TOOLS; do
    flag="$(stdlib_flag_for "$t")"
    [ -n "$flag" ] || continue
    cat > "$release_root/bin/$t" <<EOF
#!/bin/sh
# xlsynth-bin wrapper: runs the real $t with the bundled DSLX stdlib.
# Upstream's default stdlib path is relative to the working directory, so
# without this, \`import std;\` fails outside an XLS source checkout.
# Pass your own --$flag to override; the last value wins.
self="\$0"
while [ -L "\$self" ]; do
    link="\$(readlink "\$self")"
    case "\$link" in
        /*) self="\$link" ;;
        *)  self="\$(dirname "\$self")/\$link" ;;
    esac
done
pkg="\$(cd "\$(dirname "\$self")/.." && pwd)"
exec "\$pkg/libexec/xlsynth/$t" "--$flag=\$pkg/share/xlsynth/dslx_stdlib" "\$@"
EOF
    chmod 755 "$release_root/bin/$t"
done

# --- verify the repack ------------------------------------------------------
missing=""
for t in $XLS_TOOLS; do
    [ -x "$release_root/bin/$t" ] || missing="$missing $t"
done
[ -z "$missing" ] || ec_die "repack lost executables:$missing"
ec_log "all 12 xlsynth tools present in bin/"

# --- can this runner execute the target? ------------------------------------
host_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
host_arch="$(uname -m | sed 's/^arm64$/aarch64/')"
want_arch="$(echo "$p_arch" | sed 's/^arm64$/aarch64/')"
native=0
[ "$host_os" = "$p_os" ] && [ "$host_arch" = "$want_arch" ] && native=1

# --- the wrapper table must match what the tools say ------------------------
if [ "$native" = 1 ]; then
    for t in $XLS_TOOLS; do
        real="$release_root/libexec/xlsynth/$t"
        [ -x "$real" ] || real="$release_root/bin/$t"
        help="$("$real" --helpfull 2>&1 || true)"
        declared="$(stdlib_flag_for "$t")"
        has=""
        for f in dslx_stdlib_path stdlib_path; do
            if printf '%s\n' "$help" | grep -q -- "--$f ("; then has="$f"; break; fi
        done
        [ "$has" = "$declared" ] \
            || ec_die "$t: build.sh wraps it with '--${declared:-<nothing>}' but its --helpfull offers '--${has:-<nothing>}'; update stdlib_flag_for"
    done
    ec_log "stdlib wrapper table agrees with every tool's --helpfull"
fi

# --- glibc floor (Linux) ----------------------------------------------------
# Upstream's Linux build is dynamic against glibc (Finding 2). We record
# glibc_2.28 because that is the image the smoke test proves it on; make sure
# no file quietly needs more than that.
libc_tag=""
if [ "$p_os" = linux ]; then
    libc_tag="glibc_2.28"
    if command -v objdump >/dev/null 2>&1; then
        worst="$(find "$release_root/bin" "$release_root/libexec" "$release_root/lib" -type f \
                    -exec objdump -T {} \; 2>/dev/null \
                 | grep -o 'GLIBC_2\.[0-9][0-9]*' | sed 's/GLIBC_2\.//' | sort -n | tail -1)"
        [ -n "$worst" ] || ec_die "found no GLIBC symbol versions; is objdump reading these files?"
        [ "$worst" -le 28 ] || ec_die "a shipped file needs GLIBC_2.$worst, above the 2.28 floor we record"
        ec_log "highest GLIBC symbol version required: 2.$worst"
    else
        ec_log "WARNING: objdump not found; glibc floor not checked"
    fi
fi

# --- smoke test (only where this runner can execute the target) -------------
if [ "$native" = 1 ]; then
    ec_log "smoke-testing $plat natively"
    bash "$SRC_DIR/tests/run_smoke_test.sh" "$release_root" \
        || ec_die "smoke test failed for $plat"
else
    ec_log "skipping smoke test: runner is $host_os/$host_arch, target is $p_os/$want_arch"
fi

# --- shared release tail ----------------------------------------------------
# Not ec_finalize_release: its ec_platform_json derives os/arch/image from the
# machine doing the work, and for a repack `image` should say where the bits
# came from, not which container rearranged them.
tarball="xlsynth-bin-${plat}-${EC_VERSION}.tar.gz"
platform_json="$WORK_DIR/platform.json"
python3 - "$platform_json" "$p_os" "$p_arch" "$libc_tag" "$suffix" "$tarball" <<'PY'
import json, sys
out, os_, arch, libc, suffix, artifact = sys.argv[1:7]
json.dump({
    "os": os_,
    "arch": arch,
    "libc": libc,
    # No build image: `image` records which upstream build this repacks.
    "image": "upstream:" + suffix,
    "artifact": artifact,
}, open(out, "w"))
PY

ec_stage_skills "$SRC_DIR" "$release_root" --strict
ec_copy_envrc "$SRC_DIR" "$release_root"
ec_stage_release_ivpm "$SRC_DIR" "$release_root"
ec_emit_manifest "$CANDIDATE_JSON" "$release_root" "$platform_json"
ec_require_file "$release_root/skills/index.json" "skills/index.json"
ec_require_file "$release_root/export.envrc" "export.envrc"
ec_require_file "$release_root/ivpm.yaml" "ivpm.yaml"
ec_require_file "$release_root/manifest.json" "manifest.json"
cp "$release_root/manifest.json" "$OUT_DIR/manifest-${plat}.json"

ec_make_tarball "$release_root" "$tarball"
ec_log "repack complete: $tarball"

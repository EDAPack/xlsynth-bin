#!/usr/bin/env bash
# xlsynth-bin release-notes hook.
#
#   scripts/release-notes-hook.sh <artifacts-dir> <upload-dir>   # markdown -> stdout
#
# Called by edapack-common's publish job; its stdout is appended to the release
# body. See edapack-common's README (Release notes -> Adding to the body).
#
# WHY THIS EXISTS. release-notes.py already lists what changed upstream since
# our last release (commit subjects, for xlsynth: build-inputs.yaml says why).
# That answers "what did the xlsynth project do", which is not quite the
# question a user of this package has. They want "what changes for me if I
# upgrade", and for a toolchain that question has a checkable answer: which
# tools ship, which flags they accept and with what defaults, what the DSLX
# stdlib exports, and what the libxls C API exports. All of it can be read
# out of the artifacts themselves.
#
# So this does not summarize; it DIFFS. It runs the package this build just
# produced against the one the previous release shipped and reports the delta
# (scripts/xlsynth-behavior-diff.py). Nothing here is asserted: if the notes
# say a flag changed its default, it is because the two binaries disagreed.
#
# Soft-fails throughout. The publish step marks this `continue-on-error`, and
# an incomplete release body is never worth failing a release that is otherwise
# ready to ship.
set -uo pipefail

artifacts_dir="${1:-artifacts}"
upload_dir="${2:-upload}"
repo="${EC_REPO:-}"

log() { printf '[hook] %s\n' "$*" >&2; }

# pkg_root DIR -- the unpacked package root under DIR (the directory holding
# bin/), or nothing. Not `dirname "$(find ...)"`: dirname of an empty string
# is ".", which would pass for a package root.
pkg_root() {
    local b
    b="$(find "$1" -maxdepth 2 -type d -name bin | head -1)"
    [ -n "$b" ] && dirname "$b"
}

# Explicit template — portable across GNU and BSD mktemp. This runs on the
# publish runner (Linux), but it is documented as runnable by hand.
work="$(mktemp -d "${TMPDIR:-/tmp}/xlsynth-notes.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# The platform we can actually execute on the publish runner (ubuntu-latest).
# Flags, stdlib and C API are the same on every platform, so one is enough.
DIFF_PLATFORM="linux-x86_64"

# --- locate this build's binaries ------------------------------------------
new_tarball="$(find "$upload_dir" -name "xlsynth-bin-${DIFF_PLATFORM}-*.tar.gz" \
                    -print 2>/dev/null | head -1)"
new_root=""
if [ -n "$new_tarball" ]; then
    mkdir -p "$work/new"
    if tar -C "$work/new" -xzf "$new_tarball" 2>/dev/null; then
        new_root="$(pkg_root "$work/new")"
    fi
fi
[ -n "$new_root" ] || log "no ${DIFF_PLATFORM} tarball in $upload_dir; skipping behavior diff"

# --- locate the previous release's binaries --------------------------------
# The hook runs BEFORE `gh release create`, so the newest published release is
# still the previous one. No need to filter out our own tag.
prev_tag=""
prev_root=""
if [ -n "$new_root" ] && [ -n "$repo" ] && command -v gh >/dev/null 2>&1; then
    prev_tag="$(gh release list --repo "$repo" --limit 1 \
                   --json tagName -q '.[0].tagName' 2>/dev/null || true)"
    if [ -n "$prev_tag" ]; then
        mkdir -p "$work/prevdl" "$work/prev"
        if gh release download "$prev_tag" --repo "$repo" \
             --pattern "xlsynth-bin-${DIFF_PLATFORM}-*.tar.gz" \
             --dir "$work/prevdl" >/dev/null 2>&1; then
            prev_archive="$(find "$work/prevdl" -name '*.tar.gz' | head -1)"
            if [ -n "$prev_archive" ] && tar -C "$work/prev" -xzf "$prev_archive" 2>/dev/null; then
                prev_root="$(pkg_root "$work/prev")"
            fi
        fi
        [ -n "$prev_root" ] || log "could not fetch ${DIFF_PLATFORM} assets for $prev_tag"
    else
        log "no previous release found; this looks like the first one"
    fi
fi

# --- behavior diff ----------------------------------------------------------
if [ -n "$new_root" ] && [ -n "$prev_root" ]; then
    chmod -R u+rx "$prev_root" "$new_root" 2>/dev/null || true
    python3 "$(dirname "$0")/xlsynth-behavior-diff.py" \
        --old "$prev_root" --new "$new_root" --old-tag "$prev_tag" \
        || log "behavior diff failed; omitting that section"
fi

# --- assets -----------------------------------------------------------------
# Checksums exist here and nowhere else in the pipeline, and a release whose
# body carries them is verifiable without downloading anything twice.
python3 - "$upload_dir" "${EC_VERSION:-}" <<'PY'
import os, sys

upload, version = sys.argv[1], sys.argv[2]
PREFIX, SUFFIX = "xlsynth-bin-", ".tar.gz"


def platform_of(name):
    """xlsynth-bin-<platform>-<version>.tar.gz -> <platform>.

    Split on the version rather than on '-': both the platform
    (`linux-x86_64`) and the version (`0.0-4294-gc1d8f5e8`) contain hyphens,
    so counting them from either end gets it wrong.
    """
    stem = name[len(PREFIX):-len(SUFFIX)]
    if version and stem.endswith("-" + version):
        return stem[:-(len(version) + 1)]
    return stem


rows = []
for name in sorted(os.listdir(upload)):
    if not (name.startswith(PREFIX) and name.endswith(SUFFIX)):
        continue
    sha_path = os.path.join(upload, name + ".sha256")
    digest = ""
    if os.path.isfile(sha_path):
        # Both `sha256sum` and `shasum -a 256` write "<digest>  <name>".
        fields = open(sha_path).read().split()
        digest = fields[0] if fields else ""
    size = os.path.getsize(os.path.join(upload, name)) / (1024.0 * 1024.0)
    rows.append((platform_of(name), size, digest))

if rows:
    print()
    print("## Assets")
    print()
    print("| Platform | Size | SHA-256 |")
    print("|---|---|---|")
    for plat, size, digest in rows:
        print("| `{}` | {:.1f} MB | `{}` |".format(plat, size, digest or "n/a"))
PY

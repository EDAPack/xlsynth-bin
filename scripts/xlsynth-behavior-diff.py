#!/usr/bin/env python3
"""Diff two xlsynth-bin builds' user-visible surface and render it as Markdown.

    xlsynth-behavior-diff.py --old <pkg-root> --new <pkg-root> [--old-tag TAG]

<pkg-root> is an unpacked xlsynth-bin release: the directory holding bin/,
lib/ and share/.

Used by scripts/release-notes-hook.sh to put a "Behavior changes" section in
the release body. It answers the question a *user* of this package has on
seeing a new release, "what changes for me if I upgrade?", which upstream's
commit log does not.

Four surfaces, each read out of the artifacts rather than inferred:

    tools           the executables in bin/
    flags           every tool's --helpfull, XLS's own flags only
    DSLX stdlib     public declarations in share/xlsynth/dslx_stdlib/*.x:
                    DSLX that imports `std`/`apfloat`/... can stop
                    typechecking when one of these changes
    libxls C API    exported xls_* symbols (nm -D). Names only: a C symbol
                    carries no signature, so a changed prototype is invisible
                    here and the notes say so.

Deliberately NOT diffed: the optimizer's pass list. `opt_main --list_passes`
prints uninitialized memory interleaved with the pass names (seen in v0.59.0),
so its output differs between two runs of the same binary.

Flags are grouped by the source file that declares them, not by tool. A flag
file like xls/common/logging/log_flags.cc is linked into all twelve tools, and
listing one change twelve times would bury everything else.

Exit codes: 0 always, unless the new build described nothing at all (1).
"No changes" is a successful outcome with a sentence saying so.
"""

import argparse
import os
import re
import subprocess
import sys

# "  Flags from xls/tools/codegen_flags.cc:"
_SECTION_RE = re.compile(r"^\s*Flags from (\S+):")
# "    --generator (Which generator to use...); default: "";"
_FLAG_RE = re.compile(r"^\s{2,}--([a-z0-9_]+) \(")
_DEFAULT_RE = re.compile(r"default:\s*(.*?);\s*$")

STDLIB_REL = os.path.join("share", "xlsynth", "dslx_stdlib")
DSO_REL = os.path.join("lib", "libxls.so")

# Beyond this many tools sharing a flag source, name the count, not the tools.
_MAX_NAMED_TOOLS = 3
# Signatures longer than this are cut in the rendered notes.
_MAX_SIG = 160


def _run(argv):
    """Run a command, returning stdout+stderr, or None if it could not run."""
    try:
        proc = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            universal_newlines=True)
        out, _ = proc.communicate(timeout=120)
        return out
    except Exception:
        return None


# --------------------------------------------------------------------------- #
# Flags
# --------------------------------------------------------------------------- #
def parse_flags(text, own_prefix="xls/"):
    """Parse `--helpfull` into {source_file: {flag: default}}, XLS's own only.

    abseil, LLVM and fuzztest flags are dropped: they say nothing about XLS and
    would turn a dependency bump into release-note noise.
    """
    out, section, pending = {}, None, None
    for line in (text or "").splitlines():
        m = _SECTION_RE.match(line)
        if m:
            src = m.group(1)
            section = src if src.startswith(own_prefix) else None
            pending = None
            continue
        if section is None:
            continue
        m = _FLAG_RE.match(line)
        if m:
            pending = m.group(1)
            out.setdefault(section, {}).setdefault(pending, "")
        # The default can land on the flag's own line or on a continuation of
        # its wrapped description, so keep attributing until the next flag.
        if pending:
            d = _DEFAULT_RE.search(line)
            if d:
                out[section][pending] = d.group(1).strip()
                pending = None
    return out


def merge_flag_sources(per_tool):
    """{tool: {src: {flag: default}}} -> ({src: {flag: default}}, {src: {tools}})."""
    flags, users = {}, {}
    for tool, sources in per_tool.items():
        for src, fl in sources.items():
            flags.setdefault(src, {}).update(fl)
            users.setdefault(src, set()).add(tool)
    return flags, users


def _who(tools):
    tools = sorted(tools)
    if len(tools) > _MAX_NAMED_TOOLS:
        return "{} tools".format(len(tools))
    return ", ".join("`{}`".format(t) for t in tools)


def diff_flags(old, new, old_users, new_users):
    """Diff merged flag sources; return markdown bullet strings."""
    out = []
    for src in sorted(set(old) | set(new)):
        o, n = old.get(src, {}), new.get(src, {})
        who = _who(new_users.get(src) or old_users.get(src) or ())
        for flag in sorted(set(n) - set(o)):
            out.append("{}: new flag `--{}`".format(who, flag))
        for flag in sorted(set(o) - set(n)):
            out.append("{}: flag `--{}` removed".format(who, flag))
        for flag in sorted(set(o) & set(n)):
            if o[flag] != n[flag]:
                out.append("{}: `--{}` default `{}` → `{}`".format(
                    who, flag, o[flag] or "(none)", n[flag] or "(none)"))
    # A flag moving between source files shows up as removed+added under the
    # same name; that is a refactor, not a change a user can see.
    added = {}
    for line in out:
        m = re.match(r"^(.*): new flag `--(\w+)`$", line)
        if m:
            added[m.group(2)] = line
    moved = set()
    for line in out:
        m = re.match(r"^(.*): flag `--(\w+)` removed$", line)
        if m and m.group(2) in added:
            moved.update((line, added[m.group(2)]))
    return [line for line in out if line not in moved]


# --------------------------------------------------------------------------- #
# DSLX stdlib
# --------------------------------------------------------------------------- #
_STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"')
_COMMENT_RE = re.compile(r"//[^\n]*")
_KINDS = ("fn", "struct", "enum", "type", "const")


def _strip(text):
    # Strings first: a `//` inside a string is not a comment, and format
    # strings like "x={}" would otherwise unbalance the brace counting.
    return _COMMENT_RE.sub("", _STRING_RE.sub('""', text))


def _normalize(decl):
    s = re.sub(r"\s+", " ", decl).strip()
    s = re.sub(r"\s*([(),\[\]{}:;=<])\s*", r"\1", s)
    # '>' separately so the '->' arrow keeps its spacing-insensitive form.
    s = re.sub(r"\s*(-?>)\s*", r"\1", s)
    # A trailing comma is formatting, not API.
    return re.sub(r",([)\]}>])", r"\1", s)


def _match_brace(text, i):
    """Index just past the '}' matching the '{' at text[i]."""
    depth = 0
    while i < len(text):
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(text)


def _fn_header_end(text, i):
    """Index of the '{' that opens a function body, starting at `pub fn`.

    Generic parameters may contain braced const expressions
    (`<N: u32, M: u32 = {N - 1}>`) and return types contain '<..>', so the
    body is the first '{' seen outside every bracket kind.
    """
    paren = angle = brace = 0
    while i < len(text):
        c = text[i]
        if brace:
            if c == "{":
                brace += 1
            elif c == "}":
                brace -= 1
        elif c in "([":
            paren += 1
        elif c in ")]":
            paren -= 1
        elif c == "<":
            angle += 1
        elif c == ">" and text[i - 1] != "-":
            angle -= 1
        elif c == "{":
            if paren == 0 and angle == 0:
                return i
            brace += 1
        i += 1
    return len(text)


def _semicolon_end(text, i):
    """Index just past the ';' ending a type/const, outside () and {}."""
    paren = brace = 0
    while i < len(text):
        c = text[i]
        if c in "([":
            paren += 1
        elif c in ")]":
            paren -= 1
        elif c == "{":
            brace += 1
        elif c == "}":
            brace -= 1
        elif c == ";" and paren == 0 and brace == 0:
            return i + 1
        i += 1
    return len(text)


_ITEM_RE = re.compile(r"\b(pub\s+(fn|struct|enum|type|const)\s+([A-Za-z_]\w*)|impl\s+([A-Za-z_]\w*))")


def parse_module(text, prefix=""):
    """Return {qualified_name: (kind, normalized_decl)} for a module's public API.

    `impl Foo { pub fn bar ... }` yields `Foo::bar`.
    """
    text = _strip(text)
    out, i = {}, 0
    while True:
        m = _ITEM_RE.search(text, i)
        if not m:
            return out
        if m.group(4):                     # impl block
            open_ = text.find("{", m.end())
            if open_ < 0:
                return out
            close = _match_brace(text, open_)
            out.update(parse_module(text[open_ + 1:close - 1],
                                    prefix + m.group(4) + "::"))
            i = close
            continue
        kind, name, start = m.group(2), prefix + m.group(3), m.start()
        if kind == "fn":
            body = _fn_header_end(text, m.end())
            decl, i = text[start:body], _match_brace(text, body)
        elif kind in ("struct", "enum"):
            open_ = text.find("{", m.end())
            i = _match_brace(text, open_) if open_ >= 0 else len(text)
            decl = text[start:i]
        else:
            i = _semicolon_end(text, m.end())
            decl = text[start:i]
        out[name] = (kind, _normalize(decl))


def collect_stdlib(stdlib_dir):
    """{module: {name: (kind, decl)}} for every .x file, or None if absent."""
    if not os.path.isdir(stdlib_dir):
        return None
    mods = {}
    for fname in sorted(os.listdir(stdlib_dir)):
        if fname.endswith(".x"):
            with open(os.path.join(stdlib_dir, fname)) as f:
                mods[fname[:-2]] = parse_module(f.read())
    return mods


def _cut(s):
    return s if len(s) <= _MAX_SIG else s[:_MAX_SIG - 1] + "…"


def diff_stdlib(old, new):
    out = []
    for mod in sorted(set(new) - set(old)):
        out.append("new module `{}` ({} public items)".format(mod, len(new[mod])))
    for mod in sorted(set(old) - set(new)):
        out.append("module `{}` removed".format(mod))
    for mod in sorted(set(old) & set(new)):
        o, n = old[mod], new[mod]
        for name in sorted(set(n) - set(o)):
            out.append("`{}::{}` added ({})".format(mod, name, n[name][0]))
        for name in sorted(set(o) - set(n)):
            out.append("`{}::{}` removed".format(mod, name))
        for name in sorted(set(o) & set(n)):
            if o[name] != n[name]:
                out.append("`{}::{}` changed: `{}` → `{}`".format(
                    mod, name, _cut(o[name][1]), _cut(n[name][1])))
    return out


# --------------------------------------------------------------------------- #
# libxls C API
# --------------------------------------------------------------------------- #
def parse_nm(text):
    """Exported xls_* names from `nm -D --defined-only` output."""
    syms = set()
    for line in (text or "").splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] in ("T", "W", "D", "B", "R") \
                and parts[2].startswith("xls_"):
            syms.add(parts[2])
    return syms


def collect_symbols(dso):
    if not os.path.isfile(dso):
        return None
    text = _run(["nm", "-D", "--defined-only", dso])
    syms = parse_nm(text)
    return syms or None


def diff_symbols(old, new):
    out = ["new C-API function `{}`".format(s) for s in sorted(new - old)]
    out += ["C-API function `{}` removed".format(s) for s in sorted(old - new)]
    return out


# --------------------------------------------------------------------------- #
def collect(root):
    """Read the whole user-visible surface out of one unpacked release."""
    bin_dir = os.path.join(root, "bin")
    tools = sorted(t for t in os.listdir(bin_dir)) if os.path.isdir(bin_dir) else []
    per_tool = {}
    for tool in tools:
        parsed = parse_flags(_run([os.path.join(bin_dir, tool), "--helpfull"]))
        if parsed:
            per_tool[tool] = parsed
    return {
        "tools": set(tools),
        "flags": merge_flag_sources(per_tool),
        "stdlib": collect_stdlib(os.path.join(root, STDLIB_REL)),
        "symbols": collect_symbols(os.path.join(root, DSO_REL)),
    }


def render(sections, notes, old_tag):
    since = " against `{}`".format(old_tag) if old_tag else ""
    lines = ["", "## Behavior changes", ""]
    if not any(items for _, items in sections):
        lines.append("No tool, command-line-flag, DSLX-stdlib or C-API changes "
                     "in this release (diffed{}).".format(since))
    else:
        lines.append("Diffed from the shipped binaries{}, not from the commit "
                     "log.".format(since))
        lines.append("")
        for title, items in sections:
            if not items:
                continue
            lines.append("**{}**".format(title))
            lines.append("")
            lines.extend("- " + c for c in items)
            lines.append("")
    if notes:
        lines.append("")
        lines.extend("_{}_".format(n) for n in notes)
    return "\n".join(lines).rstrip() + "\n"


def build_sections(old, new):
    notes = []
    tools = ["new tool `{}`".format(t) for t in sorted(new["tools"] - old["tools"])]
    tools += ["tool `{}` no longer shipped".format(t)
              for t in sorted(old["tools"] - new["tools"])]

    (of, ou), (nf, nu) = old["flags"], new["flags"]
    flags = diff_flags(of, nf, ou, nu)

    stdlib = []
    if old["stdlib"] is None or new["stdlib"] is None:
        notes.append("DSLX stdlib not compared: one build has no {}.".format(STDLIB_REL))
    else:
        stdlib = diff_stdlib(old["stdlib"], new["stdlib"])

    symbols = []
    if old["symbols"] is None or new["symbols"] is None:
        notes.append("libxls C API not compared: could not list its symbols "
                     "(is `nm` installed?).")
    else:
        symbols = diff_symbols(old["symbols"], new["symbols"])
        notes.append("C-API comparison is by symbol name; a changed prototype "
                     "under an unchanged name is not detected.")

    return [("Tools", tools), ("Command-line flags", flags),
            ("DSLX standard library", stdlib), ("libxls C API", symbols)], notes


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--old", required=True, help="previous release's package root")
    p.add_argument("--new", required=True, help="this build's package root")
    p.add_argument("--old-tag", default="", help="tag the old build came from")
    args = p.parse_args(argv)

    old, new = collect(args.old), collect(args.new)
    if not new["tools"] and not new["flags"][0]:
        print("xlsynth-behavior-diff: the new build described nothing; "
              "is {} a package root?".format(args.new), file=sys.stderr)
        return 1

    sections, notes = build_sections(old, new)
    sys.stdout.write(render(sections, notes, args.old_tag))
    return 0


if __name__ == "__main__":
    sys.exit(main())

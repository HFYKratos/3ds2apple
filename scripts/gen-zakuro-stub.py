#!/usr/bin/env python3
"""Generate the C stub library that lets the shell run in the iOS Simulator.

The shell links libzakuro_ios.a, an arm64 DEVICE build of the Rust Zakuro
runtime, so the iOS Simulator (x86_64 on the Intel build VM) cannot link it.
The preview app (ios/preview/) therefore links empty implementations of every
zk_* function the Swift sources reference. The stub has exactly the signatures
of ios/ZakuroBridge.h, so the header stays the single source of truth and the
Swift sources compile unchanged.

How it works:

1. ios/ZakuroBridge.h is stripped of comments, its preprocessor lines are
   dropped, and the remaining text is split on ';'. Every declaration chunk
   that ends in a zk_* name and a parameter list is one function.
2. ios/app/Sources/**/*.swift is scanned for zk_* identifiers. A real Swift
   call zk_foo( that the header does not declare is an error (the app would not
   link on device either).
3. ios/preview/generated/ZakuroStub.c is written with one empty definition per
   referenced function: int/bool/enum/size_t return 0, pointers return NULL,
   void returns nothing.

Exit status: 0 on success, 1 when a declaration cannot be generated or the
Swift sources call a zk_* function the header does not declare.
scripts/ios-ui-preview.sh runs this on macOS; it also runs standalone anywhere.
"""

import argparse
import os
import re
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_HEADER = os.path.join("ios", "ZakuroBridge.h")
DEFAULT_SWIFT_DIR = os.path.join("ios", "app", "Sources")
DEFAULT_OUTPUT = os.path.join("ios", "preview", "generated", "ZakuroStub.c")

COMMENT_BLOCK_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
COMMENT_LINE_RE = re.compile(r"//[^\n]*")
LINE_SPLICE_RE = re.compile(r"\\\n")
PREPROCESSOR_RE = re.compile(r"^[ \t]*#.*$", re.MULTILINE)

# "zk_name(args)" at the very end of a declaration chunk (with an optional
# closing brace left over from the surrounding extern "C" block).
FUNC_TAIL_RE = re.compile(r"(?P<name>zk_[a-z0-9_]+)\s*\((?P<args>[^()]*)\)\s*\}*\s*$")

# A C return type: words, spaces and the optional pointer star, e.g. "uint32_t",
# "zk_system_t" or "const char *".
RETURN_TYPE_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_ \t\n]*\*?$")

IDENTIFIER_RE = re.compile(r"\b(zk_[a-z0-9_]+)\b")
CALL_RE = re.compile(r"\b(zk_[a-z0-9_]+)\s*\(")

# "typedef void *zk_system_t" - the function returns a pointer even though the
# return type text carries no star, so its stub must return NULL.
TYPEDEF_POINTER_RE = re.compile(r"\btypedef\b[^;]*?\*\s*(?P<name>[A-Za-z_][A-Za-z0-9_]*)\s*$")


def fail(message):
    sys.stderr.write("gen-zakuro-stub: error: %s\n" % message)
    sys.exit(1)


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()
    except OSError as error:
        fail("cannot read %s: %s" % (path, error))


def first_line(text):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    line = lines[0] if lines else text.strip()
    return line[:140]


def parse_header(path):
    """Return (functions, unparsable) parsed from a C header."""
    text = read_text(path)
    text = COMMENT_BLOCK_RE.sub(" ", text)
    text = COMMENT_LINE_RE.sub("", text)
    text = LINE_SPLICE_RE.sub(" ", text)
    text = PREPROCESSOR_RE.sub("", text)

    functions = []
    unparsable = []
    seen = set()
    pointer_typedefs = set()
    for chunk in text.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        typedef_match = TYPEDEF_POINTER_RE.search(chunk)
        if typedef_match is not None and "(" not in chunk:
            pointer_typedefs.add(typedef_match.group("name"))
            continue
        if "zk_" not in chunk or "(" not in chunk:
            # typedef / enum initializer / plain declaration: no stub needed
            continue
        match = FUNC_TAIL_RE.search(chunk)
        if match is None:
            unparsable.append(first_line(chunk))
            continue
        return_type = " ".join(chunk[: match.start()].split())
        if not return_type or not RETURN_TYPE_RE.match(return_type):
            unparsable.append(first_line(chunk))
            continue
        name = match.group("name")
        if name in seen:
            continue
        seen.add(name)
        arguments = " ".join(match.group("args").split())
        functions.append({
            "name": name,
            "return_type": return_type,
            "arguments": arguments,
        })
    return functions, unparsable, pointer_typedefs


def scan_swift(directory):
    """Return (identifiers, calls, file_count) from the Swift sources."""
    identifiers = set()
    calls = set()
    files = []
    for root, directories, names in os.walk(directory):
        directories.sort()
        for name in sorted(names):
            if not name.endswith(".swift"):
                continue
            files.append(os.path.join(root, name))
            text = read_text(os.path.join(root, name))
            identifiers.update(IDENTIFIER_RE.findall(text))
            calls.update(CALL_RE.findall(text))
    return identifiers, calls, len(files)


def declaration(function):
    separator = "" if function["return_type"].endswith("*") else " "
    return "%s%s%s(%s)" % (
        function["return_type"],
        separator,
        function["name"],
        function["arguments"],
    )


def body(function, pointer_typedefs):
    if function["return_type"] == "void":
        return []
    if "*" in function["return_type"] or function["return_type"] in pointer_typedefs:
        return ["    return NULL;"]
    return ["    return 0;"]


def render(functions, pointer_typedefs, header_label, swift_file_count):
    lines = [
        "/*",
        " * ZakuroStub.c - generated by scripts/gen-zakuro-stub.py. DO NOT EDIT.",
        " *",
        " * The iOS Simulator cannot link libzakuro_ios.a (an arm64 device build),",
        " * so the 3ds2apple-preview target links these empty implementations of",
        " * the zk_* functions its Swift sources reference instead. Signatures come",
        " * from ios/ZakuroBridge.h, which stays the single source of truth; the",
        " * preview app only draws UI and never starts a console.",
        " *",
        " * Header:         %s" % header_label,
        " * Swift sources:  %d file(s) under ios/app/Sources" % swift_file_count,
        " * Functions:      %d referenced" % len(functions),
        " * Regenerate:     scripts/ios-ui-preview.sh (python3 scripts/gen-zakuro-stub.py)",
        " */",
        "",
        "#include <stdlib.h>",
        "",
        "#include \"ZakuroBridge.h\"",
        "",
        "#if defined(__clang__)",
        "#pragma clang diagnostic ignored \"-Wunused-parameter\"",
        "#endif",
        "",
        "/* -------------------------------- functions ------------------------------ */",
        "",
    ]
    for function in functions:
        lines.append("/* Prototype from ios/ZakuroBridge.h; the preview app never calls it. */")
        lines.append(declaration(function))
        lines.append("{")
        lines.extend(body(function, pointer_typedefs))
        lines.append("}")
        lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


def main(argv):
    parser = argparse.ArgumentParser(
        description="Generate the zk_* C stub for the iOS Simulator preview app.",
    )
    parser.add_argument("--repo-root", default=REPO_ROOT,
                        help="repository root (default: %(default)s)")
    parser.add_argument("--header", default=None,
                        help="ZakuroBridge.h path (default: <repo>/ios/ZakuroBridge.h)")
    parser.add_argument("--swift-dir", default=None,
                        help="Swift sources directory (default: <repo>/ios/app/Sources)")
    parser.add_argument("--output", default=None,
                        help="generated C file, or '-' for stdout "
                             "(default: <repo>/ios/preview/generated/ZakuroStub.c)")
    parser.add_argument("--verbose", action="store_true",
                        help="also list zk_* identifiers that are not header functions")
    args = parser.parse_args(argv)

    repo_root = os.path.abspath(args.repo_root)
    header_path = os.path.abspath(args.header or os.path.join(repo_root, DEFAULT_HEADER))
    swift_dir = os.path.abspath(args.swift_dir or os.path.join(repo_root, DEFAULT_SWIFT_DIR))
    output_path = args.output or os.path.join(repo_root, DEFAULT_OUTPUT)

    if not os.path.isfile(header_path):
        fail("header not found: %s" % header_path)
    if not os.path.isdir(swift_dir):
        fail("Swift sources directory not found: %s" % swift_dir)

    functions, unparsable, pointer_typedefs = parse_header(header_path)
    if unparsable:
        sys.stderr.write("gen-zakuro-stub: cannot generate a stub for these "
                         "declarations in %s:\n" % header_path)
        for line in unparsable:
            sys.stderr.write("  - %s\n" % line)
        fail("%d declaration(s) could not be parsed" % len(unparsable))
    if not functions:
        fail("no zk_* function declarations found in %s (header format changed?)" % header_path)

    identifiers, calls, swift_file_count = scan_swift(swift_dir)
    declared = set(function["name"] for function in functions)
    unknown_calls = sorted(name for name in calls if name not in declared)
    if unknown_calls:
        sys.stderr.write("gen-zakuro-stub: the Swift sources call these zk_* "
                         "functions, but %s does not declare them:\n" % header_path)
        for name in unknown_calls:
            sys.stderr.write("  - %s\n" % name)
        fail("add them to ios/ZakuroBridge.h first, then regenerate the stub")

    referenced = [function for function in functions if function["name"] in identifiers]
    if not referenced:
        fail("the Swift sources reference none of the functions in %s; "
             "refusing to write an empty stub" % header_path)

    header_label = os.path.relpath(header_path, repo_root)
    text = render(referenced, pointer_typedefs, header_label, swift_file_count)

    if output_path == "-":
        sys.stdout.write(text)
    else:
        directory = os.path.dirname(os.path.abspath(output_path))
        if directory and not os.path.isdir(directory):
            os.makedirs(directory)
        with open(output_path, "w", encoding="utf-8") as handle:
            handle.write(text)
        print("gen-zakuro-stub: wrote %d stub(s) to %s" % (len(referenced), output_path))

    unreferenced = [function["name"] for function in functions
                    if function["name"] not in identifiers]
    print("gen-zakuro-stub: %d of %d header function(s) referenced by the shell; "
          "%d Swift file(s) scanned" % (len(referenced), len(functions), swift_file_count))
    if unreferenced:
        print("gen-zakuro-stub: declared in the header, not referenced (no stub): %s"
              % ", ".join(unreferenced))
    if args.verbose:
        ignored = sorted(identifier for identifier in identifiers if identifier not in declared)
        if ignored:
            print("gen-zakuro-stub: zk_* identifiers that are not functions: %s"
                  % ", ".join(ignored))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

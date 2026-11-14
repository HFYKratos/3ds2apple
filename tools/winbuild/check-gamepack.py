#!/usr/bin/env python3
"""check-gamepack.py - validate a locally cross-built 3ds2apple GamePack Mach-O dylib.

Part of 3ds2apple (Apache-2.0). Pure Python 3 standard library: it does not
need Apple's tools (otool/codesign/lipo) or a macOS host, so the same check
runs on Windows (bundled Python), Linux/WSL and macOS.  It parses the Mach-O
header and load commands directly:

  * thin 64-bit Mach-O dylib (MH_DYLIB)
  * CPU arch matches --target (arm64 device / x86_64 simulator)
  * LC_BUILD_VERSION platform is iOS or iOS Simulator and minos >= 16.0
  * LC_ID_DYLIB install name is @rpath/GamePack-<TITLE>.dylib
  * exports the GamePack pack ABI: zk_gamepack_title_id / zk_gamepack_abi_version
    / zk_gamepack_register, plus the seven 3dsrecomp tables the runtime needs
  * keeps zk_register_gamepack undefined (resolved from the host app at dlopen)
  * does NOT define any Zakuro runtime symbol (zk_create/zk_register_gamepack/...)
  * reports every other undefined import (libSystem calls such as memcpy,
    sqrtf, __stack_chk_guard) so an unexpected dependency is visible

Exit code 0 = valid, 1 = validation failed, 2 = usage/IO error.

Usage:
  python3 tools/winbuild/check-gamepack.py FILE --target device|simulator
        [--title-id 0004000000055E00] [--json] [--allow-non-gamepack]
"""
import argparse
import json
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_DYLIB = 6
CPU_TYPE_X86_64 = 0x01000007
CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_MASK = 0xFF000000

PLATFORM_IOS = 2
PLATFORM_IOSSIMULATOR = 7
PLATFORM_NAMES = {
    1: "macos", 2: "ios", 3: "tvos", 4: "watchos", 5: "bridgeos",
    6: "maccatalyst", 7: "iossimulator", 8: "tvosstimulator",
    9: "watchossimulator", 10: "driverkit", 11: "visionos", 12: "visionossimulator",
}
ARCH_NAMES = {CPU_TYPE_X86_64: "x86_64", CPU_TYPE_ARM64: "arm64", 7: "x86_64", 12: "arm64"}

LC_SEGMENT_64 = 0x19
LC_ID_DYLIB = 0xD
LC_MAIN = 0x80000028
LC_CODE_SIGNATURE = 0x1D
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
LC_UUID = 0x1B
LC_SYMTAB = 0x2
LC_DYLD_EXPORTS_TRIE = 0x80000033
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022

N_STAB = 0xE0
N_TYPE = 0x0E
N_UNDF = 0x0
N_EXT = 0x1

PACK_EXPORTS = [
    "zk_gamepack_title_id",
    "zk_gamepack_abi_version",
    "zk_gamepack_register",
    "recomp_abi",
    "recomp_generation",
    "recomp_entry_count",
    "recomp_entries",
    "recomp_module_count",
    "recomp_modules",
    "recomp_origins",
]
RUNTIME_SYMBOLS = [
    "zk_create", "zk_register_gamepack", "zk_unregister_gamepack",
    "zk_gamepack_registered", "zk_registered_gamepack_title_id",
    "zk_destroy", "zk_step", "zk_run",
]


def cstr(raw, off):
    end = raw.find(b"\0", off)
    if end < 0:
        end = len(raw)
    return raw[off:end].decode("utf-8", "replace")


def align8(v):
    return (v + 7) & ~7


class MachOError(Exception):
    pass


def parse(path):
    with open(path, "rb") as handle:
        raw = handle.read()
    if len(raw) < 32:
        raise MachOError("file is too small to be a Mach-O")
    magic = struct.unpack_from("<I", raw, 0)[0]
    if magic != MH_MAGIC_64:
        if struct.unpack_from(">I", raw, 0)[0] == MH_MAGIC_64:
            raise MachOError("big-endian Mach-O is not expected for Apple arm64/x86_64")
        raise MachOError("not a thin 64-bit Mach-O (magic %#x)" % magic)
    cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags = struct.unpack_from("<iiIIII", raw, 4)
    info = {
        "path": path,
        "bytes": len(raw),
        "cputype": cputype,
        "cpusubtype": cpusubtype,
        "arch": ARCH_NAMES.get(cputype & 0xFFFFFFFF, "unknown(%d)" % cputype),
        "filetype": filetype,
        "flags": flags,
        "install_name": None,
        "platform": None,
        "minos": None,
        "sdk": None,
        "uuid": None,
        "has_main": False,
        "has_code_signature": False,
        "has_exports_trie": False,
        "symtab": None,
        "exports": [],
        "imports": [],
    }
    if filetype != MH_DYLIB:
        raise MachOError("filetype %d is not MH_DYLIB (%d)" % (filetype, MH_DYLIB))
    off = 32
    for _ in range(ncmds):
        if off + 8 > len(raw):
            raise MachOError("truncated load commands")
        cmd, cmdsize = struct.unpack_from("<II", raw, off)
        if cmdsize < 8 or off + cmdsize > len(raw):
            raise MachOError("bad load command at offset %d" % off)
        if cmd == LC_ID_DYLIB:
            name_off = struct.unpack_from("<I", raw, off + 8)[0]
            info["install_name"] = cstr(raw, off + name_off)
        elif cmd == LC_BUILD_VERSION:
            platform, minos, sdk = struct.unpack_from("<III", raw, off + 8)
            info["platform"] = PLATFORM_NAMES.get(platform, "platform-%d" % platform)
            info["minos"] = "%d.%d.%d" % (minos >> 16, (minos >> 8) & 0xFF, minos & 0xFF)
            info["sdk"] = "%d.%d.%d" % (sdk >> 16, (sdk >> 8) & 0xFF, sdk & 0xFF)
        elif cmd == LC_VERSION_MIN_IPHONEOS:
            version = struct.unpack_from("<I", raw, off + 8)[0]
            info["platform"] = "ios"
            info["minos"] = "%d.%d.%d" % (version >> 16, (version >> 8) & 0xFF, version & 0xFF)
        elif cmd == LC_UUID:
            info["uuid"] = "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X" % struct.unpack_from("16B", raw, off + 8)
        elif cmd == LC_MAIN:
            info["has_main"] = True
        elif cmd == LC_CODE_SIGNATURE:
            info["has_code_signature"] = True
        elif cmd in (LC_DYLD_EXPORTS_TRIE,):
            info["has_exports_trie"] = True
        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, strsize = struct.unpack_from("<IIII", raw, off + 8)
            info["symtab"] = (symoff, nsyms, stroff, strsize)
        off += cmdsize
    symtab = info["symtab"]
    if symtab is not None:
        symoff, nsyms, stroff, strsize = symtab
        # nlist_64: n_strx(u32) n_type(u8) n_sect(u8) n_desc(u16) n_value(u64)
        for index in range(nsyms):
            entry = symoff + index * 16
            if entry + 16 > len(raw) or stroff + strsize > len(raw):
                break
            n_strx, n_type, _n_sect, _n_desc, _n_value = struct.unpack_from("<IBBHQ", raw, entry)
            if n_type & N_STAB:
                continue
            if n_strx == 0 or n_strx >= strsize:
                continue
            name = cstr(raw, stroff + n_strx)
            kind = n_type & N_TYPE
            if kind == N_UNDF:
                info["imports"].append(name)
            elif n_type & N_EXT:
                info["exports"].append(name)
    # Mach-O symbol names carry a leading underscore for C symbols; compare
    # against the C names the ABI documents.
    info["exports"] = sorted(set(n[1:] if n.startswith("_") else n for n in info["exports"]))
    info["imports"] = sorted(set(n[1:] if n.startswith("_") else n for n in info["imports"]))
    return info


def version_tuple(text):
    if not text:
        return None
    return tuple(int(part) for part in text.split("."))


def check(info, target, title_id, allow_non_gamepack):
    failures = []
    warnings = []
    expected_arch = "arm64" if target == "device" else "x86_64"
    expected_platforms = ("ios",) if target == "device" else ("iossimulator",)
    exports = set(info["exports"])
    imports = set(info["imports"])

    if info["arch"] != expected_arch:
        failures.append("arch is %s, expected %s for target %s" % (info["arch"], expected_arch, target))
    if info["platform"] not in expected_platforms:
        failures.append("platform is %r, expected %r for target %s" % (info["platform"], expected_platforms[0], target))
    minos = version_tuple(info["minos"])
    if minos is None or minos < (16, 0, 0):
        failures.append("minos is %r, expected >= 16.0" % (info["minos"],))
    install_name = info["install_name"] or ""
    if not install_name.startswith("@rpath/"):
        failures.append("LC_ID_DYLIB install name %r is not @rpath/..." % install_name)
    if title_id and title_id not in install_name:
        failures.append("LC_ID_DYLIB install name %r does not name title %s" % (install_name, title_id))
    if info["has_main"]:
        failures.append("dylib declares LC_MAIN (it is not a dylib)")

    missing = [name for name in PACK_EXPORTS if name not in exports]
    if missing:
        failures.append("missing GamePack exports: %s" % " ".join(missing))
    if "zk_register_gamepack" not in imports:
        failures.append("zk_register_gamepack is not an undefined import (the pack must call the host app's runtime)")
    defined_runtime = [name for name in RUNTIME_SYMBOLS if name in exports and name != "zk_register_gamepack"]
    if defined_runtime:
        failures.append("pack defines runtime symbols (it must not carry the runtime): %s" % " ".join(defined_runtime))
    unexpected_runtime = [name for name in RUNTIME_SYMBOLS if name in imports and name != "zk_register_gamepack"]
    if unexpected_runtime:
        warnings.append("pack imports other runtime symbols: %s" % " ".join(unexpected_runtime))
    if not allow_non_gamepack:
        extra_deps = [name for name in info["imports"] if not is_expected_dependency(name)]
        if extra_deps:
            warnings.append("unexpected undefined imports: %s" % " ".join(extra_deps[:12]))
    if info["has_code_signature"]:
        warnings.append("dylib carries an embedded code signature (ad-hoc?); the IPA signer re-signs nested dylibs")
    return failures, warnings


def is_expected_dependency(name):
    """libSystem calls a generated game pack may leave for dlopen() to resolve."""
    if name == "zk_register_gamepack":  # resolved from the host app, by design
        return True
    if name.startswith("__"):
        return True
    import re
    libc = re.compile(
        r"^(mem|str|wcs|sn?printf|v?printf|puts|putchar|f?getc|fputc|fputs|fopen|fclose|"
        r"fread|fwrite|fflush|fseek|ftell|rewind|malloc|calloc|realloc|free|abort|exit|"
        r"atexit|getenv|qsort|bsearch|abs|labs|div|ldiv|atoi|atol|atof|strto[a-z]*|"
        r"(a|s|t)(sin|cos|tan|sinh|cosh|tanh|tan|asin|acos|atan|atan2)(f|l)?|"
        r"sqrt(f|l)?|pow(f|l)?|exp(f|2f|m1f|l)?|log(f|10f|2f|1pf|b(f|l)?)?|"
        r"fabs(f|l)?|floor(f|l)?|ceil(f|l)?|round(f|l)?|trunc(f|l)?|rint(f|l)?|"
        r"nearbyint(f|l)?|fmod(f|l)?|fmin(f|l)?|fmax(f|l)?|hypot(f|l)?|cbrt(f|l)?|"
        r"copysign(f|l)?|fma(f|l)?|ldexp(f|l)?|frexp(f|l)?|scalbn(f|l)?|modf(f|l)?|"
        r"remainder(f|l)?|remquo(f|l)?|fdim(f|l)?|isnan|isinf|ilogb(f|l)?|lgamma(f|l)?)$"
    )
    return bool(libc.match(name))


def main(argv):
    parser = argparse.ArgumentParser(description="Validate a cross-built GamePack Mach-O dylib")
    parser.add_argument("file")
    parser.add_argument("--target", choices=("device", "sim", "simulator"), default="device")
    parser.add_argument("--title-id", default="")
    parser.add_argument("--json", action="store_true", help="print a JSON report")
    parser.add_argument("--allow-non-gamepack", action="store_true",
                        help="only warn about missing GamePack ABI (preview tooling)")
    args = parser.parse_args(argv)
    target = "sim" if args.target in ("sim", "simulator") else "device"
    title_id = args.title_id.upper()
    try:
        info = parse(args.file)
        failures, warnings = check(info, target, title_id, args.allow_non_gamepack)
    except (OSError, MachOError) as exc:
        print("check-gamepack: ERROR: %s" % exc, file=sys.stderr)
        return 2
    report = {
        "schema": "gamepack-check/1",
        "file": args.file,
        "bytes": info["bytes"],
        "arch": info["arch"],
        "filetype": info["filetype"],
        "platform": info["platform"],
        "minos": info["minos"],
        "sdk": info["sdk"],
        "install_name": info["install_name"],
        "uuid": info["uuid"],
        "exports": info["exports"],
        "imports": info["imports"],
        "import_count": len(info["imports"]),
        "failures": failures,
        "warnings": warnings,
        "ok": not failures,
    }
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print("file:        %s (%d bytes)" % (args.file, info["bytes"]))
        print("arch:        %s" % info["arch"])
        print("platform:    %s (minos %s, sdk %s)" % (info["platform"], info["minos"], info["sdk"]))
        print("install:     %s" % info["install_name"])
        print("uuid:        %s" % info["uuid"])
        print("exports:     %d (GamePack ABI + recomp tables: %s)"
              % (len(info["exports"]), "yes" if not failures or all(n in info["exports"] for n in PACK_EXPORTS) else "no"))
        print("imports:     %d undefined (resolved from libSystem/app at dlopen)"
              % len(info["imports"]))
        for warning in warnings:
            print("warning:     %s" % warning)
        for failure in failures:
            print("FAIL:        %s" % failure)
        print("result:      %s" % ("ok" if not failures else "FAILED (%d)" % len(failures)))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

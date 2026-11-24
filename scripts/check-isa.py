#!/usr/bin/python3 -I
"""Scan a root filesystem for x86-64 ELF objects that require more than x86-64-v2.

Two independent signals are checked:

1. The GNU property note GNU_PROPERTY_X86_ISA_1_NEEDED (emitted by GCC/binutils
   when building with -march=x86-64-vN and -mneeded / ISA marking, which is
   how EL10 marks its binaries).  If the NEEDED bitmask contains v3 or v4 the
   object will refuse to load (glibc) or may SIGILL on an x86-64-v2 CPU.
2. Go build settings embedded in the binary ("GOAMD64=v3"/"GOAMD64=v4").
   Go binaries do not carry the GNU property note, so this catches them.

Exit status: 0 when nothing above v2 is found, 1 otherwise, 2 on usage error.
"""

import argparse
import os
import stat
import struct
import sys

ELF_MAGIC = b"\x7fELF"
EM_X86_64 = 62
PT_NOTE = 4
PT_GNU_PROPERTY = 0x6474E553
NT_GNU_PROPERTY_TYPE_0 = 5
GNU_PROPERTY_X86_ISA_1_NEEDED = 0xC0008002
ISA_V2 = 1 << 1
ISA_V3 = 1 << 2
ISA_V4 = 1 << 3
ISA_NAMES = {1: "baseline", ISA_V2: "v2", ISA_V3: "v3", ISA_V4: "v4"}

# Directories that never contain host binaries worth scanning.
SKIP_DIRS = {"proc", "sys", "dev", "run", "tmp", "sysroot"}
# glibc only loads libraries from glibc-hwcaps/<level>/ on CPUs that support
# <level>, so optimised v3/v4 variants there are expected and harmless.
HWCAPS_OPTIONAL = {"x86-64-v3", "x86-64-v4"}


def optional_hwcaps(rel):
    parts = rel.split(os.sep)
    return any(parts[i] == "glibc-hwcaps" and parts[i + 1] in HWCAPS_OPTIONAL
               for i in range(len(parts) - 1))


def align(value, alignment):
    return (value + alignment - 1) & ~(alignment - 1)


def parse_properties(desc):
    """Return the GNU_PROPERTY_X86_ISA_1_NEEDED bitmask from a property desc."""
    off = 0
    while off + 8 <= len(desc):
        pr_type, pr_datasz = struct.unpack_from("<II", desc, off)
        off += 8
        data = desc[off:off + pr_datasz]
        if pr_type == GNU_PROPERTY_X86_ISA_1_NEEDED and len(data) >= 4:
            return struct.unpack_from("<I", data)[0]
        off = align(off + pr_datasz, 8)
    return None


def isa_needed(f):
    """Return the ISA NEEDED bitmask of an ELF64 x86-64 file, or None."""
    f.seek(0)
    ehdr = f.read(64)
    if len(ehdr) < 64 or ehdr[:4] != ELF_MAGIC or ehdr[4] != 2 or ehdr[5] != 1:
        return None
    (e_machine,) = struct.unpack_from("<H", ehdr, 18)
    if e_machine != EM_X86_64:
        return None
    e_phoff, = struct.unpack_from("<Q", ehdr, 32)
    e_phentsize, e_phnum = struct.unpack_from("<HH", ehdr, 54)
    if e_phoff == 0 or e_phnum == 0:
        return None
    f.seek(e_phoff)
    phdrs = f.read(e_phentsize * e_phnum)
    notes = []
    for i in range(e_phnum):
        p_type, _flags, p_offset, _vaddr, _paddr, p_filesz = struct.unpack_from(
            "<IIQQQQ", phdrs, i * e_phentsize)
        if p_type == PT_GNU_PROPERTY:
            notes = [(p_offset, p_filesz)]
            break
        if p_type == PT_NOTE:
            notes.append((p_offset, p_filesz))
    for p_offset, p_filesz in notes:
        f.seek(p_offset)
        buf = f.read(p_filesz)
        off = 0
        while off + 12 <= len(buf):
            namesz, descsz, ntype = struct.unpack_from("<III", buf, off)
            off += 12
            name = buf[off:off + namesz]
            off = align(off + namesz, 8)
            desc = buf[off:off + descsz]
            off = align(off + descsz, 8)
            if ntype == NT_GNU_PROPERTY_TYPE_0 and name.rstrip(b"\0") == b"GNU":
                needed = parse_properties(desc)
                if needed is not None:
                    return needed
    return 0


def goamd64_level(path, size):
    """Return 'v3'/'v4' if a Go binary was built for that level, else None."""
    if size > 1 << 30:
        return None
    with open(path, "rb") as f:
        data = f.read()
    if b"\xff Go buildinf:" not in data:
        return None
    for level in (b"v4", b"v3"):
        if b"\tGOAMD64=" + level + b"\n" in data:
            return level.decode()
    return None


def describe(mask):
    return ",".join(name for bit, name in ISA_NAMES.items() if mask & bit) or "none"


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("rootfs", help="root filesystem directory to scan")
    parser.add_argument("--max-report", type=int, default=50,
                        help="maximum offending files to print (default: 50)")
    args = parser.parse_args()

    if not os.path.isdir(args.rootfs):
        print(f"error: {args.rootfs} is not a directory", file=sys.stderr)
        return 2

    scanned = 0
    hwcaps = 0
    offenders = []
    root = os.path.abspath(args.rootfs)
    for dirpath, dirnames, filenames in os.walk(root):
        if dirpath == root:
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            path = os.path.join(dirpath, name)
            try:
                st = os.lstat(path)
                if not stat.S_ISREG(st.st_mode) or st.st_size < 64:
                    continue
                with open(path, "rb") as f:
                    if f.read(4) != ELF_MAGIC:
                        continue
                    needed = isa_needed(f)
                if needed is None:
                    continue
                scanned += 1
                rel = os.path.relpath(path, root)
                if optional_hwcaps(rel):
                    hwcaps += 1
                    continue
                if needed & (ISA_V3 | ISA_V4):
                    offenders.append((rel, "gnu-property", describe(needed)))
                    continue
                level = goamd64_level(path, st.st_size)
                if level:
                    offenders.append((rel, "go-buildinfo", f"GOAMD64={level}"))
            except (OSError, struct.error):
                continue

    print(f"scanned {scanned} x86-64 ELF objects under {root}"
          + (f" ({hwcaps} optional glibc-hwcaps v3/v4 objects ignored)" if hwcaps else ""))
    if not offenders:
        print("OK: no object requires more than x86-64-v2")
        return 0
    print(f"FAIL: {len(offenders)} object(s) require more than x86-64-v2:")
    for rel, source, detail in offenders[:args.max_report]:
        print(f"  /{rel}  [{source}: {detail}]")
    if len(offenders) > args.max_report:
        print(f"  ... and {len(offenders) - args.max_report} more")
    return 1


if __name__ == "__main__":
    sys.exit(main())

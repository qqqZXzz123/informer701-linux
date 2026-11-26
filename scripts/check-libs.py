#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check-libs.py - проверка: у каждого ELF-файла в rootfs Debian armhf (glibc)
есть все нужные разделяемые библиотеки (DT_NEEDED).

    python3 scripts/check-libs.py <каталог-rootfs> [--quiet]

Использует свой разбор ELF (readelf/objdump не нужны), поддерживает ELF32/ELF64,
учитывает multiarch-каталоги Debian (/usr/lib/arm-linux-gnueabihf), merged-usr
и chroot-относительные абсолютные симлинки.
"""
import os
import struct
import sys

LIBDIRS = (
    "lib",
    "usr/lib",
    "usr/local/lib",
    "lib/arm-linux-gnueabihf",
    "usr/lib/arm-linux-gnueabihf",
)
# библиотеки, которые даёт ядро/динамический линкер
VIRTUAL = {
    "linux-vdso.so.1",
    "linux-gate.so.1",
    "ld-linux.so.2",
    "ld-linux-armhf.so.3",
}

SHT_DYNAMIC = 6


def resolve_in_root(root, path):
    """Разрешает цепочку симлинков внутри chroot-корня `root` (без выхода в / хоста)."""
    cur = path
    for _ in range(32):
        if not os.path.islink(cur):
            return cur
        target = os.readlink(cur)
        if target.startswith("/"):
            cur = os.path.normpath(os.path.join(root, target.lstrip("/")))
        else:
            cur = os.path.normpath(os.path.join(os.path.dirname(cur), target))
    return cur


def parse_dynamic(path):
    """-> (needed:list, soname:str|None) для ELF-файла; None если не ELF."""
    try:
        with open(path, "rb") as f:
            ident = f.read(16)
            if len(ident) < 16 or ident[:4] != b"\x7fELF":
                return None
            is64 = ident[4] == 2
            le = "<" if ident[5] == 1 else ">"
            f.seek(0)
            hdr = f.read(64 if is64 else 52)
            if is64:
                e_shoff = struct.unpack_from(le + "Q", hdr, 0x28)[0]
                e_shentsize = struct.unpack_from(le + "H", hdr, 0x3A)[0]
                e_shnum = struct.unpack_from(le + "H", hdr, 0x3C)[0]
            else:
                e_shoff = struct.unpack_from(le + "I", hdr, 0x20)[0]
                e_shentsize = struct.unpack_from(le + "H", hdr, 0x2E)[0]
                e_shnum = struct.unpack_from(le + "H", hdr, 0x30)[0]
            if not e_shoff or not e_shnum or e_shnum > 4096:
                return None
            f.seek(e_shoff)
            shs = f.read(e_shentsize * e_shnum)
            dyn = None
            for i in range(e_shnum):
                off = i * e_shentsize
                if len(shs) < off + e_shentsize:
                    break
                sh_type = struct.unpack_from(le + "I", shs, off + 4)[0]
                if sh_type == SHT_DYNAMIC:
                    if is64:
                        sh_offset = struct.unpack_from(le + "Q", shs, off + 0x18)[0]
                        sh_size = struct.unpack_from(le + "Q", shs, off + 0x20)[0]
                        sh_link = struct.unpack_from(le + "I", shs, off + 0x28)[0]
                    else:
                        sh_offset = struct.unpack_from(le + "I", shs, off + 0x10)[0]
                        sh_size = struct.unpack_from(le + "I", shs, off + 0x14)[0]
                        sh_link = struct.unpack_from(le + "I", shs, off + 0x18)[0]
                    dyn = (sh_offset, sh_size, sh_link)
                    break
            if dyn is None:
                return None
            sh_offset, sh_size, sh_link = dyn
            off = sh_link * e_shentsize
            if is64:
                str_off = struct.unpack_from(le + "Q", shs, off + 0x18)[0]
                str_size = struct.unpack_from(le + "Q", shs, off + 0x20)[0]
            else:
                str_off = struct.unpack_from(le + "I", shs, off + 0x10)[0]
                str_size = struct.unpack_from(le + "I", shs, off + 0x14)[0]
            f.seek(str_off)
            strtab = f.read(str_size)
            f.seek(sh_offset)
            dynb = f.read(sh_size)

            def s(idx):
                end = strtab.find(b"\0", idx)
                return strtab[idx:end if end >= 0 else len(strtab)].decode("utf-8", "replace")

            needed, soname = [], None
            ent = 16 if is64 else 8
            fmt = le + ("QQ" if is64 else "II")
            for i in range(0, len(dynb) - ent + 1, ent):
                tag, val = struct.unpack_from(fmt, dynb, i)
                if tag == 0:
                    break
                if tag == 1:
                    needed.append(s(val))
                elif tag == 14:
                    soname = s(val)
            return needed, soname
    except (OSError, struct.error):
        return None


def main():
    argv = [a for a in sys.argv[1:] if not a.startswith("-")]
    quiet = "--quiet" in sys.argv or "-q" in sys.argv
    if not argv:
        print("использование: check-libs.py <rootfs> [--quiet]", file=sys.stderr)
        return 2
    root = os.path.abspath(argv[0])
    if not os.path.isdir(root):
        print("нет каталога %s" % root, file=sys.stderr)
        return 2

    # 1) какие soname/имена файлов есть в корневой ФС
    have = set(VIRTUAL)
    libfiles = set()
    seen_dirs = set()
    for d in LIBDIRS:
        base = resolve_in_root(root, os.path.join(root, d))
        if not os.path.isdir(base):
            continue
        for dirpath, dirs, files in os.walk(base):
            real_dir = resolve_in_root(root, dirpath)
            if real_dir in seen_dirs:
                dirs[:] = []
                continue
            seen_dirs.add(real_dir)
            for fn in files:
                p = os.path.join(dirpath, fn)
                rp = resolve_in_root(root, p)
                if not os.path.exists(rp):
                    continue
                have.add(fn)
                libfiles.add(rp)
    for p in libfiles:
        r = parse_dynamic(p)
        if r and r[1]:
            have.add(r[1])

    # 2) обходим все ELF-файлы и сверяем DT_NEEDED
    missing = {}
    nelf = 0
    for dirpath, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in ("proc", "sys", "dev")]
        for fn in files:
            p = os.path.join(dirpath, fn)
            if os.path.islink(p):
                continue
            # пропускаем модули ядра (.ko / .ko.xz)
            if fn.endswith((".ko", ".ko.xz", ".o")):
                continue
            try:
                if os.path.getsize(p) < 64:
                    continue
                with open(p, "rb") as f:
                    if f.read(4) != b"\x7fELF":
                        continue
            except OSError:
                continue
            nelf += 1
            r = parse_dynamic(p)
            if not r:
                continue
            for lib in r[0]:
                if lib in have:
                    continue
                missing.setdefault(lib, []).append(os.path.relpath(p, root))

    if not quiet:
        print("ELF-файлов проверено: %d, известно библиотек/soname: %d"
              % (nelf, len(have)))
    if not missing:
        if not quiet:
            print("check-libs: OK - все DT_NEEDED найдены")
        return 0

    print("check-libs: НЕ ХВАТАЕТ БИБЛИОТЕК:", file=sys.stderr)
    for lib in sorted(missing):
        who = sorted(set(missing[lib]))
        print("  %-24s нужно: %s%s" % (lib, ", ".join(who[:6]),
                                        " (+%d)" % (len(who) - 6) if len(who) > 6 else ""),
              file=sys.stderr)
    return 1 if os.environ.get("ALLOW_MISSING_LIBS") != "1" else 0


if __name__ == "__main__":
    sys.exit(main())

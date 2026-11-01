#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fetch-apks.py - скачивает в informer701-linux/pkgs/ пакеты Alpine v3.20 (armv7)
ВМЕСТЕ с их библиотеками-подпакетами.

Зачем этот скрипт существует
---------------------------
Первая версия резолвера пропускала все зависимости вида `so:libX.so.N`
(«библиотеки базовой системы»). В Alpine 3.20 это неверно: многие библиотеки
вынесены в отдельные подпакеты, которых в minirootfs нет:

    kmod           -> so:liblzma.so.5  (xz-libs), so:libzstd.so.1 (zstd-libs)
    iptables       -> so:libmnl.so.0, so:libnftnl.so.11, so:libxtables.so.12
    iptables-legacy-> so:libip4tc.so.2, so:libip6tc.so.2, so:libxtables.so.12
    wpa_supplicant -> so:libdbus-1.so.3 (dbus-libs), so:libpcsclite.so.1
    usbutils       -> so:libudev.so.1 (eudev-libs), so:libusb-1.0.so.0 (libusb)
    nano/htop      -> so:libncursesw.so.6 (ncurses-libs)
    iproute2       -> so:libcap.so.2 (libcap), so:libmnl.so.0

Без них бинарники в образе есть, но не запускаются
(«Error loading shared library ...»). Лечится только пересборкой образа,
поэтому резолвер обязан тянуть `so:`-зависимости, а удовлетворённые
определять по факту - сканированием уже распакованного minirootfs.

Использование
-------------
    python3 scripts/fetch-apks.py [пакет ...]     # + список SEED ниже
    BASE_ROOTFS=/tmp/base-rootfs python3 scripts/fetch-apks.py
    DRY=1 python3 scripts/fetch-apks.py           # только отчёт, без скачивания

Кэш индексов: /tmp/apkindex-*.gz (не перекачивается при повторных запусках).
"""
import io
import os
import re
import sys
import tarfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(HERE)
PKGS = os.environ.get("PKGS", os.path.join(PROJ, "pkgs"))
CACHE = os.environ.get("CACHE", "/tmp")
DRY = os.environ.get("DRY", "") == "1"

REPOS = {
    "main": "https://dl-cdn.alpinelinux.org/alpine/v3.20/main/armv7/",
    "community": "https://dl-cdn.alpinelinux.org/alpine/v3.20/community/armv7/",
}

# что нам нужно на плате (библиотеки подтянутся автоматически)
SEED = """
kmod iw wpa_supplicant hostapd dnsmasq wireless-regdb iptables iptables-legacy
iproute2 iproute2-ss iproute2-tc iproute2-minimal usbutils nano htop picocom
tzdata xz dosfstools e2fsprogs e2fsprogs-extra libnl3 wireless-tools haveged
i2c-tools memtester devmem2 dropbear dropbear-scp dropbear-dbclient
busybox-extras dnsmasq-common hwdata-usb
""".split()

# базовые пакеты minirootfs: ставить нельзя (busybox-binsh/yash-binsh подменят
# /bin/sh, apk-tools/musl и так на месте)
SKIP = set("""
alpine-baselayout alpine-baselayout-data alpine-keys apk-tools busybox
busybox-binsh ca-certificates-bundle libcrypto3 libssl3 musl musl-utils
musl-locales musl-locales-page scanelf ssl_client zlib yash yash-binsh
libc-utils ncurses-terminfo-base
""".split())

# базовый rootfs - из него берём «что уже удовлетворено»
BASE_ROOTFS = os.environ.get(
    "BASE_ROOTFS", os.path.join(PROJ, "pkgs", "..", "prebuilt", "minirootfs-x")
)


def get(url, cache_name=None):
    if cache_name:
        p = os.path.join(CACHE, cache_name)
        if os.path.exists(p) and os.path.getsize(p) > 1000:
            return open(p, "rb").read()
    last = None
    for _ in range(3):
        try:
            data = urllib.request.urlopen(url, timeout=120).read()
            if cache_name:
                open(os.path.join(CACHE, cache_name), "wb").write(data)
            return data
        except Exception as e:  # noqa: BLE001
            last = e
            print("  повтор", url, e, file=sys.stderr)
    raise SystemExit("не смог скачать %s (%s)" % (url, last))


# ---------------------------------------------------------------- индекс
db = {}          # имя пакета -> запись
provides = {}    # виртуальное имя (so:.../cmd:...) -> имя пакета


def load_index():
    for repo, base in REPOS.items():
        raw = get(base + "APKINDEX.tar.gz", "apkindex-v320-%s.tar.gz" % repo)
        with tarfile.open(fileobj=io.BytesIO(raw)) as tf:
            data = tf.extractfile("APKINDEX").read().decode("utf-8", "replace")
        for block in data.split("\n\n"):
            f = {}
            for line in block.splitlines():
                # формат APKINDEX: "P:имя", "V:версия", "D:зависимости" - без пробела
                if len(line) > 2 and line[1] == ":":
                    f[line[0]] = line[2:].strip()
            if "P" not in f:
                continue
            rec = {
                "P": f["P"], "V": f["V"], "D": f.get("D", ""),
                "p": f.get("p", ""), "I": int(f.get("I", 0)),
                "F": f.get("F", f["P"][0]), "repo": repo, "base": base,
            }
            db.setdefault(rec["P"], rec)
            for pv in rec["p"].split():
                provides.setdefault(pv.split("=")[0], rec["P"])
    print("в индексе пакетов: %d, виртуальных имён: %d" % (len(db), len(provides)))


# ------------------------------------------- что уже есть в базовом rootfs
have_libs = set()      # libX.so.N и прочее
have_cmds = set()
have_paths = set()


def scan_base(path):
    """Собирает из распакованного minirootfs фактически присутствующие
    библиотеки, команды и пути - то, что уже удовлетворено."""
    if not os.path.isdir(path):
        return False
    for root, dirs, files in os.walk(path):
        rel = os.path.relpath(root, path).replace(os.sep, "/")
        if rel in ("lib", "usr/lib", "lib/arm-linux-gnueabihf"):
            for fn in files + dirs:
                m = re.match(r"(.*\.so[\w.-]*)$", fn)
                if m:
                    have_libs.add(m.group(1))
        if rel in ("bin", "sbin", "usr/bin", "usr/sbin", "usr/local/bin"):
            for fn in files:
                have_cmds.add(fn)
                have_paths.add("/" + rel + "/" + fn)
    return True


def satisfied(dep):
    """dep вида 'so:liblzma.so.5', 'cmd:xz', '/bin/sh', 'pc:foo', 'имя=версия'."""
    dep = dep.strip()
    if not dep or dep.startswith(("pc:", "pkgconfig")):
        return True                      # не критично для запуска
    if dep.startswith("/"):
        return dep in have_paths or os.path.basename(dep) in have_cmds
    if dep.startswith("so:"):
        return dep[3:].split("=")[0] in have_libs
    if dep.startswith("cmd:"):
        return dep[4:].split("=")[0] in have_cmds
    return False


def dep_name(tok):
    tok = re.split(r"[<>=~^]", tok.strip())[0].strip()
    if tok.startswith("!"):
        return None                        # конфликт - игнорируем
    return tok or None


chosen = {}
missing = []
skipped = []


def add(name, via=""):
    name = dep_name(name)
    if not name or name in chosen:
        return
    if name in SKIP:
        skipped.append((name, via))
        return
    rec = db.get(name)
    if rec is None:
        p = provides.get(name)
        rec = db.get(p) if p else None
    if rec is None:
        missing.append((name, via))
        return
    chosen[rec["P"]] = rec
    for d in rec["D"].split():
        if satisfied(d):
            continue
        add(d, rec["P"])


def main():
    seeds = SEED + sys.argv[1:]
    load_index()

    # базовый rootfs: распаковываем minirootfs во временный каталог
    base = BASE_ROOTFS
    if not scan_base(base):
        mr = os.path.join(PKGS, "alpine-minirootfs-3.20.9-armv7.tar.gz")
        base = os.path.join(CACHE, "base-rootfs-minirootfs")
        if not scan_base(base):
            if not os.path.exists(mr):
                raise SystemExit("нет ни %s, ни %s" % (base, mr))
            os.makedirs(base, exist_ok=True)
            with tarfile.open(mr) as tf:
                tf.extractall(base)
            have_libs.clear(); have_cmds.clear(); have_paths.clear()
            scan_base(base)
    print("базовый rootfs: %s (библиотек %d, команд %d)"
          % (base, len(have_libs), len(have_cmds)))

    for s in seeds:
        add(s, "SEED")

    os.makedirs(PKGS, exist_ok=True)
    total = 0
    added = []
    for name in sorted(chosen):
        r = chosen[name]
        fn = "%s-%s.apk" % (r["P"], r["V"])
        dest = os.path.join(PKGS, fn)
        new = not os.path.exists(dest)
        if not new and not DRY:
            pass
        if new and not DRY:
            data = get(r["base"] + fn)
            open(dest, "wb").write(data)
            sz = len(data)
        elif os.path.exists(dest):
            sz = os.path.getsize(dest)
        else:
            sz = r["I"]
        total += sz
        flag = "СКАЧАН" if new else "есть  "
        print("  %s %-26s %-18s %7.0f КБ (уст. %6.0f КБ) %-10s"
              % (flag, r["P"], r["V"], sz / 1024, r["I"] / 1024, r["repo"]))
        if new:
            added.append((r["P"], r["V"]))
    print("---- пакетов в наборе: %d, всего %.2f МБ (установленный размер %.2f МБ)"
          % (len(chosen), total / 1048576.0,
             sum(r["I"] for r in chosen.values()) / 1048576.0))
    if added:
        print("---- новых: " + ", ".join("%s %s" % a for a in added))
    if skipped:
        print("---- пропущено (базовые): "
              + ", ".join(sorted(set(n for n, _ in skipped))))
    if missing:
        print("!!!! НЕ НАШЛОСЬ: "
              + ", ".join("%s (из %s)" % m for m in sorted(set(missing))))
        sys.exit(2)


if __name__ == "__main__":
    main()

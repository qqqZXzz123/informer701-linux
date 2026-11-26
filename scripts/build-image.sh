#!/bin/bash
# build-image.sh - полная сборка SD-образа Debian 12 (Bookworm) armhf для платы
# Informer 701 из предсобранных U-Boot / ядра 6.6 в prebuilt/ и пакетной базы Debian.
#
# Все тяжёлые операции (debootstrap, chroot apt-get, сборка .img и сжатие .img.xz)
# выполняются СТРОГО во временной ФС (/tmp), не затрагивая рабочий каталог репозитория.
# После сборки распакованная rootfs удаляется, а финальный сжатый образ и SHA256
# сохраняются в /tmp/out-debian/ (или $COPYTO).
set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export PATH

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

HERE="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD:-debian}"
WORK="${WORK:-/tmp/informer701-work}"
COPYTO="${1:-${COPYTO:-/tmp/out-debian}}"
IMG_NAME="${IMG_NAME:-informer701-${BUILD}.img}"
KEEP_ROOTFS="${KEEP_ROOTFS:-0}"
KEEP_RAW_IMG="${KEEP_RAW_IMG:-0}"
REUSE_ROOTFS="${REUSE_ROOTFS:-0}"
REBUILD_DEVMEM2="${REBUILD_DEVMEM2:-0}"

for p in "$WORK" "$COPYTO"; do
    case "$p" in
        "$HERE"|"$HERE"/*)
            echo "ОШИБКА: путь сборки/вывода ($p) не должен находиться внутри репозитория ($HERE)!" >&2
            exit 1 ;;
    esac
done

rm -rf "$WORK/dtbs"
mkdir -p "$WORK/dtbs" "$COPYTO"

DEVMEM2_BIN="$HERE/prebuilt/devmem2"
if [ "$REBUILD_DEVMEM2" = "1" ] || [ ! -x "$DEVMEM2_BIN" ]; then
    if command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1 && [ -f "$HERE/src/devmem2.c" ]; then
        echo "=== [0/6] кросс-компиляция devmem2 (arm-linux-gnueabihf-gcc) ==="
        arm-linux-gnueabihf-gcc -O2 -Wall -Wextra -o "$WORK/devmem2" "$HERE/src/devmem2.c"
        DEVMEM2_BIN="$WORK/devmem2"
    fi
fi

echo "=== [1/6] подготовка вариантов DTB ==="
if command -v dtc >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && [ -f "$HERE/prebuilt/sun4i-a10-informer-701.dtb" ]; then
    dtc -I dtb -O dts -q -o "$WORK/dtbs/src.dts" "$HERE/prebuilt/sun4i-a10-informer-701.dtb"
    python3 "$HERE/scripts/mkdtb-variants.py" "$WORK/dtbs/src.dts" "$WORK/dtbs"
    for dts_f in "$WORK/dtbs"/*.dts; do
        [ "$(basename "$dts_f")" = "src.dts" ] && continue
        [ "$(basename "$dts_f")" = "base.dts" ] && continue
        dtc -I dts -O dtb -q -o "${dts_f%.dts}.dtb" "$dts_f"
    done
    cp "$HERE/prebuilt/sun4i-a10-informer-701.dtb" "$WORK/dtbs/sun4i-a10-informer-701.dtb"
    for d in "$HERE/prebuilt"/*.dtb; do
        [ -f "$WORK/dtbs/$(basename "$d")" ] || cp "$d" "$WORK/dtbs/"
    done
else
    cp "$HERE/prebuilt/"*.dtb "$WORK/dtbs/"
fi
echo "  готово вариантов DTB: $(ls "$WORK/dtbs"/*.dtb | wc -l)"

echo "=== [2/6] сборка rootfs Debian 12 (Bookworm) armhf (debootstrap + chroot apt) ==="
if [ "$REUSE_ROOTFS" = "1" ] && [ -d "$WORK/rootfs/usr" ]; then
    echo "  (REUSE_ROOTFS=1: используется готовая $WORK/rootfs)"
else
    BUILD="$BUILD" DEVMEM2_BIN="$DEVMEM2_BIN" "$HERE/scripts/prepare-rootfs.sh" "$WORK/rootfs"
fi

echo "=== [3/6] проверка разделяемых библиотек ELF (armhf multiarch) ==="
as_root python3 "$HERE/scripts/check-libs.py" "$WORK/rootfs"

echo "=== [4/6] проверка подписи regulatory.db (ключ sforshee для ядра 6.6) ==="
if command -v openssl >/dev/null 2>&1 && [ -f "$HERE/certs/sforshee.x509.pem" ]; then
    openssl smime -verify -inform DER \
        -in "$WORK/rootfs/lib/firmware/regulatory.db.p7s" \
        -content "$WORK/rootfs/lib/firmware/regulatory.db" \
        -CAfile "$HERE/certs/sforshee.x509.pem" -purpose any -out /dev/null >/dev/null 2>&1
    echo "  regulatory.db: подпись sforshee ВЕРНА"
fi

echo "=== [5/6] сборка загрузочного образа microSD ($WORK/$IMG_NAME) ==="
BUILD="$BUILD" DTB_DIR="$WORK/dtbs" ROOTFS="$WORK/rootfs" \
    "$HERE/scripts/make-sdimage.sh" "$WORK/$IMG_NAME"

if [ "$KEEP_ROOTFS" != "1" ]; then
    echo "=== очистка распакованной rootfs из /tmp ($WORK/rootfs) ==="
    as_root rm -rf "$WORK/rootfs" "$WORK/dtbs" "$WORK/devmem2"
fi

echo "=== [6/6] сжатие образа (xz) и расчёт SHA256 -> $COPYTO ==="
SHA_IMG=$(sha256sum "$WORK/$IMG_NAME" | cut -d' ' -f1)
xz -6 -T2 --memlimit-compress=250MiB -c "$WORK/$IMG_NAME" > "$COPYTO/${IMG_NAME}.xz"
SHA_XZ=$(sha256sum "$COPYTO/${IMG_NAME}.xz" | cut -d' ' -f1)

cat > "$COPYTO/${IMG_NAME%.img}.sha256" <<EOF
# Informer 701 (N708H6, Allwinner A10) - Debian 12 (Bookworm) armhf SD image ($BUILD)
# Прошивка на карту microSD:
#   xz -dc ${IMG_NAME}.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
$SHA_IMG  $IMG_NAME  (распакованный, 512 MiB)
$SHA_XZ  ${IMG_NAME}.xz
EOF

if [ "$KEEP_RAW_IMG" = "1" ]; then
    mv -f "$WORK/$IMG_NAME" "$COPYTO/$IMG_NAME"
else
    rm -f "$WORK/$IMG_NAME"
    [ "$KEEP_ROOTFS" != "1" ] && rmdir "$WORK" 2>/dev/null || true
fi

if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    chown -R "${SUDO_UID}:${SUDO_GID}" "$COPYTO" 2>/dev/null || true
fi

echo
echo "=== СБОРКА ЗАВЕРШЕНА ==="
ls -lh "$COPYTO/${IMG_NAME}.xz" "$COPYTO/${IMG_NAME%.img}.sha256"
cat "$COPYTO/${IMG_NAME%.img}.sha256"

#!/bin/bash
# build-all.sh - полная сборка с нуля (U-Boot 2024.10 + Linux 6.6 + модули + Debian 12 Bookworm armhf)
#
# ВНИМАНИЕ: компиляция U-Boot и ядра Linux с нуля занимает 25..60 минут.
# Для быстрой сборки образа Debian 12 из уже готовых U-Boot и ядра в prebuilt/
# используйте ./scripts/build-image.sh (~3-5 минут).
#
# Все сборочные артефакты размещаются во временной ФС (/tmp), не загрязняя репозиторий.
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
WORK="${WORK:-/tmp/informer701-srcbuild}"
OUT="${COPYTO:-${OUT:-/tmp/out-debian}}"
IMG_NAME="${IMG_NAME:-informer701-${BUILD}.img}"
JOBS="${JOBS:-$(nproc)}"

UBOOT_VER=2024.10
KVER=6.6
RTL88X2BU_REPO="${RTL88X2BU_REPO:-https://github.com/morrownr/88x2bu-20210702.git}"

export ARCH=arm
export CROSS_COMPILE=arm-linux-gnueabihf-

for t in "${CROSS_COMPILE}gcc" flex bison bc dtc mkimage swig python3 \
         mkfs.vfat mcopy mkfs.ext4 cpio xz debootstrap curl git; do
    command -v "$t" >/dev/null || { echo "нужна утилита хоста: $t (см. BUILDING.md)" >&2; exit 1; }
done

mkdir -p "$WORK/src" "$WORK/dtbs" "$WORK/stage" "$OUT"

# --- 0. devmem2 (armhf glibc) ------------------------------------------------
echo "=== [0/5] кросс-компиляция devmem2 ==="
"${CROSS_COMPILE}gcc" -O2 -Wall -Wextra -o "$WORK/stage/devmem2" "$HERE/src/devmem2.c"

# --- 1. U-Boot 2024.10 -------------------------------------------------------
echo "=== [1/5] U-Boot $UBOOT_VER ==="
cd "$WORK/src"
[ -f "u-boot-${UBOOT_VER}.tar.bz2" ] || \
    curl -fL -O "https://ftp.denx.de/pub/u-boot/u-boot-${UBOOT_VER}.tar.bz2"
[ -d "u-boot-${UBOOT_VER}" ] || tar -xjf "u-boot-${UBOOT_VER}.tar.bz2"
cd "u-boot-${UBOOT_VER}"
cp "$HERE/dts/sun4i-a10-informer-701.dts" arch/arm/dts/sun4i-a10-informer-701.dts
cp "$HERE/u-boot/informer701_defconfig"   configs/informer701_defconfig
make informer701_defconfig
make -j"$JOBS"
cp u-boot-sunxi-with-spl.bin "$WORK/stage/u-boot-sunxi-with-spl.bin"

# --- 2. Ядро Linux 6.6 + модули (включая zram/zsmalloc/lz4/lzo) --------------
echo "=== [2/5] Linux $KVER ==="
cd "$WORK/src"
[ -f "linux-${KVER}.tar.xz" ] || \
    curl -fL -O "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KVER}.tar.xz"
[ -d "linux-${KVER}" ] || tar -xJf "linux-${KVER}.tar.xz"
cd "linux-${KVER}"
cp "$HERE/dts/sun4i-a10-informer-701.dts" arch/arm/boot/dts/allwinner/
grep -q 'sun4i-a10-informer-701.dtb' arch/arm/boot/dts/allwinner/Makefile || \
    sed -i '/sun4i-a10-olinuxino-lime.dtb/a\\tsun4i-a10-informer-701.dtb \\' \
        arch/arm/boot/dts/allwinner/Makefile

mkdir -p certs
touch .scmversion
cp "$HERE/certs/sforshee.x509.pem" certs/sforshee.x509.pem
cp "$HERE/kernel/kernel.config-b021" .config
make olddefconfig
make -j"$JOBS" zImage modules dtbs

cp arch/arm/boot/zImage "$WORK/stage/zImage"
cp arch/arm/boot/dts/allwinner/sun4i-a10-informer-701.dtb "$WORK/dtbs/sun4i-a10-informer-701.dtb"

MOD_STAGE="$WORK/modstage"
rm -rf "$MOD_STAGE"
make INSTALL_MOD_PATH="$MOD_STAGE" INSTALL_MOD_STRIP=1 modules_install
KREL=$(ls "$MOD_STAGE/lib/modules" | head -1)

# --- 2b. Внешний двухдиапазонный модуль Realtek RTL8812BU/8822BU (88x2bu.ko) --
echo "=== [2b/5] драйвер Realtek RTL8812BU (88x2bu.ko для $KREL) ==="
KSRC_DIR="$WORK/src/linux-${KVER}"
cd "$WORK/src"
[ -d 88x2bu-20210702 ] || git clone --depth 1 "$RTL88X2BU_REPO" 88x2bu-20210702
make -j"$JOBS" \
    ARCH=arm \
    CROSS_COMPILE="$CROSS_COMPILE" \
    KVER="$KREL" \
    KSRC="$KSRC_DIR" \
    -C 88x2bu-20210702 \
    modules
EXT_STAGE="$WORK/extmodstage"
rm -rf "$EXT_STAGE"
make -C "$KSRC_DIR" \
    M="$WORK/src/88x2bu-20210702" \
    ARCH=arm \
    CROSS_COMPILE="$CROSS_COMPILE" \
    INSTALL_MOD_PATH="$EXT_STAGE" \
    INSTALL_MOD_STRIP=1 \
    modules_install
BUILT_88X2BU=$(find "$EXT_STAGE" -name '88x2bu.ko*' | head -1)
[ -n "$BUILT_88X2BU" ] || { echo "ОШИБКА: модуль 88x2bu не собран!" >&2; exit 1; }
mkdir -p "$MOD_STAGE/lib/modules/$KREL/kernel/drivers/net/wireless/realtek/88x2bu"
install -m 0644 "$BUILT_88X2BU" \
    "$MOD_STAGE/lib/modules/$KREL/kernel/drivers/net/wireless/realtek/88x2bu/$(basename "$BUILT_88X2BU")"
rm -rf "$EXT_STAGE"

rm -f "$MOD_STAGE/lib/modules/$KREL/build" "$MOD_STAGE/lib/modules/$KREL/source"
if command -v depmod >/dev/null 2>&1; then
    depmod -a -b "$MOD_STAGE" "$KREL"
elif [ -x /sbin/depmod ]; then
    /sbin/depmod -a -b "$MOD_STAGE" "$KREL"
fi
tar -C "$MOD_STAGE" -cJf "$WORK/stage/modules-${KREL}.tar.xz" lib/modules
rm -rf "$MOD_STAGE"

# --- 3. Варианты DTB ---------------------------------------------------------
echo "=== [3/5] варианты DTB ==="
dtc -I dtb -O dts -q -o "$WORK/dtbs/src.dts" "$WORK/dtbs/sun4i-a10-informer-701.dtb"
python3 "$HERE/scripts/mkdtb-variants.py" "$WORK/dtbs/src.dts" "$WORK/dtbs"
for dts_f in "$WORK/dtbs"/*.dts; do
    [ "$(basename "$dts_f")" = "src.dts" ] && continue
    [ "$(basename "$dts_f")" = "base.dts" ] && continue
    dtc -I dts -O dtb -q -o "${dts_f%.dts}.dtb" "$dts_f"
done
for d in "$HERE/prebuilt"/*.dtb; do
    [ -f "$WORK/dtbs/$(basename "$d")" ] || cp "$d" "$WORK/dtbs/"
done

# --- 4. Debian 12 (Bookworm) armhf rootfs ------------------------------------
echo "=== [4/5] Debian 12 (Bookworm) armhf rootfs ==="
cd "$HERE"
BUILD="$BUILD" \
DEVMEM2_BIN="$WORK/stage/devmem2" \
MODS="$WORK/stage/modules-${KREL}.tar.xz" \
    "$HERE/scripts/prepare-rootfs.sh" "$WORK/rootfs"
as_root python3 "$HERE/scripts/check-libs.py" "$WORK/rootfs"

# --- 5. Итоговый образ microSD -----------------------------------------------
echo "=== [5/5] сборка и сжатие образа microSD ==="
BUILD="$BUILD" \
UBOOT="$WORK/stage/u-boot-sunxi-with-spl.bin" \
ZIMAGE="$WORK/stage/zImage" \
DTB_DIR="$WORK/dtbs" \
ROOTFS="$WORK/rootfs" \
    "$HERE/scripts/make-sdimage.sh" "$WORK/$IMG_NAME"

as_root rm -rf "$WORK/rootfs"
SHA_IMG=$(sha256sum "$WORK/$IMG_NAME" | cut -d' ' -f1)
xz -6 -T2 --memlimit-compress=250MiB -c "$WORK/$IMG_NAME" > "$OUT/${IMG_NAME}.xz"
SHA_XZ=$(sha256sum "$OUT/${IMG_NAME}.xz" | cut -d' ' -f1)

cat > "$OUT/${IMG_NAME%.img}.sha256" <<EOF
# Informer 701 (N708H6, Allwinner A10) - Debian 12 (Bookworm) armhf SD image ($BUILD)
# Прошивка на карту microSD:
#   xz -dc ${IMG_NAME}.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
$SHA_IMG  $IMG_NAME  (распакованный, 512 MiB)
$SHA_XZ  ${IMG_NAME}.xz
EOF

rm -f "$WORK/$IMG_NAME"
if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
    chown -R "${SUDO_UID}:${SUDO_GID}" "$OUT" 2>/dev/null || true
fi

echo
echo "Полная сборка завершена:"
ls -lh "$OUT/${IMG_NAME}.xz" "$OUT/${IMG_NAME%.img}.sha256"

#!/bin/bash
# One-shot reproducible build of the Informer 701 (N708H6, Allwinner A10)
# SD-card image: mainline U-Boot + mainline Linux + Alpine minirootfs.
#
#   usage: ./build-all.sh [outdir]
#
# Requirements (Debian/Ubuntu):
#   apt install build-essential git bc bison flex libssl-dev libgnutls28-dev \
#               uuid-dev python3-setuptools python3-dev device-tree-compiler \
#               u-boot-tools gcc-arm-linux-gnueabihf mtools e2fsprogs \
#               dosfstools parted wget
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$HERE/out}"
BUILD="$OUT/build"
BUILDID=${BUILDID:-b007}
UBOOT_TAG=v2024.10
LINUX_TAG=v6.6
CROSS=arm-linux-gnueabihf-
JOBS=$(nproc)

mkdir -p "$BUILD" "$OUT"

# ------------------------------------------------------------------- U-Boot
if [ ! -d "$BUILD/u-boot" ]; then
    git clone --depth 1 --branch $UBOOT_TAG https://source.denx.de/u-boot/u-boot.git "$BUILD/u-boot"
fi
cd "$BUILD/u-boot"
cp "$HERE/u-boot/informer701_defconfig" configs/informer701_defconfig
cp "$HERE/dts/u-boot-sun4i-a10-informer-701.dts" arch/arm/dts/sun4i-a10-informer-701.dts
grep -q sun4i-a10-informer-701 arch/arm/dts/Makefile || python3 - <<'EOF'
p='arch/arm/dts/Makefile'; s=open(p).read()
old="\tsun4i-a10-olinuxino-lime.dtb \\\n"
open(p,'w').write(s.replace(old, old+"\tsun4i-a10-informer-701.dtb \\\n",1))
EOF
make CROSS_COMPILE=$CROSS informer701_defconfig
make CROSS_COMPILE=$CROSS -j$JOBS
cp u-boot-sunxi-with-spl.bin "$OUT/"

# -------------------------------------------------------------------- Linux
if [ ! -d "$BUILD/linux" ]; then
    git clone --depth 1 --branch $LINUX_TAG https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$BUILD/linux"
fi
cd "$BUILD/linux"
cp "$HERE/dts/sun4i-a10-informer-701.dts" arch/arm/boot/dts/allwinner/
grep -q sun4i-a10-informer-701 arch/arm/boot/dts/allwinner/Makefile || python3 - <<'EOF'
p='arch/arm/boot/dts/allwinner/Makefile'; s=open(p).read()
old="\tsun4i-a10-olinuxino-lime.dtb \\\n"
open(p,'w').write(s.replace(old, old+"\tsun4i-a10-informer-701.dtb \\\n",1))
EOF
make ARCH=arm CROSS_COMPILE=$CROSS sunxi_defconfig
# trim the generic sunxi defconfig down to a headless console system
for o in DRM MEDIA_SUPPORT SOUND SND CAN STAGING IIO ATA AHCI_SUNXI USB_GADGET \
         USB_MUSB_HDRC NFS_FS NFS_V3_ACL NFS_V4 ROOT_NFS DEBUG_FS RC_CORE \
         SERIO_SUN4I_PS2 TOUCHSCREEN_SUN4I INPUT_MISC MODULES; do
    ./scripts/config --disable $o
done
./scripts/config --enable SERIAL_8250_CONSOLE
make ARCH=arm CROSS_COMPILE=$CROSS olddefconfig
make ARCH=arm CROSS_COMPILE=$CROSS -j$JOBS zImage dtbs
cp arch/arm/boot/zImage "$OUT/"
cp arch/arm/boot/dts/allwinner/sun4i-a10-informer-701.dtb "$OUT/"

# ------------------------------------------------------------------ rootfs
if [ ! -f "$OUT/alpine-minirootfs.tar.gz" ]; then
    wget -O "$OUT/alpine-minirootfs.tar.gz" \
        https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/armv7/alpine-minirootfs-3.20.9-armv7.tar.gz
fi
QEMU_ARM=$(command -v qemu-arm-static || true) \
    BUILD="$BUILDID" \
    "$HERE/scripts/prepare-rootfs.sh" "$OUT/alpine-minirootfs.tar.gz" "$OUT/rootfs" "${ROOT_PASS:-informer701}"

# ------------------------------------------------- DTB variants + initramfs
# base.dts = декомпилированное дерево платы; из него генерируются все варианты
dtc -q -I dtb -O dts -o "$OUT/base.dts" "$OUT/sun4i-a10-informer-701.dtb"
python3 "$HERE/scripts/mkdtb-variants.py" "$OUT/base.dts" "$OUT"
for v in base pinned nocpufreq safe noaxp nommc wdt; do
    dtc -q -I dts -O dtb -o "$OUT/$v.dtb" "$OUT/$v.dts"
done
cp -f "$OUT/base.dtb" "$OUT/informer.dtb"
cp -f "$OUT/sun4i-a10-informer-701.dtb" "$OUT/informer.dtb"

WORK="${WORK:-/tmp/informer701-work}"
mkdir -p "$WORK"
cp -f "$OUT/alpine-minirootfs.tar.gz" "$WORK/alpine.tar.gz" 2>/dev/null || true
BUILD="$BUILDID" bash "$HERE/scripts/build-initramfs.sh"
cp -f /tmp/w/rescue2.cpio.gz "$OUT/" 2>/dev/null || cp -f "$WORK/rescue2.cpio.gz" "$OUT/"

# ------------------------------------------------------------------- image
ART="$OUT/art"
rm -rf "$ART"; mkdir -p "$ART"
cp "$OUT/u-boot-sunxi-with-spl.bin" "$OUT/zImage" "$ART/"
cp "$OUT/informer.dtb" "$OUT/pinned.dtb" "$OUT/nocpufreq.dtb" "$OUT/safe.dtb" \
   "$OUT/noaxp.dtb" "$OUT/nommc.dtb" "$OUT/wdt.dtb" "$OUT/rescue2.cpio.gz" "$ART/"
cp -a "$OUT/rootfs" "$ART/rootfs"

BUILD="$BUILDID" "$HERE/scripts/make-sdimage.sh" "$ART" "$OUT" "${COPY_TO:-}"

echo
echo "Готово: informer701-$BUILDID.img.xz"
echo "Прошивка:  xzcat informer701-$BUILDID.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync"
echo "Логин:     root / ${ROOT_PASS:-informer701}"

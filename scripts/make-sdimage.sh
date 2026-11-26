#!/bin/bash
# make-sdimage.sh <выходной.img>
#
# Собирает полный загрузочный образ microSD для Informer 701 (N708H6, Allwinner A10,
# Debian 12 Bookworm armhf) строго во временной ФС (/tmp или /dev/shm) с разреженными
# (sparse) файлами:
#
#   [0 .. 8 КиБ)        MBR
#   [8 КиБ .. ~520 КиБ) u-boot-sunxi-with-spl.bin (SPL + U-Boot 2024.10)
#   [1 МиБ .. 65 МиБ)   раздел 1, FAT16 "BOOT": zImage, все 12 DTB (lowopp.dtb и др.),
#                       rescue2.cpio.gz, extlinux/extlinux.conf (16 пунктов меню),
#                       deb/README.txt (офлайн-установка .deb через pkg local), logs/
#   [65 МиБ .. 512 МиБ) раздел 2, ext4 "rootfs": Debian 12 (Bookworm) armhf + systemd
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${1:?укажите путь к выходному .img (в /tmp или /dev/shm)}"

case "$IMG" in
    "$HERE"|"$HERE"/*)
        echo "ОШИБКА: образ ($IMG) не должен создаваться внутри репозитория ($HERE)!" >&2
        echo "Используйте /tmp/... или /dev/shm/..." >&2
        exit 1
        ;;
esac

BUILD="${BUILD:-debian12}"
BOOT_DEFAULT="${BOOT_DEFAULT:-lowopp}"
UBOOT="${UBOOT:-$HERE/prebuilt/u-boot-sunxi-with-spl.bin}"
ZIMAGE="${ZIMAGE:-$HERE/prebuilt/zImage}"
DTB_DIR="${DTB_DIR:-$HERE/prebuilt}"
RESCUE="${RESCUE:-$HERE/prebuilt/rescue2.cpio.gz}"
ROOTFS="${ROOTFS:?задайте ROOTFS=<каталог подготовленной rootfs Debian 12>}"

TOTAL_MIB="${TOTAL_MIB:-512}"
BOOT_START_MIB=1
BOOT_SIZE_MIB=64
ROOT_START_MIB=$((BOOT_START_MIB + BOOT_SIZE_MIB))
ROOT_SIZE_MIB=$((TOTAL_MIB - ROOT_START_MIB))

for f in "$UBOOT" "$ZIMAGE" "$RESCUE" "$DTB_DIR/lowopp.dtb" "$DTB_DIR/informer.dtb"; do
    [ -f "$f" ] || { echo "нет обязательного файла: $f" >&2; exit 1; }
done
[ -d "$ROOTFS/bin" ] || { echo "ROOTFS ($ROOTFS) не похож на корень Linux" >&2; exit 1; }

PATH="$PATH:/sbin:/usr/sbin"
for t in mkfs.vfat mmd mcopy mdir mkfs.ext4 python3 dd truncate; do
    command -v "$t" >/dev/null || { echo "нужна утилита хоста: $t" >&2; exit 1; }
done

mkdir -p "$(dirname "$IMG")"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sdimg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- 1. Конфигурация U-Boot distro-boot (/extlinux/extlinux.conf) ------------
mkdir -p "$WORK/boot/extlinux" "$WORK/boot/deb"

cat > "$WORK/boot/extlinux/extlinux.conf" <<EOF
# ============================================================================
#  Informer 701 (N708H6, Allwinner A10) - U-Boot distro boot menu ($BUILD)
#  ОС: Debian 12 (Bookworm) armhf / glibc / bash / systemd / apt
#
#  Интерактивное меню намеренно выключено (нет строки "prompt"): U-Boot сразу
#  грузит пункт default ($BOOT_DEFAULT). Переключение из Linux:
#    bootnext 15       одноразовая загрузка пункта 15 (default вернётся сам!)
#    bootnext 15 -p    сделать пункт 15 постоянным
#    bootnext          список всех пунктов меню
#    bootnext default  вернуть заводской пункт ($BOOT_DEFAULT)
#  Из консоли U-Boot (=>):  setenv pxe_label_override safe; boot
# ============================================================================
default $BOOT_DEFAULT
timeout 150

# --- 1. safe (аварийный: без cpufreq и без PMIC) ----------------------------
label safe
    kernel /zImage
    devicetree /safe.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=10 loglevel=4 clk_ignore_unused initcall_blacklist=cpufreq_dt_platdev_init net.ifnames=0 usbnet=0 ssh=0

# --- 2. pinned (1008 МГц @ 1.4 В фиксированно) ------------------------------
label pinned
    kernel /zImage
    devicetree /pinned.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=10 loglevel=7 clk_ignore_unused net.ifnames=0 usbnet=1 ssh=1

# --- 3. nofreq (без таблицы OPP, но с PMIC AXP209) --------------------------
label nofreq
    kernel /zImage
    devicetree /nocpufreq.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=10 loglevel=7 clk_ignore_unused net.ifnames=0 usbnet=1 ssh=1

# --- 4. base (полная лестница OPP с переключением напряжений) ---------------
label base
    kernel /zImage
    devicetree /informer.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=10 loglevel=8 clk_ignore_unused net.ifnames=0 usbnet=1 ssh=1

# --- 5. base-perf (governor=performance) ------------------------------------
label base-perf
    kernel /zImage
    devicetree /informer.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=10 loglevel=8 clk_ignore_unused cpufreq.default_governor=performance net.ifnames=0 usbnet=1 ssh=1

# --- 6. flatvolt (1008 и 912 МГц @ 1.4 В) -----------------------------------
label flatvolt
    kernel /zImage
    devicetree /flatvolt.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=10 loglevel=8 clk_ignore_unused cpufreq.default_governor=performance net.ifnames=0 usbnet=1 ssh=1

# --- 7. base-initcall (отладка initcall_debug) ------------------------------
label base-initcall
    kernel /zImage
    devicetree /informer.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=10 loglevel=8 clk_ignore_unused initcall_debug net.ifnames=0 usbnet=0 ssh=0

# --- 8. rescue (диагностический RAM-диск без монтирования SD ext4) ----------
label rescue
    kernel /zImage
    initrd /rescue2.cpio.gz
    devicetree /nocpufreq.dtb
    append console=ttyS0,115200n8 loglevel=7 clk_ignore_unused

# --- 9. noaxp (без драйвера PMIC AXP209, с таблицей OPP) --------------------
label noaxp
    kernel /zImage
    devicetree /noaxp.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=10 loglevel=7 clk_ignore_unused net.ifnames=0 usbnet=1 ssh=1

# --- 10. wdt (контрольный пункт watchdog) -----------------------------------
label wdt
    kernel /zImage
    devicetree /wdt.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=10 loglevel=7 clk_ignore_unused net.ifnames=0 usbnet=1 ssh=1

# --- 11. safe-v (safe + loglevel=8, panic=0) --------------------------------
label safe-v
    kernel /zImage
    devicetree /safe.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=0 loglevel=8 clk_ignore_unused initcall_blacklist=cpufreq_dt_platdev_init net.ifnames=0 usbnet=0 ssh=0

# --- 12. lowopp (ПО УМОЛЧАНИЮ: 1008/912/864/624 МГц @ 1.4 В + USB-сеть/SSH) -
label lowopp
    kernel /zImage
    devicetree /lowopp.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=10 loglevel=4 clk_ignore_unused net.ifnames=0 usbnet=1 ssh=1

# --- 13. lowopp-v (lowopp + подробный лог ядра loglevel=8) ------------------
label lowopp-v
    kernel /zImage
    devicetree /lowopp.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=0 loglevel=8 clk_ignore_unused net.ifnames=0 usbnet=1 ssh=1

# --- 14. usbnet (отладка USB OTG / musb / configfs-gadget) ------------------
label usbnet
    kernel /zImage
    devicetree /lowopp.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=10 loglevel=8 clk_ignore_unused net.ifnames=0 usbnet=1 ssh=1

# --- 15. nousb (все контроллеры USB выключены в DTB) ------------------------
label nousb
    kernel /zImage
    devicetree /nousb.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=10 loglevel=8 clk_ignore_unused net.ifnames=0 nousb=1 usbnet=0 ssh=0

# --- 16. hdmi (включён вывод консоли на HDMI через sun4i DRM) ---------------
label hdmi
    kernel /zImage
    devicetree /hdmi.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rootfstype=ext4 rw rootwait panic=10 loglevel=8 clk_ignore_unused net.ifnames=0 usbnet=1 ssh=1
EOF

cat > "$WORK/boot/deb/README.txt" <<'EOF'
Каталог deb - офлайновая установка пакетов Debian 12 (Bookworm) armhf на плате.

1. На ПК скачайте нужные пакеты *.deb для Debian 12 (bookworm), архитектура armhf:
     https://packages.debian.org/bookworm/
2. Скопируйте файлы *.deb в ЭТОТ каталог (раздел BOOT виден на любом ПК как FAT-диск).
3. На плате выполните:
     pkg local           (или явно: pkg local /boot/deb)

При наличии интернета через Wi-Fi (`wifi connect <SSID> <пароль>`) или через
USB-кабель от ПК (`usbnet nat`) пакеты ставятся напрямую из репозитория Debian:
     pkg time && pkg update && pkg add <имя_пакета>
EOF

{
    echo "build $BUILD (Debian 12 Bookworm armhf)"
    echo "u-boot : $(sha256sum "$UBOOT" | cut -c1-16)  $(stat -c%s "$UBOOT") bytes"
    echo "zImage : $(sha256sum "$ZIMAGE" | cut -c1-16)  $(stat -c%s "$ZIMAGE") bytes"
    for d in informer pinned flatvolt lowopp nocpufreq safe noaxp nommc wdt hdmi nousb sun4i-a10-informer-701; do
        [ -f "$DTB_DIR/$d.dtb" ] && echo "dtb    : $(sha256sum "$DTB_DIR/$d.dtb" | cut -c1-16)  $d.dtb"
    done
} > "$WORK/boot/BUILD-$BUILD.txt"

# --- 2. Разреженный образ, MBR и U-Boot @ +8 КиБ -----------------------------
rm -f "$IMG"
truncate -s "${TOTAL_MIB}M" "$IMG"
if command -v sfdisk >/dev/null 2>&1; then
    sfdisk --no-reread --no-tell-kernel "$IMG" >/dev/null <<EOF
label: dos
unit: sectors
start=$((BOOT_START_MIB * 2048)), size=$((BOOT_SIZE_MIB * 2048)), type=c, bootable
start=$((ROOT_START_MIB * 2048)), size=$((ROOT_SIZE_MIB * 2048)), type=83
EOF
else
    python3 - "$IMG" "$((BOOT_START_MIB * 2048))" "$((BOOT_SIZE_MIB * 2048))" \
              "$((ROOT_START_MIB * 2048))" "$((ROOT_SIZE_MIB * 2048))" <<'PYEOF'
import struct, sys
img, p1s, p1n, p2s, p2n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
def chs(sector):
    c, h, s = sector // (63 * 255), (sector // 63) % 255, (sector % 63) + 1
    if c > 1023:
        c, h, s = 1023, 254, 63
    return bytes([h, ((c >> 8) << 6) | s, c & 0xff])
mbr = bytearray(512)
mbr[440:444] = b'\x70\x01\x12\xde'
mbr[446] = 0x80
mbr[447:450] = chs(p1s);          mbr[450] = 0x0C
mbr[451:454] = chs(p1s + p1n - 1); mbr[454:458] = struct.pack('<I', p1s)
mbr[458:462] = struct.pack('<I', p1n)
mbr[462] = 0x00
mbr[463:466] = chs(p2s);          mbr[466] = 0x83
mbr[467:470] = chs(p2s + p2n - 1); mbr[470:474] = struct.pack('<I', p2s)
mbr[474:478] = struct.pack('<I', p2n)
mbr[510:512] = b'\x55\xaa'
with open(img, 'r+b') as f:
    f.write(mbr)
PYEOF
fi

dd if="$UBOOT" of="$IMG" bs=1024 seek=8 conv=notrunc status=none

# --- 3. Раздел 1: FAT16 BOOT (64 МиБ @ +1 МиБ) -------------------------------
BOOT="$WORK/boot.vfat"
truncate -s "${BOOT_SIZE_MIB}M" "$BOOT"
mkfs.vfat -F 16 -n BOOT "$BOOT" >/dev/null
MTOOLS_SKIP_CHECK=1 mmd -i "$BOOT" ::/extlinux ::/deb ::/logs
MTOOLS_SKIP_CHECK=1 mcopy -o -i "$BOOT" "$ZIMAGE"  ::/zImage
MTOOLS_SKIP_CHECK=1 mcopy -o -i "$BOOT" "$RESCUE"  ::/rescue2.cpio.gz
MTOOLS_SKIP_CHECK=1 mcopy -o -i "$BOOT" "$UBOOT"   ::/u-boot-sunxi-with-spl.bin
MTOOLS_SKIP_CHECK=1 mcopy -o -i "$BOOT" "$WORK/boot/BUILD-$BUILD.txt" ::/
for d in informer pinned flatvolt lowopp nocpufreq safe noaxp nommc wdt hdmi nousb sun4i-a10-informer-701; do
    [ -f "$DTB_DIR/$d.dtb" ] && MTOOLS_SKIP_CHECK=1 mcopy -o -i "$BOOT" "$DTB_DIR/$d.dtb" "::/$d.dtb"
done
[ -f "$DTB_DIR/sun4i-a10-informer-701.dtb" ] || \
    MTOOLS_SKIP_CHECK=1 mcopy -o -i "$BOOT" "$DTB_DIR/informer.dtb" ::/sun4i-a10-informer-701.dtb
MTOOLS_SKIP_CHECK=1 mcopy -o -i "$BOOT" "$WORK/boot/extlinux/extlinux.conf" ::/extlinux/extlinux.conf
MTOOLS_SKIP_CHECK=1 mcopy -o -i "$BOOT" "$WORK/boot/deb/README.txt"         ::/deb/README.txt

MTOOLS_SKIP_CHECK=1 mdir -i "$BOOT" ::/extlinux | grep -q extlinux.conf || {
    echo "ОШИБКА: /extlinux/extlinux.conf не записан на раздел BOOT" >&2
    exit 1
}

dd if="$BOOT" of="$IMG" bs=1M seek="$BOOT_START_MIB" conv=notrunc,sparse status=none
rm -f "$BOOT"

# --- 4. Раздел 2: ext4 rootfs (447 МиБ @ +65 МиБ) ----------------------------
EXT4="$WORK/rootfs.ext4"
truncate -s "${ROOT_SIZE_MIB}M" "$EXT4"
if [ "$(id -u)" -eq 0 ]; then
    mkfs.ext4 -q -F -b 4096 -L rootfs \
        -U 8f1a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8 \
        -O ^metadata_csum_seed,^orphan_file \
        -d "$ROOTFS" "$EXT4"
else
    sudo mkfs.ext4 -q -F -b 4096 -L rootfs \
        -U 8f1a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8 \
        -O ^metadata_csum_seed,^orphan_file \
        -d "$ROOTFS" "$EXT4"
    sudo chown "$(id -u):$(id -g)" "$EXT4"
fi
dd if="$EXT4" of="$IMG" bs=1M seek="$ROOT_START_MIB" conv=notrunc,sparse status=none
rm -f "$EXT4"

echo "[sdimage] готов: $IMG (виртуальный размер ${TOTAL_MIB} МиБ, занято блоками $(du -sh "$IMG" | cut -f1))"
echo "  U-Boot : $(basename "$UBOOT") @ +8 КиБ"
echo "  p1 BOOT: ${BOOT_SIZE_MIB} МиБ FAT16 @ +${BOOT_START_MIB} МиБ (extlinux.conf + zImage + 12 DTB + rescue2.cpio.gz)"
echo "  p2 root: ${ROOT_SIZE_MIB} МиБ ext4  @ +${ROOT_START_MIB} МиБ (Debian 12 Bookworm armhf)"

#!/bin/bash
# Сборка ядра v6.6 для Informer 701 с поддержкой USB (gadget + host), HDMI и тачскрина.
# База - тот же рецепт, что в informer701-linux/scripts/build-all.sh (sunxi_defconfig
# + набор отключений), но USB_GADGET/USB_MUSB_HDRC/DRM больше НЕ отключаются.
set -x
HERE="$(cd "$(dirname "$0")/.." && pwd)"          # корень набора
WS="$(cd "$HERE/.." && pwd)"                            # каталог над набором
KIT_DTS="$HERE/dts/sun4i-a10-informer-701.dts"
[ -f "$KIT_DTS" ] || KIT_DTS="$WS/informer701-linux/dts/sun4i-a10-informer-701.dts"
K=/tmp/kb/src/linux-6.6
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
cd "$K" || exit 1

# scripts/config в v6.6 принимает ОДИН символ за вызов - иначе печатает usage
# и ничего не меняет (на этом попался первый запуск).
en()  { for x in "$@"; do ./scripts/config --enable  "$x" || echo "!! enable $x"; done; }
dis() { for x in "$@"; do ./scripts/config --disable "$x" || echo "!! disable $x"; done; }

cp "$KIT_DTS" arch/arm/boot/dts/allwinner/
python3 - <<'EOF'
p='arch/arm/boot/dts/allwinner/Makefile'; s=open(p).read()
if 'sun4i-a10-informer-701' not in s:
    old="\tsun4i-a10-olinuxino-lime.dtb \\\n"
    assert old in s, "не найден якорь в Makefile"
    open(p,'w').write(s.replace(old, old+"\tsun4i-a10-informer-701.dtb \\\n",1))
    print("Makefile: добавлен sun4i-a10-informer-701.dtb")
EOF

make sunxi_defconfig || exit 1

# --- то же, что отключал build-all.sh, КРОМЕ USB_GADGET / USB_MUSB_HDRC / DRM ---
dis MEDIA_SUPPORT SOUND SND CAN STAGING IIO ATA AHCI_SUNXI \
    NFS_FS NFS_V3_ACL NFS_V4 ROOT_NFS DEBUG_FS RC_CORE \
    SERIO_SUN4I_PS2 TOUCHSCREEN_SUN4I INPUT_MISC MODULES
en SERIAL_8250_CONSOLE

# --- USB: контроллеры и PHY ---
en USB USB_ANNOUNCE_NEW_DEVICES EXTCON \
   USB_EHCI_HCD USB_EHCI_HCD_PLATFORM USB_OHCI_HCD USB_OHCI_HCD_PLATFORM \
   NOP_USB_XCEIV PHY_SUN4I_USB \
   USB_MUSB_HDRC USB_MUSB_SUNXI USB_MUSB_DUAL_ROLE
dis USB_MUSB_HOST USB_MUSB_GADGET

# --- USB: gadget (configfs, без модулей - всё built-in) ---
en USB_GADGET USB_LIBCOMPOSITE USB_CONFIGFS \
   USB_CONFIGFS_RNDIS USB_CONFIGFS_ECM USB_CONFIGFS_EEM USB_CONFIGFS_NCM \
   USB_CONFIGFS_MASS_STORAGE USB_CONFIGFS_ACM USB_CONFIGFS_SERIAL \
   USB_CONFIGFS_F_FS USB_F_RNDIS USB_F_ECM USB_F_NCM USB_F_EEM \
   USB_F_MASS_STORAGE USB_F_ACM USB_F_SERIAL USB_U_SERIAL USB_U_ETHER
./scripts/config --set-val USB_GADGET_VBUS_DRAW 500

# --- USB: host-классы (флешки, Ethernet-адаптеры, модемы, UART-мосты) ---
en USB_STORAGE USB_UAS USB_ACM \
   USBNET USB_NET_CDCETHER USB_NET_RNDIS_HOST USB_NET_CDC_NCM USB_NET_CDC_EEM \
   USB_NET_AX8817X USB_NET_AX88179_178A USB_NET_SMSC95XX USB_NET_DM9601 \
   USB_NET_SR9700 USB_NET_SR9800 USB_NET_CH9200 USB_NET_MCS7830 \
   USB_RTL8150 USB_RTL8152 USB_NET_CDC_SUBSET \
   USB_SERIAL USB_SERIAL_GENERIC USB_SERIAL_FTDI_SIO USB_SERIAL_PL2303 \
   USB_SERIAL_CH341 USB_SERIAL_CP210X \
   USB_HID HID_GENERIC

# --- DRM/HDMI (в DTB по умолчанию выключено, включается отдельным вариантом) ---
en DRM DRM_SUN4I DRM_FBDEV_EMULATION FRAMEBUFFER_CONSOLE
dis DRM_SUN4I_HDMI_CEC DRM_SUN8I_DW_HDMI DRM_PANEL_EDP \
    DRM_PANEL_LVDS DRM_LIMA DRM_SIMPLE_BRIDGE

# --- тачскрин (ёмкостной FT5206 на шине I2C) ---
en INPUT_TOUCHSCREEN TOUCHSCREEN_EDT_FT5X06

# --- сеть/диагностика/systemd/zram (Debian 12 Bookworm) ---
en MODULES MODULE_UNLOAD MODULE_COMPRESS_XZ \
   CGROUPS CGROUP_SCHED CGROUP_PIDS CGROUP_FREEZER CGROUP_DEVICE MEMCG \
   NAMESPACES UTS_NS IPC_NS USER_NS PID_NS NET_NS \
   AUTOFS_FS TMPFS_POSIX_ACL TMPFS_XATTR INOTIFY_USER FANOTIFY FHANDLE \
   VETH TUN BRIDGE VLAN_8021Q IKCONFIG IKCONFIG_PROC PROC_PAGE_MONITOR SYSFS \
   SUNXI_WATCHDOG WATCHDOG
./scripts/config --module ZSMALLOC
./scripts/config --module ZRAM
./scripts/config --module CRYPTO_LZO
./scripts/config --module CRYPTO_LZ4

make olddefconfig || exit 1
cp .config /tmp/kb/kernel.config.new
echo "=== проверка конфига ==="
for s_ in USB_GADGET USB_MUSB_HDRC USB_MUSB_SUNXI USB_MUSB_DUAL_ROLE USB_LIBCOMPOSITE \
          USB_CONFIGFS USB_CONFIGFS_RNDIS USB_CONFIGFS_ECM USB_CONFIGFS_NCM \
          USB_CONFIGFS_MASS_STORAGE USB_CONFIGFS_ACM CONFIGFS_FS \
          USB_STORAGE USB_UAS USBNET USB_NET_CDCETHER USB_NET_RNDIS_HOST \
          USB_SERIAL_FTDI_SIO DRM DRM_SUN4I TOUCHSCREEN_EDT_FT5X06 \
          IKCONFIG_PROC PHY_SUN4I_USB EXTCON MODULES; do
    printf '  %-26s %s\n' "$s_" "$(./scripts/config --state $s_)"
done

echo "=== СБОРКА ($(date)) ==="
time make -j2 zImage dtbs 2>&1 | tail -30
echo "=== ГОТОВО ($(date)) ==="
ls -la arch/arm/boot/zImage arch/arm/boot/dts/allwinner/sun4i-a10-informer-701.dtb

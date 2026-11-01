#!/bin/bash
# Докрутка конфига: USB-сеть (правильные символы) + мелочи, затем сборка.
set -x
cd /tmp/kb/src/linux-6.6 || exit 1
export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
en()  { for s in "$@"; do ./scripts/config --enable  "$s"; done; }
dis() { for s in "$@"; do ./scripts/config --disable "$s"; done; }

# --- USB-сеть: USB_NET_DRIVERS уже =y, нужен фреймворк USB_USBNET и дети ---
en USB_USBNET
en USB_NET_CDCETHER USB_NET_RNDIS_HOST USB_NET_CDC_NCM USB_NET_CDC_EEM \
   USB_NET_AX8817X USB_NET_AX88179_178A USB_NET_DM9601 USB_NET_SMSC95XX \
   USB_NET_SMSC75XX USB_NET_SR9700 USB_NET_MCS7830 USB_NET_CH9200 \
   USB_NET_AQC111 USB_LAN78XX USB_RTL8150 USB_PEGASUS USB_CATC USB_KAWETH
en USB_NET_CDC_SUBSET USB_NET_ZAURUS USB_NET_NET1080 USB_NET_PLUSB USB_NET_GL620A
# --- хост-группа / gadget на всякий случай ещё раз (идемпотентно) ---
en USB_EHCI_HCD USB_EHCI_HCD_PLATFORM USB_OHCI_HCD USB_OHCI_HCD_PLATFORM \
   USB_STORAGE USB_UAS USB_MUSB_HDRC USB_MUSB_SUNXI USB_MUSB_DUAL_ROLE \
   NOP_USB_XCEIV USB_PHY PHY_SUN4I_USB EXTCON SUNXI_SRAM
en USB_GADGET USB_LIBCOMPOSITE USB_CONFIGFS USB_CONFIGFS_RNDIS USB_CONFIGFS_ECM \
   USB_CONFIGFS_EEM USB_CONFIGFS_NCM USB_CONFIGFS_MASS_STORAGE USB_CONFIGFS_ACM \
   USB_CONFIGFS_SERIAL USB_CONFIGFS_F_FS CONFIGFS_FS
# --- сеть/прочее ---
en IPV6 BLK_DEV_LOOP NLS_UTF8 LIBCRC32C CRC_ITU_T IKCONFIG IKCONFIG_PROC
dis MODULES
make olddefconfig

echo "=== ПРОВЕРКА КЛЮЧЕВЫХ СИМВОЛОВ ==="
for s in USB_USBNET USB_NET_CDCETHER USB_NET_RNDIS_HOST USB_NET_CDC_NCM USB_RTL8152 \
         USB_NET_DM9601 USB_NET_SMSC95XX USB_CONFIGFS_RNDIS USB_MUSB_SUNXI NOP_USB_XCEIV \
         PHY_SUN4I_USB EXTCON DRM_SUN4I TOUCHSCREEN_EDT_FT5X06 IKCONFIG_PROC IPV6 \
         INET UNIX98_PTYS MODULES; do
  printf '  %-24s %s\n' "$s" "$(./scripts/config --state $s)"
done
cp .config /tmp/kb/kernel.config.new

echo "=== СБОРКА $(date) ==="
set +x
make -j2 zImage dtbs > /tmp/kb/make.log 2>&1
rc=$?
set -x
echo "BUILD_EXIT=$rc"
tail -25 /tmp/kb/make.log
ls -la arch/arm/boot/zImage arch/arm/boot/dts/allwinner/sun4i-a10-informer-701.dtb
./scripts/config --state USB_USBNET
echo "=== ГОТОВО $(date) ==="

#!/bin/bash
# Assemble a bootable SD-card image for the Informer 701 (N708H6, Allwinner A10).
#
#   usage: BUILD=b007 ./make-sdimage.sh <artifact-dir> <outdir> [copy-to-dir]
#
# Artifacts expected in <artifact-dir>:
#   u-boot-sunxi-with-spl.bin   SPL + U-Boot, written at 8 KiB (where the BROM looks)
#   zImage                      kernel
#   base.dtb informer.dtb pinned.dtb nocpufreq.dtb safe.dtb
#   noaxp.dtb nommc.dtb wdt.dtb
#   rescue2.cpio.gz             diagnostic initramfs
#   rootfs/                     prepared root filesystem
#
# Output (unique per build, so several images can live side by side):
#   informer701-$BUILD.img       raw 512 MiB   (NOT copied to the workspace, too big)
#   informer701-$BUILD.img.xz    compressed
#   informer701-$BUILD.sha256    hashes of the files above
#
# образ выдаётся в .img.xz (Rufus пишет распакованный .img, balenaEtcher
# понадобится - запустить с MAKE_ZIP=1.
#
# Layout (MBR):
#   [0 .. 8K)             empty (MBR)
#   [8K .. ~500K)         u-boot-sunxi-with-spl.bin
#   [1 MiB .. 65 MiB)     vFAT "boot": zImage, *.dtb, initramfs, extlinux/
#   [65 MiB .. end)       ext4 "root": rootfs = /dev/mmcblk0p2
set -euo pipefail

ART="$1"
OUT="$2"
COPYTO="${3:-}"
BUILD="${BUILD:-dev}"

BOOT_MIB=${BOOT_MIB:-64}
TOTAL_MIB=${TOTAL_MIB:-512}
MiB=$((1024*1024))
SECT=512

p1_start=$((1*MiB/SECT))
p1_size=$((BOOT_MIB*MiB/SECT))
p2_start=$((p1_start+p1_size))
total_sect=$((TOTAL_MIB*MiB/SECT))
p2_size=$((total_sect-p2_start))

NAME="informer701-$BUILD"
IMG="$OUT/$NAME.img"

echo "== build $BUILD"
echo "== geometry: p1 @${p1_start}+${p1_size}  p2 @${p2_start}+${p2_size} sectors"

rm -rf "$OUT/work"; mkdir -p "$OUT/work"

# ------------------------------------------------------------------ boot part
BOOT="$OUT/work/boot"
mkdir -p "$BOOT/extlinux"
cp "$ART/zImage"                     "$BOOT/zImage"
for d in informer pinned flatvolt lowopp nocpufreq safe noaxp nommc wdt hdmi nousb; do
    if [ -f "$ART/$d.dtb" ]; then
        cp "$ART/$d.dtb" "$BOOT/$d.dtb"
    else
        echo "   ! $ART/$d.dtb missing" >&2
    fi
done
cp "$BOOT/informer.dtb" "$BOOT/sun4i-a10-informer-701.dtb"   # canonical name
cp "$ART/rescue2.cpio.gz"            "$BOOT/"
[ -f "$ART/rescue.cpio.gz" ] && cp "$ART/rescue.cpio.gz" "$BOOT/"
cp "$ART/u-boot-sunxi-with-spl.bin"  "$BOOT/"

# --- аварийный возврат на проверенное ядро b016 -----------------------------
# b017 - это ПЕРЕСОБРАННОЕ ядро (добавлены musb/gadget/configfs, DRM, USB-сеть).
# Чтобы одна неудачная сборка не оставила плату без загрузки, на разделе лежит
# старое ядро и старый DTB из b016 (комбинация, подтверждённая на плате):
# пункт 17 "b016-lowopp". Сделать его постоянным:  bootnext 17 -p
if [ -f "$ART/zImage-b016" ] && [ -f "$ART/lowopp-b016.dtb" ]; then
    cp "$ART/zImage-b016"     "$BOOT/zImage-b016"
    cp "$ART/lowopp-b016.dtb" "$BOOT/lowopp-b016.dtb"
    echo "== fallback b016 kernel added (zImage-b016 + lowopp-b016.dtb)"
else
    echo "   ! нет zImage-b016/lowopp-b016.dtb - пункт возврата не создаётся" >&2
fi

cat > "$BOOT/extlinux/extlinux.conf" <<'EOF'
# ============================================================================
#  Informer 701 (N708H6, Allwinner A10) - U-Boot distro boot menu, сборка b017
#  Файл можно править прямо с платы: он лежит на vfat-разделе, смонтированном
#  в /boot  (mount уже выполнен в rcS).  Изменили default -> reboot: с b015
#  reboot/poweroff перезапускают плату сами (watchdog-узел включён во всех DTB,
#  обработчик arm_pm_restart зарегистрирован драйвером sunxi_wdt).
#
#  ЧТО НОВОГО (подробно: BUILDS.md и docs/wifi-pakety-akselerometr.md):
#  b017/b018: ядро 6.6 с USB: musb-hdrc (OTG micro-USB), configfs-gadget
#      (RNDIS/ECM/NCM/ACM), USB-хост (EHCI/OHCI, storage, usbnet, usb-serial),
#      DRM/sun4i (HDMI), тач EDT FT5x06; в rootfs dropbear (SSH/scp) и udhcpd.
#      Команда `usbnet` поднимает сеть через USB-кабель, стартует сама.
#  b019/b020: исправлен GPIO ключа питания USB2 - PH3 (был PD22); без этого
#      разъём, впаянный на место WiFi-модуля, не получал питание VBUS.
#  b021: ядро с CONFIG_MODULES: беспроводной стек (cfg80211/mac80211) и ~17
#      драйверов USB-WiFi + прошивки в /lib/firmware; wpa_supplicant/iw/hostapd/
#      dnsmasq; kmod (настоящий modprobe) и /sbin/hotplug - автозагрузка модулей;
#      пакетный менеджер apk (обёртка `pkg`); включены шины TWI1 (акселерометр
#      MMA7660, `accel`) и TWI2 (тач); exFAT/NTFS; netfilter/NAT (`usbnet nat`,
#      `wifi share`); iproute2, usbutils, dosfstools, e2fsprogs, nano, htop,
#      picocom, tzdata, haveged. Новые команды: wifi, accel, pkg.
#
#  Интерактивное меню ЗДЕСЬ НАМЕРЕННО ВЫКЛЮЧЕНО (нет строки "prompt"):
#  U-Boot сразу грузит default, ровно как в проверенных b008-b011.  Без
#  "prompt" ветка menu_get_choice() в common/menu.c уходит в
#  menu_default_choice() - без вывода списка и без ожидания ввода.
#
#  Как выбрать другой пункт (меню для этого не нужно):
#    из Linux   :  bootnext 15     (одноразово; default сам вернётся к прежнему)
#                  bootnext 15 -p  (сделать пункт постоянным)
#                  bootnext        (список пунктов)
#    из U-Boot  :  setenv pxe_label_override nousb; boot
#                  (переменная читается в pxe_menu_to_menu() и подменяет
#                   default; работает без "prompt")
#    какой пункт реально загрузился - команда `whichboot`.
#
#  Строка "12: lowopp" в логе загрузки - это НЕ меню: её печатает label_boot()
#  (boot/pxe_utils.c:476) перед загрузкой ядра, и она есть в каждой сборке.
#
#  ЕСЛИ ПЛАТА НЕ ГРУЗИТСЯ НОВЫМ ЯДРОМ: пункт 17 (b016-lowopp) загружает
#  ПРЕЖНЕЕ ядро zImage-b016 с прежним lowopp-b016.dtb - это ровно та
#  комбинация, что подтверждена на плате в b016. Сделать постоянной:
#      bootnext 17 -p      (или из U-Boot: setenv pxe_label_override b016-lowopp; boot)
#
#  Вернуть интерактивное меню: добавьте строку  prompt 1  (тогда напечатаются
#  все пункты и U-Boot будет ждать timeout/10 секунд на "Enter choice:").
# ============================================================================
default lowopp
timeout 150

# --- 1. safe (аварийный: без cpufreq и без PMIC) ------------------------------
# PMIC/LRADC/RTP выключены, OPP-таблицы нет, cpufreq-dt заблокирован. CPU
# остаётся на той частоте, что выставил SPL. USB-гаджет здесь не поднимается
# (usbnet=0 ssh=0), чтобы в диагностике не участвовало ничего лишнего.
label safe
    kernel /zImage
    devicetree /safe.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=10 loglevel=4 clk_ignore_unused initcall_blacklist=cpufreq_dt_platdev_init usbnet=0 ssh=0

# --- 2. pinned --------------------------------------------------------------
# Всё включено (PMIC, кнопки LRADC, резистивный тач, USB), но в OPP-таблице
# ровно одна точка 1008 МГц @ 1.4 В - та, что уже выставил SPL. cpufreq
# регистрируется, но переключать частоту ему некуда: pll-core не перестраивается.
label pinned
    kernel /zImage
    devicetree /pinned.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=10 loglevel=7 clk_ignore_unused usbnet=1 ssh=1

# --- 3. nofreq --------------------------------------------------------------
# То же, что pinned, но OPP-таблицы нет вообще: cpufreq-dt не стартует.
# PMIC при этом виден ядру (regulators, ADC, зарядник).
label nofreq
    kernel /zImage
    devicetree /nocpufreq.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=10 loglevel=7 clk_ignore_unused usbnet=1 ssh=1

# --- 4. base ----------------------------------------------------------------
# ПОЛНАЯ лестница OPP (1008@1.4 / 912@1.35 / 864@1.30 / 624@1.25 В), cpufreq
# активен, thermal-zones включены. На слабом USB-питании без батареи этот
# пункт в b012-b014 заводился не с первой попытки (просадка VDD-CPU ниже 1.4 В)
# - он оставлен только как диагностика, рабочий пункт - 12 (lowopp).
label base
    kernel /zImage
    devicetree /informer.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=10 loglevel=8 clk_ignore_unused usbnet=1 ssh=1

# --- 5. base-perf -----------------------------------------------------------
# То же дерево, что base, но governor=performance: ядро сразу ставит 1008 МГц
# и НИКОГДА не переключает частоту само. Если base виснет, а base-perf грузится
# - виноват именно переход между точками OPP.
label base-perf
    kernel /zImage
    devicetree /informer.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=10 loglevel=8 clk_ignore_unused cpufreq.default_governor=performance usbnet=1 ssh=1

# --- 6. flatvolt ------------------------------------------------------------
# ДВЕ точки OPP (1008 и 912 МГц), но обе @ 1.4 В - напряжение уже стоит,
# регулятор при переходе не трогается. governor=performance: сам по себе он
# частоту не меняет, переход делается руками командой cftest 912000.
label flatvolt
    kernel /zImage
    devicetree /flatvolt.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=10 loglevel=8 clk_ignore_unused cpufreq.default_governor=performance usbnet=1 ssh=1

# --- 7. base-initcall -------------------------------------------------------
# То же, что base, плюс initcall_debug: видно, на каком initcall всё встаёт.
# Вывод длинный, терминал должен писать в файл. Гаджет отключён, чтобы его
# сообщения не мешали разбирать тайминги инициализации.
label base-initcall
    kernel /zImage
    devicetree /informer.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=10 loglevel=8 clk_ignore_unused initcall_debug usbnet=0 ssh=0

# --- 8. rescue --------------------------------------------------------------
# Загрузка в диагностический initramfs (без монтирования корня). Автозапуск diag.
# Команды: diag pmic pmic-regs clk regs memtest mmcinfo info
label rescue
    kernel /zImage
    initrd /rescue2.cpio.gz
    devicetree /nocpufreq.dtb
    append console=ttyS0,115200n8 loglevel=7 clk_ignore_unused

# --- 9. noaxp ---------------------------------------------------------------
# noaxp: PMIC выключен, OPP-таблица есть - проверка "а вдруг виноват axp20x"
label noaxp
    kernel /zImage
    devicetree /noaxp.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=10 loglevel=7 clk_ignore_unused initcall_blacklist=cpufreq_dt_platdev_init usbnet=1 ssh=1

# --- 10. wdt ----------------------------------------------------------------
# Начиная с b015 узел watchdog включён ВО ВСЕХ DTB: без него в ядре нет
# обработчика перезапуска (arm_pm_restart = null_restart), и команда reboot
# печатала "Restarting system" и зависала. Пункт wdt отличается от lowopp
# только строкой model в DTB (оставлен для совместимости номеров).
label wdt
    kernel /zImage
    devicetree /wdt.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=10 loglevel=7 clk_ignore_unused usbnet=1 ssh=1

# --- 11. safe-v -------------------------------------------------------------
# ТО ЖЕ САМОЕ, что safe (тот же safe.dtb, тот же blacklist), но loglevel=8 и
# panic=0. Нужен, когда плата молча перезагружается после "Starting kernel ...".
label safe-v
    kernel /zImage
    devicetree /safe.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=0 loglevel=8 clk_ignore_unused initcall_blacklist=cpufreq_dt_platdev_init usbnet=0 ssh=0

# --- 12. lowopp (ПО УМОЛЧАНИЮ) ----------------------------------------------
# Полная таблица OPP (1008/912/864/624 МГц), но ВСЕ точки @ 1.4 В: напряжение
# VDD-CPU не меняется никогда, а частота переключается свободно. ПРОВЕРЕНО НА
# ПЛАТЕ в b015/b016. В b017 к этому добавлены usbnet=1 ssh=1: через 4 с после
# старта /etc/init.d/local поднимает USB-гаджет (RNDIS) и dropbear, то есть
# сеть и SSH доступны по тому же кабелю micro-USB, что и питание:
#     ssh root@192.168.77.1     пароль informer701
# loglevel=4 - тихая загрузка; подробный лог нужен в пункте 13 (lowopp-v).
label lowopp
    kernel /zImage
    devicetree /lowopp.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=10 loglevel=4 clk_ignore_unused usbnet=1 ssh=1

# --- 13. lowopp-v -----------------------------------------------------------
# ТО ЖЕ САМОЕ, что lowopp, но loglevel=8 (видно всё, что печатает ядро, включая
# probe musb/phy/gadget) и panic=0 (паника остаётся на экране).
label lowopp-v
    kernel /zImage
    devicetree /lowopp.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=0 loglevel=8 clk_ignore_unused usbnet=1 ssh=1

# --- 14. usbnet -------------------------------------------------------------
# Основной рабочий пункт для сети через USB: то же ядро и тот же lowopp.dtb,
# но loglevel=8 - в логе видно, как musb определяет роль (peripheral), как
# phy сообщает VBUS/ID и как configfs-gadget привязывается к UDC. Если после
# `usbnet on` ПК не видит устройство - грузитесь сюда и смотрите dmesg.
label usbnet
    kernel /zImage
    devicetree /lowopp.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=10 loglevel=8 clk_ignore_unused usbnet=1 ssh=1

# --- 15. nousb --------------------------------------------------------------
# Все USB-узлы выключены в DTB (musb, usbphy, ehci0/1, ohci0/1) + usbnet=0.
# Контрольный пункт: если new kernel с USB не грузится, а nousb грузится -
# проблема именно в USB-части дерева/драйверов.
label nousb
    kernel /zImage
    devicetree /nousb.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=10 loglevel=8 clk_ignore_unused nousb=1 usbnet=0 ssh=0

# --- 16. hdmi ---------------------------------------------------------------
# Включены display-engine и hdmi@1c16000 (tcon0/tcon1 в sun4i-a10.dtsi не имеют
# status, т.е. уже включены; узел hdmi-connector в дереве есть - без него
# sun4i_hdmi_get_ddc() вернул бы -EINVAL и драйвер не забиндился бы вовсе).
# Нужен, когда появится HDMI-кабель: DRM поднимет framebuffer, fbcon выведет
# консоль на экран, последовательная консоль при этом продолжит работать.
label hdmi
    kernel /zImage
    devicetree /hdmi.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=10 loglevel=8 clk_ignore_unused usbnet=1 ssh=1

# nommc.dtb на разделе лежит, но пункта меню нет: эксперимент закончен
# (mmc работает), а лишние строки в меню только мешают.
EOF

# пункт аварийного возврата появляется ТОЛЬКО если в prebuilt/ есть и ядро b016,
# и его DTB: иначе в меню был бы битый пункт, который не может загрузиться
if [ -f "$BOOT/zImage-b016" ] && [ -f "$BOOT/lowopp-b016.dtb" ]; then
    cat >> "$BOOT/extlinux/extlinux.conf" <<'EOF17'
# --- 17. b016-lowopp (АВАРИЙНЫЙ ВОЗВРАТ) ------------------------------------
# ПРЕЖНЕЕ ядро (zImage-b016) и ПРЕЖНИЙ lowopp-b016.dtb. В нём нет USB-гаджета
# и SSH, зато оно гарантированно грузится. Сделать постоянным: bootnext 17 -p
label b016-lowopp
    kernel /zImage-b016
    devicetree /lowopp-b016.dtb
    append console=ttyS0,115200n8 root=/dev/mmcblk0p2 rw rootwait panic=10 loglevel=4 clk_ignore_unused usbnet=0 ssh=0
EOF17
fi

# heredoc выше кавычкованный, поэтому номер сборки подставляем отдельно
sed -i "s/сборка b017$/сборка $BUILD/" "$BOOT/extlinux/extlinux.conf"

{
    echo "build $BUILD"
    echo "u-boot : $(sha256sum "$ART/u-boot-sunxi-with-spl.bin" | cut -c1-16)  $(stat -c%s "$ART/u-boot-sunxi-with-spl.bin") bytes"
    echo "zImage : $(sha256sum "$ART/zImage" | cut -c1-16)  $(stat -c%s "$ART/zImage") bytes"
    [ -f "$BOOT/zImage-b016" ] && \
        echo "zb016  : $(sha256sum "$BOOT/zImage-b016" | cut -c1-16)  $(stat -c%s "$BOOT/zImage-b016") bytes"
    for f in "$BOOT"/*.dtb; do echo "dtb    : $(sha256sum "$f" | cut -c1-16)  $(basename "$f")"; done
} > "$BOOT/BUILD-$BUILD.txt"

mkfs.vfat -C -n BOOT "$OUT/work/boot.vfat" $((BOOT_MIB*1024)) >/dev/null
VFAT="$OUT/work/boot.vfat"
MTOOLS_SKIP_CHECK=1 mcopy -o -i "$VFAT" \
    "$BOOT"/zImage* "$BOOT"/*.dtb "$BOOT"/*.cpio.gz \
    "$BOOT"/u-boot-sunxi-with-spl.bin "$BOOT"/BUILD-"$BUILD".txt ::/
MTOOLS_SKIP_CHECK=1 mmd -i "$VFAT" ::/extlinux 2>/dev/null || true
MTOOLS_SKIP_CHECK=1 mcopy -o -i "$VFAT" "$BOOT/extlinux/extlinux.conf" ::/extlinux/

# Каталог apk/ на разделе BOOT: сюда с ПК (раздел виден как обычный диск) можно
# положить файлы .apk, и на плате выполнить `pkg local` - установка пакетов
# Alpine без интернета. Полезно, пока на плате нет ни WiFi, ни NAT через ПК.
mkdir -p "$BOOT/apk"
cat > "$BOOT/apk/README.txt" <<'EOF'
Каталог apk - офлайновая установка пакетов Alpine на плате.

1. На ПК скачайте нужные .apk для Alpine v3.20, архитектура armv7:
     https://dl-cdn.alpinelinux.org/alpine/v3.20/main/armv7/
     https://dl-cdn.alpinelinux.org/alpine/v3.20/community/armv7/
   (поиск по имени: https://pkgs.alpinelinux.org/packages?name=...&branch=v3.20&arch=armv7)
2. Скопируйте их в ЭТОТ каталог (на карте он виден из Windows как диск BOOT).
3. На плате выполните:  pkg local        (или явно: pkg local /boot/apk)

Не забудьте про зависимости: что нужно, покажет `pkg deps <имя>` (если индекс
уже обновлён) или страница пакета на pkgs.alpinelinux.org.

Проще всего получить интернет на плату и ставить напрямую:
   wifi connect <SSID> <пароль>   - через USB-WiFi адаптер
   usbnet nat                     - через USB-кабель от ПК
Потом:  pkg time && pkg update && pkg add <имя>
EOF
MTOOLS_SKIP_CHECK=1 mmd -i "$VFAT" ::/apk 2>/dev/null || true
MTOOLS_SKIP_CHECK=1 mcopy -o -i "$VFAT" "$BOOT/apk/README.txt" ::/apk/
# the boot menu must be there, otherwise U-Boot has nothing to load
MTOOLS_SKIP_CHECK=1 mdir -i "$VFAT" ::/extlinux | grep -q extlinux.conf || {
    echo "FATAL: /extlinux/extlinux.conf is not on the boot partition" >&2; exit 1; }

echo "== boot partition:"
MTOOLS_SKIP_CHECK=1 mdir -i "$VFAT" ::/ | sed -n '4,40p'
MTOOLS_SKIP_CHECK=1 mdir -i "$VFAT" ::/extlinux | sed -n '4,8p'

# --------------------------------------------------------------- root (ext4)
root_blocks=$((p2_size*SECT/4096))
mkfs.ext4 -q -F -b 4096 -L rootfs -d "$ART/rootfs" \
    -U 8f1a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8 "$OUT/work/root.ext4" ${root_blocks}

# ------------------------------------------------------------------ assemble
dd if=/dev/zero of="$IMG" bs=1M count=$TOTAL_MIB status=none

python3 - "$IMG" "$p1_start" "$p1_size" "$p2_start" "$p2_size" <<'PYEOF'
import sys, struct
img, p1s, p1n, p2s, p2n = (sys.argv[1], int(sys.argv[2]), int(sys.argv[3]),
                           int(sys.argv[4]), int(sys.argv[5]))
def chs(sector):
    c, h, s = sector//63//255, (sector//63) % 255, (sector % 63) + 1
    return bytes([h, ((c >> 8) << 6) | s, c & 0xff])
mbr = bytearray(512)
mbr[446] = 0x00
mbr[447:450] = chs(p1s);      mbr[450] = 0x0C
mbr[451:454] = chs(p1s+p1n-1); mbr[454:458] = struct.pack('<I', p1s)
mbr[458:462] = struct.pack('<I', p1n)
mbr[462] = 0x00
mbr[463:466] = chs(p2s);      mbr[466] = 0x83
mbr[467:470] = chs(p2s+p2n-1); mbr[470:474] = struct.pack('<I', p2s)
mbr[474:478] = struct.pack('<I', p2n)
mbr[510:512] = b'\x55\xaa'
with open(img, 'r+b') as f:
    f.write(mbr)
print("MBR written")
PYEOF

dd if="$ART/u-boot-sunxi-with-spl.bin" of="$IMG" bs=1024 seek=8 conv=notrunc status=none
dd if="$OUT/work/boot.vfat" of="$IMG" bs=$SECT seek=$p1_start conv=notrunc status=none
dd if="$OUT/work/root.ext4" of="$IMG" bs=$SECT seek=$p2_start conv=notrunc status=none
sync

echo "== compressing"
xz -6 -T1 --memlimit-compress=300MiB -c "$IMG" > "$IMG.xz"
if [ "${MAKE_ZIP:-0}" = 1 ]; then
    ( cd "$OUT" && rm -f "$NAME.img.zip" && zip -q -9 "$NAME.img.zip" "$NAME.img" )
fi

SHA_IMG=$(sha256sum "$IMG" | cut -d' ' -f1)
SHA_XZ=$(sha256sum "$IMG.xz" | cut -d' ' -f1)
cat > "$OUT/$NAME.sha256" <<EOF
# Informer 701 (N708H6, Allwinner A10) - SD image, build $BUILD
# Прошивка: распакуйте .xz (xz -dk, 7-Zip, WinRAR; balenaEtcher пишет .img.xz напрямую) и
#   sudo dd if=$NAME.img of=/dev/sdX bs=4M status=progress oflag=sync conv=fsync
# Ключ SHA256, по которому надо сверять - это ПЕРВАЯ строка (образ без сжатия).
$SHA_IMG  $NAME.img        (распакованный, 512 MiB)
$SHA_XZ  $NAME.img.xz
EOF
if [ "${MAKE_ZIP:-0}" = 1 ]; then
    echo "$(sha256sum "$IMG.zip" | cut -d' ' -f1)  $NAME.img.zip" >> "$OUT/$NAME.sha256"
fi
cat "$OUT/$NAME.sha256"

# ------------------------------------------------------------ hand out copies
for f in "$IMG.xz" "$OUT/$NAME.sha256"; do
    cp -f "$f" "$OUT/../" 2>/dev/null || true
done
if [ "${MAKE_ZIP:-0}" = 1 ]; then
    cp -f "$IMG.zip" "$OUT/../" 2>/dev/null || true
fi
if [ -n "$COPYTO" ]; then
    mkdir -p "$COPYTO"
    cp -f "$IMG.xz" "$OUT/$NAME.sha256" "$COPYTO/"
    if [ "${MAKE_ZIP:-0}" = 1 ]; then cp -f "$IMG.zip" "$COPYTO/"; fi
    echo "== copied to $COPYTO"
    ls -la "$COPYTO"
fi

echo
echo "== done: $IMG"
ls -la "$OUT/$NAME".*

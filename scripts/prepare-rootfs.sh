#!/bin/bash
# prepare-rootfs.sh <каталог>
#
# Собирает корневую ФС Debian 12 (Bookworm) armhf (glibc, bash, systemd, apt)
# для платы Informer 701 (Allwinner A10 / sun4i, Cortex-A8, VFPv3/NEON, 512 МиБ RAM):
#   1. debootstrap --arch=armhf --variant=minbase bookworm + qemu-user-static;
#   2. установка всех эквивалентных пакетов Debian armhf через chroot + apt-get
#      с очисткой кэшей apt и исключением лишних man/doc/locale (01-nodoc);
#   3. распаковка модулей ядра 6.6.0-b021 (включая zram/zsmalloc/lz4/lzo) с
#      сохранением merged-usr симлинка /lib -> usr/lib, и прошивок Wi-Fi +
#      подписанной regulatory.db (ключ Seth Forshee для ядра 6.6);
#   4. установка кросс-скомпилированного под armhf glibc devmem2, всех бортовых
#      утилит (/usr/local/bin/*, /usr/local/sbin/*, /sbin/hotplug), конфигов
#      tmpfs (/tmp, /var/tmp, /var/log), volatile journald, zram swap и
#      аппаратного watchdog (/dev/watchdog через systemd RuntimeWatchdogSec=16s).
#
# Все тяжёлые операции выполняются строго в переданном каталоге (по умолчанию
# в /tmp), не затрагивая рабочий репозиторий.
set -euo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
export PATH

if [ "$(id -u)" -ne 0 ]; then
    exec sudo -E env PATH="$PATH" bash "$0" "$@"
fi

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:?укажите целевой каталог в /tmp или /dev/shm, например /tmp/informer701-work/rootfs}"
DEBIAN_SUITE="${DEBIAN_SUITE:-bookworm}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
DEBIAN_SEC_MIRROR="${DEBIAN_SEC_MIRROR:-http://security.debian.org/debian-security}"
ROOT_PASSWORD="${ROOT_PASSWORD:-informer701}"

case "$DEST" in
    "$HERE"|"$HERE"/*)
        echo "ОШИБКА: каталог rootfs ($DEST) не должен находиться внутри репозитория ($HERE)!" >&2
        echo "Используйте /tmp/... или /dev/shm/..." >&2
        exit 1
        ;;
esac

MODS="${MODS:-$HERE/prebuilt/modules-6.6.0-b021.tar.xz}"
FW_SRC="${FW_SRC:-$HERE/firmware}"
DEVMEM2_BIN="${DEVMEM2_BIN:-$HERE/prebuilt/devmem2}"
RF="$HERE/rootfs-files"

for f in "$MODS" "$DEVMEM2_BIN" "$FW_SRC/regulatory.db" "$FW_SRC/regulatory.db.p7s"; do
    [ -e "$f" ] || { echo "нет обязательного файла: $f" >&2; exit 1; }
done

for cmd in debootstrap chroot tar xz; do
    command -v "$cmd" >/dev/null || { echo "нужна утилита хоста: $cmd" >&2; exit 1; }
done

arm_binfmt_ok() {
    [ -e /proc/sys/fs/binfmt_misc/qemu-arm ] && return 0
    [ -e /proc/sys/fs/binfmt_misc/arm ] && return 0
    grep -qlE '454c46010101.*2800' /proc/sys/fs/binfmt_misc/* 2>/dev/null && return 0
    return 1
}

# Активировать binfmt_misc для прозрачного запуска armhf ELF в chroot
if ! arm_binfmt_ok; then
    [ -e /proc/sys/fs/binfmt_misc/status ] || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
    if command -v update-binfmts >/dev/null 2>&1; then
        update-binfmts --enable qemu-arm 2>/dev/null || true
    fi
    if ! arm_binfmt_ok && [ -x /usr/lib/systemd/systemd-binfmt ]; then
        /usr/lib/systemd/systemd-binfmt 2>/dev/null || true
    fi
    if ! arm_binfmt_ok && [ -x /usr/bin/qemu-arm-static ] && [ -w /proc/sys/fs/binfmt_misc/register ]; then
        echo ':qemu-arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-arm-static:OCF' \
            > /proc/sys/fs/binfmt_misc/register 2>/dev/null || true
    fi
fi
arm_binfmt_ok || {
    echo "ОШИБКА: обработчик binfmt_misc для armhf не зарегистрирован, chroot невозможен" >&2
    exit 1
}

# В контейнерных окружениях /tmp и /dev/shm часто смонтированы с nodev,nosuid,
# из-за чего debootstrap отказывается создавать устройства и suid-бинарники.
mkdir -p "$(dirname "$DEST")"
MNT_OPTS=$(findmnt -n -o OPTIONS --target "$(dirname "$DEST")" 2>/dev/null || true)
case ",$MNT_OPTS," in
    *,nodev,*|*,nosuid,*|*,noexec,*)
        MNT_TARGET=$(findmnt -n -o TARGET --target "$(dirname "$DEST")")
        echo "[rootfs] remount $MNT_TARGET с dev,suid,exec (было: $MNT_OPTS)"
        mount -o remount,dev,suid,exec "$MNT_TARGET"
        ;;
esac

cleanup_mounts() {
    set +e
    for mp in "$DEST/dev/pts" "$DEST/dev" "$DEST/sys" "$DEST/proc"; do
        if mountpoint -q "$mp" 2>/dev/null; then
            umount -lf "$mp" 2>/dev/null || true
        fi
    done
    rm -f "$DEST/usr/sbin/policy-rc.d" "$DEST/usr/bin/qemu-arm-static" 2>/dev/null || true
}
trap cleanup_mounts EXIT

cleanup_mounts
rm -rf "$DEST"
mkdir -p "$DEST"

echo "[rootfs] 1/7 debootstrap Debian 12 ($DEBIAN_SUITE) armhf --variant=minbase -> $DEST"
KEYRING_ARG=()
if [ -f /usr/share/keyrings/debian-archive-keyring.gpg ]; then
    KEYRING_ARG=(--keyring=/usr/share/keyrings/debian-archive-keyring.gpg)
fi
debootstrap \
    --arch=armhf \
    --variant=minbase \
    "${KEYRING_ARG[@]}" \
    --include=ca-certificates,debian-archive-keyring \
    "$DEBIAN_SUITE" "$DEST" "$DEBIAN_MIRROR"

echo "[rootfs] 2/7 настройка dpkg/apt (без man/doc/locale, экономия места на SD)"
mkdir -p "$DEST/etc/dpkg/dpkg.cfg.d" "$DEST/etc/apt/apt.conf.d"
install -m 0644 "$RF/etc/dpkg/dpkg.cfg.d/01-nodoc" "$DEST/etc/dpkg/dpkg.cfg.d/01-nodoc"
install -m 0644 "$RF/etc/apt/apt.conf.d/99-informer701" "$DEST/etc/apt/apt.conf.d/99-informer701"

cat > "$DEST/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_SUITE main contrib non-free non-free-firmware
deb $DEBIAN_MIRROR ${DEBIAN_SUITE}-updates main contrib non-free non-free-firmware
deb $DEBIAN_SEC_MIRROR ${DEBIAN_SUITE}-security main contrib non-free non-free-firmware
EOF

if [ -x /usr/bin/qemu-arm-static ]; then
    install -m 0755 /usr/bin/qemu-arm-static "$DEST/usr/bin/qemu-arm-static"
fi

# Запрещаем автостарт демонов внутри сборочного chroot во время apt-get install
cat > "$DEST/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$DEST/usr/sbin/policy-rc.d"

mount -t proc proc "$DEST/proc"
mount -t sysfs sysfs "$DEST/sys"
mount --bind /dev "$DEST/dev"
mount --bind /dev/pts "$DEST/dev/pts"

# Полный список пакетов Debian 12 armhf (замена всех бывших пакетов Alpine + systemd)
DEBIAN_PKGS=(
    # Init, udev, dbus, модули ядра, часы без батарейки RTC
    systemd systemd-sysv systemd-timesyncd udev dbus kmod fake-hwclock
    # Базовое окружение GNU/Linux и утилиты диагностики
    bash login passwd mount coreutils util-linux procps psmisc
    findutils grep sed gawk mawk tar gzip xz-utils cpio
    less nano htop tzdata
    # Сеть, Wi-Fi (STA + AP + NAT), DHCP, DNS, SSH (сервер + клиент), HTTP, NTP
    iproute2 libatm1 iputils-ping iptables isc-dhcp-client dnsmasq-base
    wpasupplicant iw wireless-tools rfkill hostapd ethtool
    dropbear-bin openssh-client curl wget ntpsec-ntpdate netbase
    # Аппаратная диагностика (I2C/PMIC/акселерометр, USB, ФС, память, UART, энтропия)
    i2c-tools usbutils dosfstools e2fsprogs fdisk memtester picocom haveged
)

echo "[rootfs] 3/7 chroot apt-get install (${#DEBIAN_PKGS[@]} пакетов Debian armhf)"
chroot "$DEST" /usr/bin/env \
    DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C \
    LANG=C \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    bash -e -c "
        apt-get update
        apt-get install -y --no-install-recommends ${DEBIAN_PKGS[*]}

        # Ядро 6.6.0-b021 собрано с классическим CONFIG_IP_NF_IPTABLES/NAT (без nf_tables)
        update-alternatives --set iptables /usr/sbin/iptables-legacy
        update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

        # Shell по умолчанию для root - /bin/bash, пароль root
        chsh -s /bin/bash root
        echo 'root:${ROOT_PASSWORD}' | chpasswd

        # Часовой пояс UTC по умолчанию
        ln -sf /usr/share/zoneinfo/UTC /etc/localtime
        echo UTC > /etc/timezone

        # Фиксируем machine-id, чтобы systemd 252 не запускал preset-all на первом старте
        # и не перезаписывал наши enable/disable/mask симлинки сервисов
        systemd-machine-id-setup
        mkdir -p /var/lib/dbus
        ln -sf /etc/machine-id /var/lib/dbus/machine-id

        # Предварительно создаём ключи Dropbear, чтобы первая загрузка не тратила на это время
        mkdir -p /etc/dropbear && chmod 0700 /etc/dropbear
        dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null 2>&1 || true
        dropbearkey -t ecdsa   -f /etc/dropbear/dropbear_ecdsa_host_key   >/dev/null 2>&1 || true
        dropbearkey -t rsa -s 2048 -f /etc/dropbear/dropbear_rsa_host_key >/dev/null 2>&1 || true
        chmod 0600 /etc/dropbear/* 2>/dev/null || true

        # Сохраняем манифест пакетов, вшитых в образ (для команды pkg baked)
        dpkg-query -W -f='\${Package} \${Version}\n' > /etc/apt/baked.txt

        # Полная очистка кэша apt и списков пакетов внутри chroot
        apt-get clean
        rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*
    "

# Удаляем policy-rc.d и размонтируем служебные ФС chroot
cleanup_mounts

# Удаляем документацию/локали, попавшие ещё на этапе minbase (сохраняя copyright)
find "$DEST/usr/share/man" -mindepth 1 -delete 2>/dev/null || true
find "$DEST/usr/share/locale" -mindepth 1 -maxdepth 1 ! -name 'locale.alias' -exec rm -rf {} + 2>/dev/null || true
find "$DEST/usr/share/doc" -type f ! -name 'copyright' -delete 2>/dev/null || true
find "$DEST/usr/share/doc" -type l -delete 2>/dev/null || true
find "$DEST/usr/share/doc" -type d -empty -delete 2>/dev/null || true

echo "[rootfs] 4/7 модули ядра ($(basename "$MODS")) и прошивки Wi-Fi + regulatory.db"
# КРИТИЧНО: --keep-directory-symlink сохраняет merged-usr симлинк /lib -> usr/lib!
tar --keep-directory-symlink -xJf "$MODS" -C "$DEST"
if [ ! -e "$DEST/lib/ld-linux-armhf.so.3" ]; then
    echo "ОШИБКА: повреждён /lib -> usr/lib после распаковки модулей!" >&2
    exit 1
fi
KREL=$(ls "$DEST/lib/modules" | head -1)
if command -v depmod >/dev/null 2>&1; then
    depmod -a -b "$DEST" "$KREL"
elif [ -x /sbin/depmod ]; then
    /sbin/depmod -a -b "$DEST" "$KREL"
fi

mkdir -p "$DEST/usr/lib/firmware"
cp -a "$FW_SRC"/. "$DEST/usr/lib/firmware/"

echo "[rootfs] 5/7 кросс-скомпилированный devmem2 и бортовые утилиты Informer 701"
mkdir -p "$DEST/usr/local/bin" "$DEST/usr/local/sbin" "$DEST/sbin"
install -m 0755 "$DEVMEM2_BIN" "$DEST/usr/local/bin/devmem2"
ln -sf /usr/local/bin/devmem2 "$DEST/usr/sbin/devmem2"

for s in "$RF"/usr-local-bin/*; do
    install -m 0755 "$s" "$DEST/usr/local/bin/$(basename "$s")"
done
for s in "$RF"/usr-local-sbin/*; do
    install -m 0755 "$s" "$DEST/usr/local/sbin/$(basename "$s")"
done
install -m 0755 "$RF/sbin/hotplug" "$DEST/sbin/hotplug"

echo "[rootfs] 6/7 конфигурация системы (/etc, fstab с tmpfs, sysctl, udev, systemd)"
mkdir -p \
    "$DEST/boot" "$DEST/tmp" "$DEST/var/tmp" "$DEST/var/log" \
    "$DEST/etc/sysctl.d" "$DEST/etc/tmpfiles.d" "$DEST/etc/udev/rules.d" \
    "$DEST/etc/modules-load.d" "$DEST/etc/profile.d" \
    "$DEST/etc/informer701" "$DEST/etc/wifi/networks.d" "$DEST/etc/dropbear"
chmod 1777 "$DEST/tmp" "$DEST/var/tmp"
chmod 0700 "$DEST/etc/wifi" "$DEST/etc/wifi/networks.d"

install -m 0644 "$RF/etc/fstab" "$DEST/etc/fstab"
install -m 0644 "$RF/etc/sysctl.d/90-informer701.conf" "$DEST/etc/sysctl.d/90-informer701.conf"
install -m 0644 "$RF/etc/tmpfiles.d/informer701-varlog.conf" "$DEST/etc/tmpfiles.d/informer701-varlog.conf"
install -m 0644 "$RF/etc/udev/rules.d/90-informer701.rules" "$DEST/etc/udev/rules.d/90-informer701.rules"

echo "informer701" > "$DEST/etc/hostname"
cat > "$DEST/etc/hosts" <<'EOF'
127.0.0.1       localhost
127.0.1.1       informer701
::1             localhost ip6-localhost ip6-loopback
EOF

cat > "$DEST/etc/resolv.conf" <<'EOF'
# Заполняется автоматически dhclient (wifi / usbnet host) или вручную.
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

# По умолчанию автоподнимаем USB-гаджет (ECM + RNDIS, usb0 = 192.168.77.1/24, DHCP) и SSH
cat > "$DEST/etc/informer701/usbnet.conf" <<'EOF'
MODE=both
EOF
touch "$DEST/etc/usbnet-enabled" "$DEST/etc/ssh-enabled"
echo "${BOOT_DEFAULT:-lowopp}" > "$DEST/etc/boot-default"

# Загружаем cfg80211 на старте (проверяет подписанную regulatory.db); остальные Wi-Fi/USB
# модули подгрузит systemd-udevd по VID:PID подключённого адаптера.
cat > "$DEST/etc/modules-load.d/informer701.conf" <<'EOF'
cfg80211
EOF

cat > "$DEST/etc/profile.d/informer701.sh" <<'EOF'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export LC_NUMERIC=C
EOF
chmod 0644 "$DEST/etc/profile.d/informer701.sh"

BUILD_ID="${BUILD:-debian12}-$(date -u +%Y%m%d-%H%M)"
echo "$BUILD_ID" > "$DEST/etc/build-id"

cat > "$DEST/etc/issue" <<'EOF'

Informer 701 (Allwinner A10, Debian 12 Bookworm armhf) \n \l

EOF

cat > "$DEST/etc/motd" <<EOF

====================================================================
 Informer 701 (плата N708H6, Allwinner A10, 512 МиБ DDR3)
 Debian 12 (Bookworm) armhf / systemd / Linux $KREL ($BUILD_ID)
====================================================================
 Быстрые команды:
   info       сводка по плате, памяти, zram, watchdog и PMIC
   diag       полный отчёт (частоты, AXP209, dmesg, разделы)
   savelog    сохранить diag + journalctl на FAT-раздел /boot/logs/
   usbnet     сеть по micro-USB OTG (192.168.77.1, SSH, DHCP)
   wifi       управление Wi-Fi (scan, up, ap, share, status, selftest)
   pkg        менеджер пакетов (обёртка над apt / dpkg)
   accel      акселерометр MMA7660 (read, watch, level, info)
   pmic-vbus  контроль напряжения питания 5 В через АЦП AXP209
   wdt        статус аппаратного сторожевого таймера (/dev/watchdog)
   bootnext   безопасный выбор варианта DTB на одну загрузку
====================================================================
EOF

echo "[rootfs] 7/7 настройка юнитов systemd, zram, watchdog, dropbear, usbnet, wifi"
mkdir -p \
    "$DEST/etc/systemd/system.conf.d" \
    "$DEST/etc/systemd/journald.conf.d" \
    "$DEST/etc/systemd/system/serial-getty@ttyS0.service.d" \
    "$DEST/etc/systemd/system/haveged.service.d" \
    "$DEST/etc/systemd/system/multi-user.target.wants" \
    "$DEST/etc/systemd/system/getty.target.wants" \
    "$DEST/etc/systemd/system/sysinit.target.wants"

install -m 0644 "$RF/systemd/system-watchdog.conf" \
    "$DEST/etc/systemd/system.conf.d/10-watchdog.conf"
install -m 0644 "$RF/systemd/journald-volatile.conf" \
    "$DEST/etc/systemd/journald.conf.d/10-volatile.conf"
install -m 0644 "$RF/systemd/serial-getty-ttyS0-override.conf" \
    "$DEST/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf"
install -m 0644 "$RF/systemd/haveged-override.conf" \
    "$DEST/etc/systemd/system/haveged.service.d/override.conf"

for unit in \
    informer701-zram.service \
    informer701-bootonce.service \
    dropbear.service \
    informer701-usbnet.service \
    informer701-wifi.service
do
    install -m 0644 "$RF/systemd/$unit" "$DEST/etc/systemd/system/$unit"
done

# Включаем критичные сервисы:
ln -sf /etc/systemd/system/informer701-zram.service \
    "$DEST/etc/systemd/system/sysinit.target.wants/informer701-zram.service"
ln -sf /etc/systemd/system/informer701-bootonce.service \
    "$DEST/etc/systemd/system/multi-user.target.wants/informer701-bootonce.service"
ln -sf /etc/systemd/system/dropbear.service \
    "$DEST/etc/systemd/system/multi-user.target.wants/dropbear.service"
ln -sf /etc/systemd/system/informer701-usbnet.service \
    "$DEST/etc/systemd/system/multi-user.target.wants/informer701-usbnet.service"
ln -sf /etc/systemd/system/informer701-wifi.service \
    "$DEST/etc/systemd/system/multi-user.target.wants/informer701-wifi.service"
ln -sf /lib/systemd/system/serial-getty@.service \
    "$DEST/etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service"

# Отключаем/маскируем фоновые таймеры записи на SD-карту, неиспользуемый autofs
# (CONFIG_AUTOFS_FS выключен в ядре) и системные шаблоны wpa_supplicant/hostapd
# (ими управляет утилита /usr/local/bin/wifi с собственными конфигами в /run/wifi).
for mask_unit in \
    proc-sys-fs-binfmt_misc.automount \
    proc-sys-fs-binfmt_misc.mount \
    wpa_supplicant.service \
    hostapd.service \
    apt-daily.timer \
    apt-daily-upgrade.timer \
    e2scrub_all.timer \
    e2scrub_reap.service \
    fstrim.timer
do
    ln -sf /dev/null "$DEST/etc/systemd/system/$mask_unit"
    rm -f "$DEST/etc/systemd/system/timers.target.wants/$mask_unit" \
          "$DEST/etc/systemd/system/multi-user.target.wants/$mask_unit" \
          "$DEST/etc/systemd/system/sysinit.target.wants/$mask_unit" 2>/dev/null || true
done

# Очищаем временные логи от установки пакетов (в бою /var/log монтируется в tmpfs)
rm -rf "$DEST/var/log/"* "$DEST/tmp/"* "$DEST/var/tmp/"* 2>/dev/null || true

MOD_COUNT=$(find "$DEST/lib/modules" -name '*.ko*' | wc -l)
FW_COUNT=$(find "$DEST/lib/firmware" -type f | wc -l)
echo "[rootfs] готово: $DEST ($(du -sh "$DEST" | cut -f1)), ядро $KREL, модулей: $MOD_COUNT, файлов firmware: $FW_COUNT"

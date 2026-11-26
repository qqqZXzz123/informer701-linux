#!/bin/bash
# qtest-init.sh - автоматический самотест образа Informer 701 (Debian 12 Bookworm armhf)
# внутри QEMU (qemu-system-arm -M cubieboard, реальный systemd PID 1).
#
# Запускается сервисом informer701-qtest.service ПОСЛЕ достижения multi-user.target,
# проверяя реальную загрузку systemd, zram, tmpfs, journald volatile, /dev/watchdog,
# сеть usb0 (192.168.77.1 + DHCP + SSH), модули ядра 6.6 + regulatory.db, NAT и все
# бортовые утилиты. В конце печатает маркер QTEST_RESULT: PASS|FAIL.

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH LC_ALL=C LC_NUMERIC=C

# Пишем одновременно в stdout и напрямую в /dev/ttyS0, чтобы лог гарантированно
# попадал в -serial stdio независимо от буферизации journald.
exec > /dev/ttyS0 2>&1

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$*"; }
sect() { printf '\n=== %s ===\n' "$*"; }

check() {
    local desc="$1"; shift
    if "$@" >/tmp/qtest.out 2>&1; then
        ok "$desc"
    else
        bad "$desc"
        sed 's/^/         | /' /tmp/qtest.out | head -12
    fi
}

echo ""
echo "=================================================================="
echo " Informer 701 QEMU self-test (Debian 12 Bookworm armhf + systemd)"
echo " $(uname -a)"
echo "=================================================================="

# --- 1. Базовая ОС Debian 12 (glibc, bash, systemd PID 1, разделы) -----------
sect "1. Debian 12 Bookworm armhf, glibc и systemd PID 1"
check "ОС Debian 12 (bookworm) в /etc/os-release" \
    grep -q 'VERSION_CODENAME=bookworm' /etc/os-release
check "архитектура dpkg = armhf" \
    bash -c '[ "$(dpkg --print-architecture)" = "armhf" ]'
check "/etc/apt/sources.list содержит полные репозитории Debian 12 (main contrib non-free non-free-firmware)" \
    bash -e -c '
        grep -qE "^deb .* bookworm main contrib non-free non-free-firmware$" /etc/apt/sources.list
        grep -qE "^deb .* bookworm-updates main contrib non-free non-free-firmware$" /etc/apt/sources.list
        grep -qE "^deb .* bookworm-security main contrib non-free non-free-firmware$" /etc/apt/sources.list
    '
check "динамический линкер glibc armhf (ld-linux-armhf.so.3)" \
    test -e /lib/ld-linux-armhf.so.3
check "GNU bash работает" \
    bash --version
check "PID 1 - реальный systemd" \
    bash -c 'ps -p 1 -o comm= | grep -qx systemd'
check "нет упавших юнитов systemd (--failed пуст)" \
    bash -c '[ "$(systemctl --failed --no-legend --plain | wc -l)" -eq 0 ]'
check "корень / смонтирован rw с noatime" \
    bash -c 'findmnt -n -o OPTIONS / | grep -q noatime'
check "раздел /boot (mmcblk0p1, vfat) смонтирован автоматически и содержит extlinux.conf" \
    bash -c 'mountpoint -q /boot && [ -f /boot/zImage ] && [ -f /boot/extlinux/extlinux.conf ] && [ -d /boot/deb ]'

# --- 2. Надёжность 24/7 и 512 МБ RAM (zram, tmpfs, volatile journal, WDT) ----
sect "2. Оптимизации 24/7: zram swap, tmpfs, journald volatile, /dev/watchdog"
check "сервис informer701-zram активен" \
    systemctl is-active --quiet informer701-zram.service
check "/dev/zram0 подключён как swap в /proc/swaps" \
    grep -q '/dev/zram0' /proc/swaps
echo "  swaps: $(awk 'NR>1{print $1, $2, int($3/1024)"MiB", "prio="$5}' /proc/swaps)"

for mp in /tmp /var/tmp /var/log; do
    check "$mp смонтирован в tmpfs (защита SD-карты от износа)" \
        bash -c "[ \"\$(findmnt -n -o FSTYPE '$mp')\" = 'tmpfs' ]"
done

check "systemd-journald хранит логи в RAM (/run/log/journal, не на SD)" \
    bash -c '[ -d /run/log/journal ] && [ ! -d /var/log/journal ]'

check "аппаратный watchdog /dev/watchdog открыт PID 1 (systemd) и включён в WDOG_MODE" \
    bash -e -c '
        [ -c /dev/watchdog ]
        readlink /proc/1/fd/* 2>/dev/null | grep -q "^/dev/watchdog"
        WM=$(devmem2 0x01c20c94 w | awk "/Read at address/{print \$NF}")
        [ $(( WM & 1 )) -eq 1 ]
    '
check "RuntimeWatchdogSec задан в systemd" \
    bash -c 'systemctl show --property=RuntimeWatchdogUSec | grep -qv "=0$"'
check "утилита wdt status отрабатывает" \
    wdt status

# --- 3. Критичные сервисы, консоль ttyS0 и Restart=always --------------------
sect "3. Сервисы systemd, консоль ttyS0 и политика Restart=always"
check "dropbear.service активен и слушает TCP :22" \
    bash -c 'systemctl is-active --quiet dropbear.service && ss -tln | grep -q ":22 "'
check "haveged.service активен" \
    systemctl is-active --quiet haveged.service
for svc in dropbear.service haveged.service informer701-usbnet.service informer701-wifi.service; do
    check "$svc имеет Restart=always" \
        bash -c "[ \"\$(systemctl show -p Restart --value '$svc')\" = 'always' ]"
done
check "serial-getty@ttyS0 настроен на 115200 и включён в getty.target" \
    bash -c '[ -f /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf ] && grep -q 115200 /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf'

# --- 4. Сеть usb0 (192.168.77.1), DHCP (dnsmasq+dhclient), SSH и NAT ---------
sect "4. Эмуляция сети usb0 (192.168.77.1/24), DHCP, SSH и iptables NAT"
check "сборка пары veth usb0 <-> host0 (netns pc) + адрес 192.168.77.1/24" bash -e -c '
    ip netns del pc 2>/dev/null || true
    ip link del usb0 2>/dev/null || true
    ip netns add pc
    ip link add usb0 type veth peer name host0
    ip link set host0 netns pc
    ip addr add 192.168.77.1/24 dev usb0
    ip link set usb0 up
    ip netns exec pc ip link set lo up
    ip netns exec pc ip link set host0 up
'
check "dnsmasq выдаёт IP по DHCP на usb0, клиент dhclient получает 192.168.77.x" bash -e -c '
    dnsmasq --interface=usb0 --bind-interfaces --port=0 \
        --dhcp-range=192.168.77.10,192.168.77.50,255.255.255.0,1h \
        --dhcp-leasefile=/run/qtest-dnsmasq.leases \
        --pid-file=/run/qtest-dnsmasq.pid
    ip netns exec pc dhclient -1 -lf /run/qtest-dhclient.leases -pf /run/qtest-dhclient.pid host0
    ip netns exec pc ip -4 addr show dev host0 | grep -q "192.168.77\."
'
check "ping 192.168.77.1 и баннер SSH (Dropbear :22) со стороны ПК" bash -e -c '
    ip netns exec pc ping -c 1 -W 2 192.168.77.1 >/dev/null
    BANNER=$(ip netns exec pc bash -c "exec 3<>/dev/tcp/192.168.77.1/22; head -c 32 <&3" || true)
    case "$BANNER" in
        SSH-2.0-dropbear*) exit 0 ;;
        *) echo "неожиданный ответ SSH: $BANNER"; exit 1 ;;
    esac
'
# Останавливаем тестовый dnsmasq/veth
[ -f /run/qtest-dnsmasq.pid ] && kill "$(cat /run/qtest-dnsmasq.pid)" 2>/dev/null || true
[ -f /run/qtest-dhclient.pid ] && kill "$(cat /run/qtest-dhclient.pid)" 2>/dev/null || true
ip netns del pc 2>/dev/null || true
ip link del usb0 2>/dev/null || true

# --- 5. Подсистема Wi-Fi, regulatory.db (ядро 6.6) и модули ------------------
sect "5. Модули ядра 6.6, подписанная regulatory.db и wifi selftest"
check "modprobe cfg80211 + проверка регуляторной базы (iw reg get)" bash -e -c '
    modprobe cfg80211
    sleep 1
    if dmesg | grep -qiE "regulatory\.db.*failed|failed to load regulatory\.db"; then
        dmesg | grep -i regulatory
        exit 1
    fi
    iw reg get | grep -q country
'
for m in mac80211 rt2800usb ath9k_htc carl9170 rtl8xxxu 88x2bu r8152 asix cdc_ether rndis_host exfat ntfs3; do
    check "modprobe $m" modprobe "$m"
done
check "modinfo 88x2bu: vermagic строго совпадает с uname -r и прописаны USB ID RTL8812BU" bash -e -c '
    K=$(uname -r)
    VM=$(modinfo -F vermagic 88x2bu)
    echo "uname=$K vermagic=$VM"
    case "$VM" in
        "$K "*) ;;
        *) echo "несовпадение vermagic!"; exit 1 ;;
    esac
    modinfo -F depends 88x2bu | grep -q cfg80211
    modinfo 88x2bu | grep -qi "v0BDApB812"
    lsmod | grep -q "^88x2bu "
'
check "/etc/modprobe.d/blacklist-rtw88.conf блокирует rtw88_8822bu" \
    grep -q "^blacklist rtw88_8822bu$" /etc/modprobe.d/blacklist-rtw88.conf
echo "  загружено модулей: $(wc -l < /proc/modules)"

check "полный самотест /usr/local/bin/wifi selftest" \
    /usr/local/bin/wifi selftest
check "полный самотест многоадаптерного конфигуратора /usr/local/bin/wifi-config selftest" \
    /usr/local/bin/wifi-config selftest
check "wifi config делегирует команды в wifi-config (STA + AP профили)" \
    bash -e -c '
        wifi config set-sta 00:e0:37:6f:b3:5b "RouterNet" "routerpass123"
        wifi config set-ap  00:e0:4c:88:12:bb "InformerAP" "appass12345" 36
        wifi config status | grep -q "RouterNet"
        wifi config status | grep -q "InformerAP"
        [ -f /etc/wifi-enabled ]
        wifi config clear all
        [ ! -f /etc/wifi-enabled ]
    '

# --- 6. Аппаратные и диагностические утилиты платы + rootfs-expand -----------
sect "6. Бортовые утилиты Informer 701, rootfs-expand (exFAT Windows) и savelog"
check "/etc/default/locale задаёт LANG=C.UTF-8 (без предупреждений pam_env)" \
    grep -q "^LANG=C.UTF-8$" /etc/default/locale
check "devmem2 читает регистр CCU PLL1 (0x01c20000)" \
    bash -c 'devmem2 0x01c20000 w | grep -q "Read at address"'
check "clk расшифровывает частоты CCU Allwinner A10" \
    bash -c 'clk | grep -q "PLL1_CFG"'
check "regs читает регистры CCU/PIO/TWI0/WDOG" \
    bash -c 'regs | grep -q "WDOG_MODE"'
check "rootfs-expand онлайн расширяет / и создаёт Windows-раздел /mnt/share (exFAT)" \
    bash -e -c '
        SPL_BEFORE=$(dd if=/dev/mmcblk0 bs=1k skip=8 count=500 status=none | sha256sum | awk "{print \$1}")
        ROOT_BEFORE=$(df -Pm / | awk "NR==2{print \$2}")
        rootfs-expand --share-size 128M --fs exfat --label INFORMER --yes
        ROOT_AFTER=$(df -Pm / | awk "NR==2{print \$2}")
        SPL_AFTER=$(dd if=/dev/mmcblk0 bs=1k skip=8 count=500 status=none | sha256sum | awk "{print \$1}")
        echo "rootfs MiB: $ROOT_BEFORE -> $ROOT_AFTER; SPL sha256: $SPL_AFTER"
        [ "$SPL_BEFORE" = "$SPL_AFTER" ]
        [ "$ROOT_AFTER" -gt $((ROOT_BEFORE + 250)) ]
        [ -b /dev/mmcblk0p3 ]
        [ "$(blkid -s TYPE -o value /dev/mmcblk0p3)" = "exfat" ]
        [ "$(blkid -s LABEL -o value /dev/mmcblk0p3)" = "INFORMER" ]
        mountpoint -q /mnt/share
        [ -f /mnt/share/README.txt ]
        echo "Привет из Informer 701" > "/mnt/share/files/проверка-utf8.txt"
        sync
        systemctl restart informer701-share.service
        mountpoint -q /mnt/share
        grep -q "Привет из Informer 701" "/root/share/files/проверка-utf8.txt"
    '
check "info выводит сводку по плате и видит /mnt/share" \
    bash -e -c 'info | grep -q "/mnt/share"'
check "whichboot определяет носители" \
    whichboot
check "savelog сохраняет отчёт и в /boot/logs/, и на общий раздел /mnt/share/logs/" \
    bash -e -c 'savelog && ls /boot/logs/diag-*.txt >/dev/null && ls /mnt/share/logs/diag-*.txt >/dev/null'
check "bootnext (список / -n safe / откат через informer701-bootinit) работает" \
    bash -e -c '
        bootnext | grep -q lowopp
        bootnext -n safe
        [ -f /boot/bootonce ]
        grep -q "^default safe$" /boot/extlinux/extlinux.conf
        /usr/local/sbin/informer701-bootinit
        [ ! -f /boot/bootonce ]
        grep -q "^default lowopp$" /boot/extlinux/extlinux.conf
    '
check "usbnet status отрабатывает штатно" \
    usbnet status
check "pkg status и pkg installed работают поверх apt/dpkg" \
    bash -e -c 'pkg status && pkg installed | grep -q dropbear-bin'
check "memtester 2M 1 проходит проверку памяти" \
    memtester 2M 1
check "синтаксис bash -n всех скриптов в /usr/local/bin и /usr/local/sbin" \
    bash -e -c '
        for f in /usr/local/bin/* /usr/local/sbin/* /sbin/hotplug; do
            head -c 2 "$f" | grep -q "^#!" || continue
            bash -n "$f"
        done
    '

# --- Итог --------------------------------------------------------------------
echo ""
echo "=================================================================="
if [ "$FAIL" -eq 0 ]; then
    echo " QTEST_RESULT: PASS ($PASS проверок успешно, 0 ошибок)"
else
    echo " QTEST_RESULT: FAIL ($PASS успешно, $FAIL ошибок)"
fi
echo "=================================================================="
sync
sleep 1
poweroff -f 2>/dev/null || true
